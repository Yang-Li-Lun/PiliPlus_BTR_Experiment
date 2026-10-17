import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

import 'demand_lifecycle_test.dart' show waitUntil;
import 'fake_cdn.dart';

void main() {
  final bytes = Uint8List.fromList(
    List.generate(6 * 1024 * 1024, (i) => i % 251),
  );
  late FakeCdn cdn;
  late BtrScheduler scheduler;
  late BtrMetrics metrics;
  late BtrTransport transport;
  late String url;
  Future<void> setup(Duration attempt) async {
    cdn = FakeCdn(bytes);
    await cdn.start();
    scheduler = BtrScheduler();
    metrics = BtrMetrics(BtrMode.combined);
    transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(
        scheduler,
        metrics,
        cdn,
        attemptTimeout: attempt,
        stallTimeout: const Duration(seconds: 3),
      ),
    );
    url = (await transport.start([
      BtrTrackSpec(
        kind: 'video',
        urls: ['https://origin.bilivideo.com/video.m4s'],
      ),
    ]))['video']!;
    await transport.tracks['video']!.initialize();
  }

  tearDown(() async {
    await transport.close();
    await cdn.close();
  });

  test(
    'a sole reader uses the original full window without raising the cap',
    () async {
      await setup(const Duration(seconds: 5));
      transport.adaptive.connectionBps = 1024 * 1024 / .6;
      expect(
        await fetchLocal(url, range: 'bytes=65536-'),
        bytes.sublist(65536),
      );
      expect(
        transport.tracks['video']!.peakReservedBytes,
        4 * 1024 * 1024,
        reason: 'idle handler head slots unnecessarily reduce steady prefetch',
      );
    },
  );

  test(
    'late exhausted old GETs cannot terminate a successful newer generation',
    () async {
      await setup(const Duration(seconds: 5));
      final gate = Completer<void>();
      cdn.handler = (r, range, n) async {
        if (range.start >= 4 * 1024 * 1024) return false;
        await gate.future;
        r.response.statusCode = 503;
        await r.response.close();
        return true;
      };
      final old = [
        for (var i = 1; i <= 3; i++)
          expectLater(
            fetchLocal(url, range: 'bytes=${i * 65536}-${(i + 1) * 65536 - 1}'),
            throwsA(anything),
          ),
      ];
      try {
        await waitUntil(() => transport.snapshot()['activeProxyHandlers'] == 3);
        transport.seek();
        expect(
          await fetchLocal(url, range: 'bytes=4194304-4259839'),
          bytes.sublist(4194304, 4259840),
        );
      } finally {
        gate.complete();
        await Future.wait(old);
      }
      await transport.settled;
      expect(transport.tracks['video']!.terminal, false);
      expect(transport.currentReadFailureAt, isNull);
      expect(
        await fetchLocal(url, range: 'bytes=4194304-4259839'),
        bytes.sublist(4194304, 4259840),
      );
    },
  );

  test(
    'scheduler wait does not consume an upstream attempt or retry',
    () async {
      await setup(const Duration(milliseconds: 100));
      final token = BtrCancel();
      final releases = <void Function()>[];
      for (var i = 0; i < 7; i++) {
        releases.add(
          await scheduler.acquire(token, audio: false, priority: () => 500),
        );
      }
      final downloading = fetchLocal(url, range: 'bytes=65536-131071');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      for (final release in releases) {
        release();
      }
      expect(await downloading, bytes.sublist(65536, 131072));
      expect(metrics.requestFailures, 0);
      expect(metrics.retries, 0);
    },
  );

  for (final notifySeek in [false, true]) {
    test(
      'new GET reclaims speculation and completes both; seek=$notifySeek',
      () async {
        await setup(const Duration(seconds: 5));
        transport.adaptive.connectionBps = 65536 / .6;
        final releaseOld = Completer<void>();
        cdn.handler = (r, range, n) async {
          if (range.start < 3 * 1024 * 1024) await releaseOld.future;
          return false;
        };
        final old = fetchLocal(url, range: 'bytes=65536-2097151');
        // Observe old prefetch plus its head hedge occupying all video slots.
        try {
          await waitUntil(() => scheduler.videoActive == 7);
          if (notifySeek) transport.seek();
          final fresh = await fetchLocal(
            url,
            range: 'bytes=4194304-4259839',
          ).timeout(const Duration(milliseconds: 700));
          expect(fresh, bytes.sublist(4194304, 4259840));
          expect(
            metrics.cancellations,
            0,
            reason: 'old HTTP demand remains valid',
          );
          expect(metrics.requestFailures, 0);
        } finally {
          releaseOld.complete();
          expect(await old, bytes.sublist(65536, 2097152));
        }
        await transport.settled;
        expect(scheduler.active, 0);
        expect(scheduler.queued, 0);
        expect(
          transport.tracks['video']!.peakReservedBytes,
          lessThanOrEqualTo(4 * 1024 * 1024),
        );
      },
    );
  }

  test(
    'new GET retains one completed prefetch piece for the active old reader',
    () async {
      await setup(const Duration(seconds: 5));
      transport.adaptive.connectionBps = 1024 * 1024 / .6;
      final entered = Completer<void>(), release = Completer<void>();
      final oldDone = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await transport.tracks['video']!.serve(
          GatedRequest(request, entered, release),
        );
        oldDone.complete();
      });
      final old = fetchLocal(
        'http://127.0.0.1:${server.port}/old',
        range: 'bytes=65536-2162687',
      );
      try {
        await entered.future;
        await waitUntil(() => scheduler.active == 0);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        transport.seek();
        expect(
          await fetchLocal(url, range: 'bytes=4194304-4259839'),
          bytes.sublist(4194304, 4259840),
        );
        release.complete();
        expect(await old, bytes.sublist(65536, 2162688));
        await oldDone.future;
        final firstPrefetch = cdn.requests.where((r) => r.$2.start == 131072);
        expect(
          firstPrefetch,
          hasLength(1),
          reason: 'validated completed prefix was downloaded twice',
        );
        expect(
          transport.tracks['video']!.peakReservedBytes,
          lessThanOrEqualTo(4 * 1024 * 1024),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await old;
        await server.close(force: true);
      }
    },
  );

  test(
    'rebalancing cannot discard an observed speculative identity violation',
    () async {
      await setup(const Duration(seconds: 5));
      transport.adaptive.connectionBps = 1024 * 1024 / .6;
      final gate = Completer<void>();
      cdn.handler = (r, range, _) async {
        if (range.start == 65536) await gate.future;
        if (range.start == 131072) {
          r.response.statusCode = 206;
          r.response.headers.set(
            'content-range',
            'bytes ${range.start}-${range.end}/${bytes.length}',
          );
          r.response.headers.set('etag', '"changed-identity"');
          r.response.contentLength = range.length;
          r.response.add(bytes.sublist(range.start, range.end + 1));
          await r.response.close();
          return true;
        }
        return false;
      };
      final old = fetchLocal(
        url,
        range: 'bytes=65536-2097151',
      ).then<bool>((_) => true, onError: (Object _) => false);
      try {
        await waitUntil(() => metrics.requestFailures > 0);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final fresh = await fetchLocal(
          url,
          range: 'bytes=4194304-4259839',
        ).then<bool>((_) => true, onError: (Object _) => false);
        expect(
          fresh,
          false,
          reason: 'rebalance hid a known identity contradiction',
        );
        expect(transport.tracks['video']!.terminal, true);
        expect(metrics.terminalFailures, 1);
      } finally {
        gate.complete();
        await old;
      }
      await transport.settled;
      expect(scheduler.active, 0);
      expect(scheduler.queued, 0);
    },
  );
}

class GatedRequest implements HttpRequest {
  GatedRequest(this.inner, Completer<void> entered, Completer<void> release)
    : response = GatedResponse(inner.response, entered, release);
  final HttpRequest inner;
  @override
  final HttpResponse response;
  @override
  String get method => inner.method;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class GatedResponse implements HttpResponse {
  GatedResponse(this.inner, this.entered, this.release);
  final HttpResponse inner;
  final Completer<void> entered, release;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future get done => inner.done;
  @override
  set statusCode(int v) => inner.statusCode = v;
  @override
  set contentLength(int v) => inner.contentLength = v;
  @override
  set deadline(Duration? v) => inner.deadline = v;
  @override
  void add(List<int> bytes) => inner.add(bytes);
  @override
  Future<void> close() async {
    await inner.close();
  }

  @override
  Future<void> flush() async {
    await inner.flush();
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
