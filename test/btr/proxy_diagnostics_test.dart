import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/diagnostics.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/proxy_diagnostics.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

import 'demand_lifecycle_test.dart' show waitUntil;
import 'fake_cdn.dart';

void main() {
  late FakeCdn cdn;
  late BtrTransport transport;
  late BtrMetrics metrics;
  late Map<String, String> urls;
  final data = Uint8List.fromList(
    List.generate(8 * 1024 * 1024, (i) => i % 251),
  );

  setUp(() async {
    cdn = FakeCdn(data);
    await cdn.start();
    metrics = BtrMetrics(BtrMode.combined);
    final scheduler = BtrScheduler();
    transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(
        scheduler,
        metrics,
        cdn,
        stallTimeout: const Duration(seconds: 5),
        attemptTimeout: const Duration(seconds: 10),
      ),
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

  Map ledger() => transport.snapshot()['proxyLifecycle'] as Map;
  List<Map> rejections() => (ledger()['rejections'] as List).cast<Map>();
  List<Map> lifecycle() => (ledger()['lifecycle'] as List).cast<Map>();

  void recordObservation(String scenario, Map observation) {
    // ignore: avoid_print
    print(jsonEncode({'scenario': scenario, 'observation': observation}));
  }

  Completer<void> holdUpstream() {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    cdn.handler = (_, range, _) async {
      if (range.start >= 131072) await gate.future;
      return false;
    };
    return gate;
  }

  Future<Uint8List> read(int i) => fetchLocal(
    urls[i.isEven ? 'video' : 'audio']!,
    range: 'bytes=131072-196607',
  );

  test('response saturation records exact 8/4 state and preserves all valid GET bytes across seeks', () async {
    final gate = holdUpstream();
    final reads = <Future<Uint8List>>[];
    for (var i = 0; i < 8; i++) {
      if (i.isEven) transport.seek();
      reads.add(read(i));
      await waitUntil(
        () => transport.snapshot()['openProxyResponses'] == i + 1,
      );
    }
    final checked = Future.wait(reads);
    await waitUntil(() => transport.snapshot()['openProxyResponses'] == 8);
    await expectLater(
      read(8),
      throwsA(isA<BtrFailure>().having((e) => e.status, 'status', 503)),
    );
    final rejected = rejections().single;
    expect(rejected['capacityCause'], 'response-limit');
    expect(rejected['openResponses'], 8);
    expect(rejected['trackedResponses'], 8);
    expect(rejected['activeHandlers'], 4);
    expect(rejected['pendingAdmissions'], 4);
    expect(rejected['admissionWaitMs'], 0);
    final captured = (rejected['responses'] as List).cast<Map>();
    expect(captured.where((r) => r['phase'] == 'handler-wait'), hasLength(4));
    expect(
      captured.every((r) => r['consumerValidity'] == 'unobservable'),
      isTrue,
    );
    expect(captured.every((r) => r['responseDone'] == 'pending'), isTrue);
    recordObservation('response-limit', rejected);
    for (var i = 0; i < 5; i++) {
      await expectLater(
        read(8),
        throwsA(isA<BtrFailure>().having((e) => e.status, 'status', 503)),
      );
    }
    expect(rejections(), hasLength(BtrProxyDiagnostics.rejectionLimit));
    expect(ledger()['droppedRejections'], 2);
    gate.complete();
    for (final bytes in await checked) {
      expect(bytes, orderedEquals(data.sublist(131072, 196608)));
    }
    await transport.settled;
    expect(metrics.cancellations, 0);
    expect(transport.snapshot()['openProxyResponses'], 0);
    expect(transport.snapshot()['activeProxyHandlers'], 0);
    expect(ledger()['activeResponses'], isEmpty);
    expect(lifecycle().where((e) => e['event'] == 'released'), hasLength(8));
    recordObservation('valid-get-release', {
      'byteExactResponses': reads.length,
      'openResponses': transport.snapshot()['openProxyResponses'],
      'activeHandlers': transport.snapshot()['activeProxyHandlers'],
      'cancellations': metrics.cancellations,
    });
    // Releasing/changing current requests cannot rewrite a rejection snapshot.
    expect(captured.every((r) => r['releasedAtMs'] == null), isTrue);
    expect(rejections().every((r) => r['openResponses'] == 8), isTrue);
    expect(transport.scheduler.peak, lessThanOrEqualTo(16));
  });

  test('execution wait timeout is distinct from response saturation and releases its own admission', () async {
    final gate = holdUpstream();
    final old = Future.wait(List.generate(4, read));
    await waitUntil(() => transport.snapshot()['activeProxyHandlers'] == 4);
    await expectLater(
      read(4),
      throwsA(isA<BtrFailure>().having((e) => e.status, 'status', 503)),
    );
    final rejected = rejections().single;
    expect(rejected['capacityCause'], 'execution-timeout');
    expect(rejected['openResponses'], 5);
    expect(rejected['activeHandlers'], 4);
    expect(rejected['pendingAdmissions'], 1);
    expect(rejected['admissionWaitMs'], greaterThanOrEqualTo(1900));
    recordObservation('execution-timeout', rejected);
    await waitUntil(() => transport.snapshot()['openProxyResponses'] == 4);
    final released = lifecycle().singleWhere((e) => e['event'] == 'released');
    expect(released['proxyRequest'], rejected['proxyRequest']);
    expect(released['openResponses'], 4);
    expect(released['serverCloseRequested'], isTrue);
    gate.complete();
    for (final bytes in await old) {
      expect(bytes, orderedEquals(data.sublist(131072, 196608)));
    }
    await transport.settled;
    expect(transport.snapshot()['openProxyResponses'], 0);
    expect(metrics.cancellations, 0);
  });

  test('a paused valid consumer retains its response and resumes byte-exactly after seeks', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.getUrl(Uri.parse(urls['video']!));
    final response = await req.close();
    final collected = BytesBuilder(copy: false), received = Completer<void>();
    final first = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (bytes) {
        collected.add(bytes);
        if (!first.isCompleted) {
          subscription.pause();
          first.complete();
        }
      },
      onDone: received.complete,
      onError: received.completeError,
    );
    await first.future;
    await waitUntil(() => transport.snapshot()['parkedProxyWriters'] == 1);
    for (var i = 0; i < 3; i++) {
      transport.seek();
    }
    final active = (ledger()['activeResponses'] as List).single as Map;
    expect(active['backpressured'], isTrue);
    expect(active['responseDone'], 'pending');
    expect(active['consumerValidity'], 'unobservable');
    expect(transport.snapshot()['openProxyResponses'], 1);
    expect(metrics.cancellations, 0);
    subscription.resume();
    await received.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    expect(collected.takeBytes(), orderedEquals(data));
    await transport.settled;
    expect(ledger()['activeResponses'], isEmpty);
    expect(transport.snapshot()['openProxyResponses'], 0);
  });

  test('client close observations stay separate from response completion and capacity release', () async {
    // Keep later bytes upstream so close cannot race with a fully sent body.
    cdn.handler = (_, range, _) async {
      if (range.start >= 65536) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return false;
    };
    final uri = Uri.parse(urls['video']!);
    final socket = await Socket.connect(uri.host, uri.port);
    addTearDown(socket.destroy);
    final first = Completer<void>();
    final subscription = socket.listen((_) {
      if (!first.isCompleted) first.complete();
    }, onError: (Object _) {});
    socket.write(
      'GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nRange: bytes=0-\r\n\r\n',
    );
    await socket.flush();
    await first.future;
    final beforeClose = (ledger()['activeResponses'] as List).single as Map;
    expect(beforeClose['deliveredBytes'], lessThan(data.length));
    final closeAt = metrics.now() - metrics.openedAt;
    socket.destroy();
    await transport.settled.timeout(const Duration(seconds: 18));
    await subscription.cancel();
    expect(transport.snapshot()['openProxyResponses'], 0);
    expect(transport.scheduler.active, 0);
    final done = lifecycle()
        .where((e) => e['event'] == 'response-done')
        .toList();
    expect(done, hasLength(1));
    expect(done.single['responseDone'], isIn(['completed', 'error']));
    final released = lifecycle().singleWhere((e) => e['event'] == 'released');
    // A peer close request does not prove the server observed an abandoned GET:
    // this Windows loopback can still complete the response. Check the recorded
    // outcome against actual byte/close state, without reclassifying completion
    // as cancellation or claiming Android disconnect coverage from this case.
    if (released['outcome'] == 'complete') {
      expect(released['deliveredBytes'], data.length);
      expect(released['serverCloseRequested'], isTrue);
      expect(released['serverDeadlineApplied'], isFalse);
    } else {
      expect(released['deliveredBytes'], lessThan(data.length));
      expect(
        released['serverDeadlineApplied'] == true ||
            released['cancellation'] != null,
        isTrue,
      );
    }
    // Record what the actual Dart socket reported without imposing a fictitious
    // promise that FIN/error detection must precede a write timeout.
    // ignore: avoid_print
    print(
      jsonEncode({
        'clientCloseRequestedAtMs': closeAt,
        'clientCloseLifecycle': lifecycle(),
      }),
    );
  });

  test('lifecycle evidence is bounded, immutable and exported without request secrets', () async {
    for (var i = 0; i < 24; i++) {
      await fetchLocal(urls['video']!, range: 'bytes=0-31');
    }
    await transport.settled;
    expect(lifecycle().length, BtrProxyDiagnostics.lifecycleLimit);
    expect(ledger()['droppedLifecycle'], greaterThan(0));
    expect(ledger()['activeResponses'], isEmpty);
    final report = BtrDiagnostics.report(
      selectedSettings: {},
      current: transport.snapshot(),
      recent: [],
    );
    for (final text in [
      BtrDiagnostics.full(report),
      BtrDiagnostics.compact(report),
    ]) {
      final decoded = jsonDecode(text) as Map;
      expect(
        decoded['current']['proxyLifecycle'],
        (report['current'] as Map)['proxyLifecycle'],
      );
      expect(text, isNot(contains('http://')));
      expect(text, isNot(contains('fixture-v1')));
      expect(
        text,
        isNot(contains(Uri.parse(urls['video']!).pathSegments.first)),
      );
    }
  });
}
