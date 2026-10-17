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
import 'demand_lifecycle_test.dart' show waitUntil;

void main() {
  test('real loopback backpressure is cancellable at native stop without waiting 15s flush timeout', () async {
    final bytes = Uint8List(16 * 1024 * 1024);
    final cdn = FakeCdn(bytes);
    await cdn.start();
    final metrics = BtrMetrics(BtrMode.combined);
    final scheduler = BtrScheduler();
    final transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(scheduler, metrics, cdn),
    );
    final sockets = <Socket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
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
    for (final kind in ['video', 'audio', 'video', 'audio']) {
      final uri = Uri.parse(urls[kind]!);
      final socket = await Socket.connect(uri.host, uri.port);
      sockets.add(socket);
      // Deliberately never read: the OS/Dart socket buffers eventually fill.
      socket.write(
        'GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nRange: bytes=0-\r\n\r\n',
      );
      await socket.flush();
    }
    await waitUntil(
      () =>
          transport.snapshot()['activeProxyHandlers'] == 4 &&
          (transport.snapshot()['tracks'] as List).every(
            (t) =>
                (t['demands'] as List).length == 2 &&
                // One request can occupy the shared 4 MiB track window;
                // another legitimately waits upstream for that reservation.
                (t['demands'] as List).any(
                  (d) =>
                      d['stage'] == 'proxy-write' && d['progressAgeMs'] >= 50,
                ),
          ),
    );
    final elapsed = Stopwatch()..start();
    await transport.retirePlayerRequests().timeout(const Duration(seconds: 3));
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
    expect(transport.snapshot()['activeProxyHandlers'], 0);
    expect(scheduler.active, 0);
    expect(scheduler.queued, 0);
    expect(metrics.terminalFailures, 0);
    expect(metrics.requestFailures, 0);
    expect(metrics.events.where((e) => e['outcome'] == 'local-error'), isEmpty);
    expect(
      await fetchLocal(urls['audio']!, range: 'bytes=-100'),
      hasLength(100),
    );
  });
  test('four held GETs reject visibly, native stop releases all before dual-track reopen', () async {
    final bytes = Uint8List.fromList(
      List.generate(6 * 1024 * 1024, (i) => i % 251),
    );
    final cdn = FakeCdn(bytes)
      ..audioBytes = Uint8List.fromList(bytes.map((v) => v ^ 0x55).toList());
    await cdn.start();
    final metrics = BtrMetrics(BtrMode.combined);
    final scheduler = BtrScheduler();
    final transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(scheduler, metrics, cdn),
    );
    final held = Completer<void>();
    addTearDown(() async {
      if (!held.isCompleted) held.complete();
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
    cdn.handler = (r, range, n) async {
      if (range.start >= 1000000 && range.start < 3000000) await held.future;
      return false;
    };
    final old = <Future<void>>[];
    for (final offset in [1000000, 2000000]) {
      for (final kind in ['video', 'audio']) {
        old.add(
          expectLater(
            fetchLocal(urls[kind]!, range: 'bytes=$offset-${offset + 65535}'),
            throwsA(anything),
          ),
        );
      }
    }
    await waitUntil(
      () => (transport.snapshot()['activeProxyHandlers'] as int?) == 4,
    );
    for (var i = 0; i < 5; i++) {
      transport.seek();
    }
    await expectLater(
      fetchLocal(urls['video']!, range: 'bytes=-100'),
      throwsA(isA<BtrFailure>().having((e) => e.status, 'status', 503)),
    );
    expect(transport.snapshot()['proxyCapacityRejections'], 1);
    expect(transport.currentSeekHasLocalFailure, true);
    transport.seek();
    expect(transport.currentSeekHasLocalFailure, false);
    expect(
      metrics.events
          .where((e) => e['event'] == 'proxy-rejected')
          .single['reason'],
      'handler-capacity',
    );
    // Deliberately held valid streams are not cancelled by seek/full capacity.
    expect(metrics.cancellations, 0);
    // Simulated native stop boundary: no old stream is an active consumer now.
    await transport.retirePlayerRequests().timeout(const Duration(seconds: 3));
    await Future.wait(old);
    expect(transport.snapshot()['activeProxyHandlers'], 0);
    expect(scheduler.active, 0);
    expect(scheduler.queued, 0);
    for (final t in transport.snapshot()['tracks'] as List) {
      expect(t['activeDemands'], 0);
      expect(t['orderedReservationBytes'], 0);
    }
    held.complete();
    cdn.handler = null;
    for (var i = 0; i < 10; i++) {
      transport.seek();
      final results = await Future.wait([
        fetchLocal(urls['video']!, range: 'bytes=-100'),
        fetchLocal(urls['audio']!, range: 'bytes=-100'),
      ]);
      expect(results[0], orderedEquals(bytes.sublist(bytes.length - 100)));
      expect(
        results[1],
        orderedEquals(cdn.audioBytes!.sublist(bytes.length - 100)),
      );
    }
    await transport.settled;
    expect(transport.snapshot()['peakProxyHandlers'], 4);
    expect(transport.snapshot()['proxyHandlerLimit'], 4);
    expect(metrics.terminalFailures, 0);
    expect(metrics.requestFailures, 0);
    expect(
      metrics.events.where((e) => e['cancellation'] == 'player-stopped').length,
      4,
    );
  });
}
