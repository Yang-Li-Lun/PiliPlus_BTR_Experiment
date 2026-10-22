import 'dart:async';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/proxy_capacity.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

import 'demand_lifecycle_test.dart' show waitUntil;
import 'fake_cdn.dart';

void main() {
  test('a completed fast flush lets a waiting response execute without closing the old response', () async {
    final capacity = BtrProxyCapacity(), token = BtrCancel();
    final slots = List.generate(5, (_) => capacity.admit()!);
    await Future.wait(slots.take(4).map((s) => s.acquire(token)));
    final admitted = slots[4].acquire(token);
    // Handle cancellation in cleanup even if the admission assertion fails.
    unawaited(admitted.catchError((Object _) {}));
    try {
      await slots.first.flush(
        Future<void>.value(),
        token,
        onBlocked: () => fail('fast flush was parked'),
      );
      await admitted.timeout(const Duration(milliseconds: 300));
      expect(capacity.responses, 5);
      expect(capacity.active, 4);
      expect(capacity.parked, 0);
      expect(capacity.suspensions, 0);
      expect(capacity.cooperativeYields, 1);
      slots[4].close();
      await slots.first.acquire(token);
      expect(capacity.peak, 4);
    } finally {
      token.cancel();
      for (final slot in slots) {
        slot.close();
      }
      await admitted.catchError((Object _) {});
    }
    expect(capacity.responses, 0);
    expect(capacity.active, 0);
  });

  test('cancellation while lending a fast writer slot preserves capacity accounting', () async {
    final capacity = BtrProxyCapacity(),
        writerToken = BtrCancel(),
        waitingToken = BtrCancel();
    final slots = List.generate(5, (_) => capacity.admit()!);
    await Future.wait(slots.take(4).map((s) => s.acquire(writerToken)));
    final admitted = slots[4]
        .acquire(waitingToken)
        .then((_) => writerToken.cancel());
    try {
      await expectLater(
        slots.first.flush(
          Future<void>.value(),
          writerToken,
          onBlocked: () => fail('fast flush was parked'),
        ),
        throwsA(isA<BtrCancelled>()),
      );
      await admitted;
      expect(capacity.active, 4);
      expect(capacity.responses, 5);
    } finally {
      waitingToken.cancel();
      for (final slot in slots) {
        slot.close();
      }
    }
    expect(capacity.active, 0);
    expect(capacity.responses, 0);
  });

  test('four continuously consumed responses admit audio while preserving every old byte', () async {
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024, (i) => i % 251),
    );
    // The existing weak-validator fallback gives continuous small HTTP chunks.
    // This isolates proxy execution fairness from segment scheduling and hedges.
    final cdn = FakeCdn(payload)..etag = null;
    await cdn.start();
    final metrics = BtrMetrics(BtrMode.combined), scheduler = BtrScheduler();
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
    addTearDown(() async {
      await transport.close();
      await cdn.close();
    });
    final urls = await transport.start([
      for (final kind in ['video', 'audio'])
        BtrTrackSpec(
          kind: kind,
          urls: ['https://origin.bilivideo.com/$kind.m4s'],
        ),
    ]);
    await Future.wait(transport.tracks.values.map((t) => t.initialize()));
    cdn.handler = (request, range, _) async {
      if (range.length <= 65536) return false;
      request.response.statusCode = 206;
      request.response.contentLength = range.length;
      request.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/${payload.length}',
      );
      for (var start = range.start; start <= range.end; start += 16384) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        request.response.add(
          Uint8List.sublistView(
            payload,
            start,
            (start + 16384).clamp(0, range.end + 1),
          ),
        );
        await request.response.flush();
      }
      await request.response.close();
      return true;
    };
    final oldResponses = List.generate(
      4,
      (_) =>
          fetchLocal(urls['video']!)
              .then<Object>((bytes) => bytes, onError: (Object error) => error),
    );
    await waitUntil(
      () =>
          transport.snapshot()['activeProxyHandlers'] == 4 &&
          metrics.deliveredBytes >= 65536,
    );
    final received = await fetchLocal(urls['audio']!, range: 'bytes=0-16383');
    expect(received, orderedEquals(payload.sublist(0, 16384)));
    for (final old in await Future.wait(oldResponses)) {
      expect(old, isA<Uint8List>());
      expect(old, orderedEquals(payload));
    }
    await transport.settled;
    expect(metrics.cancellations, 0);
    expect(transport.snapshot()['proxyCapacityRejections'], 0);
    expect(transport.snapshot()['peakProxyHandlers'], 4);
    expect(transport.snapshot()['proxyResponseLimit'], 8);
    expect(transport.snapshot()['openProxyResponses'], 0);
  });
}
