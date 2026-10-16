import 'dart:async';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

import 'fake_cdn.dart';

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('fixture condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'cancelling retry/discovery delay removes its timer immediately',
    () async {
      final token = BtrCancel();
      final timers = <Timer>[];
      final waiting = runZoned(
        () => token.delay(const Duration(hours: 1)),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
      final expectation = expectLater(waiting, throwsA(isA<BtrCancelled>()));
      token.cancel();
      await expectation;
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isFalse);
    },
  );

  test('close during proxy bind waits for late listener shutdown', () async {
    final transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: BtrMetrics(BtrMode.combined),
    );
    final starting = expectLater(
      transport.start([]),
      throwsA(isA<BtrCancelled>()),
    );
    final closing = transport.close();
    expect(identical(closing, transport.close()), isTrue);
    await Future.wait([starting, closing]);
    expect(transport.tracks, isEmpty);
    expect(transport.scheduler.active, 0);
    expect(transport.scheduler.queued, 0);
  });

  test('closed transport cannot start a new proxy', () async {
    final transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: BtrMetrics(BtrMode.combined),
    );
    await transport.close();
    await expectLater(transport.start([]), throwsA(isA<BtrCancelled>()));
    expect(transport.tracks, isEmpty);
  });

  for (final hedge in [false, true]) {
    test(
      'task close cancels dual-track downloads, queue and hedge=$hedge',
      () async {
        final cdn = FakeCdn(Uint8List(6 * 1024 * 1024));
        await cdn.start();
        final metrics = BtrMetrics(BtrMode.combined);
        final scheduler = BtrScheduler();
        final transport = BtrTransport(
          mode: BtrMode.combined,
          metrics: metrics,
          scheduler: scheduler,
          network: FakeNetwork(
            scheduler,
            metrics,
            cdn,
            stallTimeout: const Duration(seconds: 2),
          ),
        );
        final held = Completer<void>();
        addTearDown(() async {
          if (!held.isCompleted) held.complete();
          await transport.close();
          await cdn.close();
        });
        final urls = await transport.start([
          BtrTrackSpec(
            kind: 'video',
            urls: ['https://origin.bilivideo.com/upgcxcode/video.m4s'],
          ),
          BtrTrackSpec(
            kind: 'audio',
            urls: ['https://origin.bilivideo.com/upgcxcode/audio.m4s'],
          ),
        ]);
        await Future.wait(
          transport.tracks.values.map((track) => track.initialize()),
        );
        cdn.handler = (request, range, number) async {
          await held.future;
          return false;
        };
        transport.adaptive.pieceMs = 0;
        final range = hedge ? 'bytes=1000000-1065535' : null;
        final video = expectLater(
          fetchLocal(urls['video']!, range: range),
          throwsA(anything),
        );
        final audio = expectLater(
          fetchLocal(urls['audio']!, range: range),
          throwsA(anything),
        );
        if (hedge) {
          await waitFor(() => metrics.hedges > 0);
        } else {
          await waitFor(
            () => scheduler.queued > 0 && scheduler.audioActive > 0,
          );
        }
        await Future.wait([transport.close(), transport.close()])
            .timeout(const Duration(seconds: 3));
        await Future.wait([video, audio]);
        expect(scheduler.active, 0);
        expect(scheduler.queued, 0);
        final requests = cdn.requests.length;
        final retries = metrics.retries;
        final hedges = metrics.hedges;
        held.complete();
        await Future<void>.delayed(const Duration(milliseconds: 650));
        expect(cdn.requests.length, requests);
        expect(metrics.retries, retries);
        expect(metrics.hedges, hedges);
        expect(cdn.active, 0);
        await expectLater(fetchLocal(urls['video']!), throwsA(anything));
        await expectLater(fetchLocal(urls['audio']!), throwsA(anything));
      },
    );
  }
}
