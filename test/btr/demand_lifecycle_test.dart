import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

import 'fake_cdn.dart';

Future<void> waitUntil(bool Function() ready) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(until)) fail('fixture did not become ready');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// Inject a downstream flush timeout after real headers/body have been sent.
// This exercises serve's local sink boundary, independently of upstream I/O.
class FlushFailureResponse implements HttpResponse {
  FlushFailureResponse(this.inner, {this.beforeFailure});
  final Future<void> Function()? beforeFailure;
  final HttpResponse inner;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future get done => inner.done;
  @override
  set statusCode(int value) => inner.statusCode = value;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  set deadline(Duration? value) => inner.deadline = value;
  @override
  void add(List<int> bytes) => inner.add(bytes);
  @override
  Future<void> close() async {
    await inner.close();
  }

  @override
  Future<void> flush() async {
    await inner.flush();
    await beforeFailure?.call();
    throw TimeoutException('https://secret.invalid/?token=never-log');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FlushFailureRequest implements HttpRequest {
  FlushFailureRequest(this.inner, {Future<void> Function()? beforeFailure})
    : response = FlushFailureResponse(
        inner.response,
        beforeFailure: beforeFailure,
      );
  final HttpRequest inner;
  @override
  final HttpResponse response;
  @override
  String get method => inner.method;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final video = Uint8List.fromList(
    List.generate(6 * 1024 * 1024, (i) => i % 251),
  );
  final audio = Uint8List.fromList(video.map((b) => b ^ 0x55).toList());
  late FakeCdn cdn;
  late BtrTransport transport;
  late BtrMetrics metrics;
  late Map<String, String> urls;

  setUp(() async {
    cdn = FakeCdn(video)..audioBytes = audio;
    await cdn.start();
    metrics = BtrMetrics(BtrMode.combined);
    final scheduler = BtrScheduler();
    transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(scheduler, metrics, cdn),
    );
    urls = await transport.start([
      for (final kind in ['video', 'audio'])
        BtrTrackSpec(
          kind: kind,
          urls: ['https://origin.bilivideo.com/$kind.m4s'],
        ),
    ]);
    await Future.wait(transport.tracks.values.map((t) => t.initialize()));
  });
  tearDown(() async {
    await transport.close();
    await cdn.close();
  });

  Future<void> restart({Duration attempt = const Duration(seconds: 2)}) async {
    await transport.close();
    metrics = BtrMetrics(BtrMode.combined);
    final scheduler = BtrScheduler();
    transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(scheduler, metrics, cdn, attemptTimeout: attempt),
    );
    urls = await transport.start([
      for (final kind in ['video', 'audio'])
        BtrTrackSpec(
          kind: kind,
          urls: ['https://origin.bilivideo.com/$kind.m4s'],
        ),
    ]);
    await Future.wait(transport.tracks.values.map((t) => t.initialize()));
  }

  for (final newer in [false, true]) {
    test(
      'late old response failure keeps its generation; newer failure=$newer',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final oldDone = Completer<void>(), newDone = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await server.close(force: true);
        });
        server.listen((r) async {
          final old = r.uri.path == '/old';
          await transport.tracks['video']!.serve(
            FlushFailureRequest(
              r,
              beforeFailure: old
                  ? () async {
                      entered.complete();
                      await release.future;
                    }
                  : null,
            ),
          );
          (old ? oldDone : newDone).complete();
        });
        final old = expectLater(
          fetchLocal('http://127.0.0.1:${server.port}/old'),
          throwsA(anything),
        );
        await entered.future;
        transport.seek();
        if (newer) {
          await expectLater(
            fetchLocal('http://127.0.0.1:${server.port}/new'),
            throwsA(anything),
          );
          await newDone.future;
          expect(transport.currentSeekHasLocalFailure, true);
        }
        release.complete();
        await old;
        await oldDone.future;
        expect(
          transport.snapshot()['localReadFailureGeneration'],
          newer ? 1 : 0,
        );
        expect(transport.currentSeekHasLocalFailure, newer);
      },
    );
  }

  test('attempt timeout is bounded upstream failure, not a cancellation or permanent track failure', () async {
    await restart(attempt: const Duration(milliseconds: 80));
    cdn.handler = (r, range, n) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return false;
    };
    await expectLater(
      fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
      throwsA(anything),
    );
    await transport.settled;
    expect(metrics.requestFailures, 3);
    expect(metrics.retries, 2);
    expect(metrics.cancellations, 0);
    expect(metrics.terminalFailures, 0);
    expect(transport.tracks['video']!.lastFailure, 'attempt-deadline');
    cdn.handler = null;
    expect(
      await fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
      orderedEquals(video.sublist(1000000, 1065536)),
    );
    await transport.settled;
    final track = (transport.snapshot()['tracks'] as List).first as Map;
    expect(track['recoverableDemandFailures'], 0);
  });

  test('unvalidated direct stream interruption recovers without prefix reuse or segmentation', () async {
    cdn.etag = null;
    await restart();
    var broken = false;
    cdn.handler = (r, range, n) async {
      if (broken || range.start == 0 && range.end == 65535) return false;
      broken = true;
      r.response.statusCode = 206;
      r.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/${video.length}',
      );
      r.response.contentLength = range.length;
      r.response.add(video.sublist(range.start, range.start + 32768));
      await r.response.flush();
      r.response.deadline = Duration.zero;
      return true;
    };
    await expectLater(
      fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
      throwsA(anything),
    );
    await transport.settled;
    expect(transport.tracks['video']!.terminal, isFalse);
    expect(
      await fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
      orderedEquals(video.sublist(1000000, 1065536)),
    );
    expect(metrics.resumes, 0);
    expect(metrics.hedges, 0);
    expect(transport.tracks['video']!.peakReservedBytes, 0);
  });

  test('piece deadline is a bounded upstream failure rather than seek cancellation', () async {
    cdn.handler = (r, range, n) async {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      return false;
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final served = Completer<void>();
    var deadlines = 0;
    await runZoned(
      () async {
        // Register the handler in this zone so only the production piece's
        // 25 second deadline is accelerated; cancellation behavior is real.
        server.listen((request) async {
          try {
            await transport.tracks['video']!.serve(request);
            served.complete();
          } catch (error, stack) {
            served.completeError(error, stack);
          }
        });
        await expectLater(
          fetchLocal(
            'http://127.0.0.1:${server.port}/video',
            range: 'bytes=1000000-1065535',
          ),
          throwsA(anything),
        );
        await served.future;
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 25)) {
            deadlines++;
            duration = const Duration(milliseconds: 60);
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    await transport.settled;
    expect(deadlines, 1);
    expect(transport.tracks['video']!.lastFailure, 'piece-deadline');
    expect(transport.tracks['video']!.terminal, isFalse);
    expect(metrics.cancellations, 0);
    expect(metrics.terminalFailures, 0);
    expect(metrics.retries, 0);
    cdn.handler = null;
    expect(
      await fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
      orderedEquals(video.sublist(1000000, 1065536)),
    );
  });

  test(
    'seek and overlapping GETs preserve old and new dual-track ranges',
    () async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      cdn.handler = (r, range, n) async {
        if (range.start == 1000000) await held.future;
        return false;
      };
      final old = Future.wait([
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        fetchLocal(urls['audio']!, range: 'bytes=1000000-1065535'),
      ]);
      // Observe errors before issuing the overlapping requests on the old code.
      final oldChecked = expectLater(
        old,
        completion([
          orderedEquals(video.sublist(1000000, 1065536)),
          orderedEquals(audio.sublist(1000000, 1065536)),
        ]),
      );
      await waitUntil(
        () => cdn.requests.where((r) => r.$2.start == 1000000).length >= 2,
      );
      transport.seek();
      final next = await Future.wait([
        fetchLocal(urls['video']!, range: 'bytes=2000000-2065535'),
        fetchLocal(urls['audio']!, range: 'bytes=2000000-2065535'),
      ]);
      expect(next[0], orderedEquals(video.sublist(2000000, 2065536)));
      expect(next[1], orderedEquals(audio.sublist(2000000, 2065536)));
      held.complete();
      await oldChecked;
      await transport.settled;
      expect(metrics.terminalFailures, 0);
      expect(metrics.requestFailures, 0);
      expect(metrics.cancellations, 0);
    },
  );

  test(
    'new same-track GET does not truncate an existing response without seek',
    () async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      cdn.handler = (r, range, n) async {
        if (range.start == 1000000) await held.future;
        return false;
      };
      final old = expectLater(
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        completion(orderedEquals(video.sublist(1000000, 1065536))),
      );
      await waitUntil(() => cdn.requests.any((r) => r.$2.start == 1000000));
      expect(
        await fetchLocal(urls['video']!, range: 'bytes=-100'),
        orderedEquals(video.sublist(video.length - 100)),
      );
      held.complete();
      await old;
    },
  );

  test(
    'downstream flush timeout leaves both tracks usable without seek',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = Completer<void>();
      server.listen((r) async {
        try {
          await transport.tracks['video']!.serve(FlushFailureRequest(r));
          served.complete();
        } catch (e, s) {
          served.completeError(e, s);
        }
      });
      addTearDown(() => server.close(force: true));
      await expectLater(
        fetchLocal('http://127.0.0.1:${server.port}/video'),
        throwsA(anything),
      );
      await served.future;
      expect(transport.tracks['video']!.terminal, isFalse);
      expect(metrics.requestFailures, 0);
      expect(metrics.terminalFailures, 0);
      final next = await Future.wait([
        fetchLocal(urls['video']!, range: 'bytes=2000000-2065535'),
        fetchLocal(urls['audio']!, range: 'bytes=2000000-2065535'),
      ]);
      expect(next[0], orderedEquals(video.sublist(2000000, 2065536)));
      expect(next[1], orderedEquals(audio.sublist(2000000, 2065536)));
      final report = '${metrics.snapshot()} ${transport.snapshot()}';
      expect(report, contains('proxy-write'));
      expect(report, isNot(contains('never-log')));
      expect(report, isNot(contains('https://')));
    },
  );

  test(
    'exhausted transient upstream I/O can recover on a later exact Range',
    () async {
      cdn.handler = (r, range, n) async {
        r.response.statusCode = 503;
        await r.response.close();
        return true;
      };
      await expectLater(
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        throwsA(anything),
      );
      await transport.settled;
      expect(transport.tracks['video']!.terminal, isFalse);
      expect(metrics.retries, 2);
      cdn.handler = null;
      expect(
        await fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        orderedEquals(video.sublist(1000000, 1065536)),
      );
      expect(
        await fetchLocal(urls['audio']!, range: 'bytes=-100'),
        orderedEquals(audio.sublist(audio.length - 100)),
      );
      expect(metrics.terminalFailures, 0);
    },
  );

  test(
    'buffered seek needs no replacement GET and preserves both streams',
    () async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      cdn.handler = (r, range, n) async {
        if (range.start > 0) await held.future;
        return false;
      };
      final pending = Future.wait([
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        fetchLocal(urls['audio']!, range: 'bytes=1000000-1065535'),
      ]);
      await waitUntil(() => transport.scheduler.active >= 2);
      transport
        ..seek()
        ..seek();
      held.complete();
      final result = await pending;
      expect(result[0], orderedEquals(video.sublist(1000000, 1065536)));
      expect(result[1], orderedEquals(audio.sublist(1000000, 1065536)));
      expect(metrics.cancellations, 0);
    },
  );

  test(
    'overlapping large demands share the per-track 4 MiB window and drain',
    () async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      cdn.handler = (r, range, n) async {
        if (range.start == 1000000 || range.start == 2000000) await held.future;
        return false;
      };
      final first = fetchLocal(urls['video']!, range: 'bytes=1000000-');
      await waitUntil(() => cdn.requests.any((r) => r.$2.start == 1000000));
      final second = fetchLocal(urls['video']!, range: 'bytes=2000000-');
      await waitUntil(() => cdn.requests.any((r) => r.$2.start == 2000000));
      held.complete();
      final results = await Future.wait([first, second]);
      expect(results[0], orderedEquals(video.sublist(1000000)));
      expect(results[1], orderedEquals(video.sublist(2000000)));
      await transport.settled;
      expect(
        transport.tracks['video']!.peakReservedBytes,
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
      final track = (transport.snapshot()['tracks'] as List).first as Map;
      expect(track['orderedReservationBytes'], 0);
      expect(track['activeDemands'], 0);
      expect(transport.scheduler.active, 0);
      expect(transport.scheduler.queued, 0);
    },
  );

  test(
    'HTTP precondition failure remains terminal without recovery or identity reset',
    () async {
      cdn.handler = (r, range, n) async {
        r.response.statusCode = 412;
        await r.response.close();
        return true;
      };
      final locked = transport.tracks['video']!.sample!.identity;
      final before = cdn.requests.length;
      await expectLater(
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        throwsA(anything),
      );
      await transport.settled;
      expect(transport.tracks['video']!.terminal, isTrue);
      expect(transport.tracks['video']!.sample!.identity, same(locked));
      expect(cdn.requests.length - before, 1);
      expect(metrics.retries, 0);
      expect(metrics.terminalFailures, 1);
      final count = cdn.requests.length;
      cdn.handler = null;
      await expectLater(
        fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        throwsA(anything),
      );
      expect(cdn.requests.length, count);
      expect(transport.scheduler.active, 0);
    },
  );

  test(
    'consecutive exhausted upstream demands terminate after a finite budget',
    () async {
      cdn.handler = (r, range, n) async {
        r.response.statusCode = 503;
        await r.response.close();
        return true;
      };
      final before = cdn.requests.length;
      for (var i = 0; i < 3; i++) {
        await expectLater(
          fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
          throwsA(anything),
        );
        await transport.settled;
        expect(transport.tracks['video']!.terminal, i == 2);
        if (i < 2) {
          final client = HttpClient();
          try {
            final head = await client.headUrl(Uri.parse(urls['video']!));
            await (await head.close()).drain<void>();
          } finally {
            client.close(force: true);
          }
        }
      }
      expect(cdn.requests.length - before, 9);
      expect(metrics.terminalFailures, 1);
      expect(transport.tracks['video']!.lastFailure, 'recovery-exhausted');
      final count = cdn.requests.length;
      await expectLater(fetchLocal(urls['video']!), throwsA(anything));
      expect(cdn.requests.length, count);
      cdn.handler = null;
      expect(
        await fetchLocal(urls['audio']!, range: 'bytes=-100'),
        orderedEquals(audio.sublist(audio.length - 100)),
      );
    },
  );
}
