import 'dart:async';
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

  test(
    'new generation reclaims speculation, preserves and completes old GET',
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
        transport.seek();
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
