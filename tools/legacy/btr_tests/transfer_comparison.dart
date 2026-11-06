// Short loopback-only comparisons. Run with a package config pinned to each
// production revision; this measures HTTP delivery, never decoded playback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';

import '../../test/btr/fake_cdn.dart';

const mib = 1024 * 1024;
final video = Uint8List.fromList(List.generate(8 * mib, (i) => i % 251));
final audio = Uint8List.fromList(video.map((b) => b ^ 0x55).toList());

bool exact(Uint8List actual, Uint8List expected, int start, int end) {
  if (actual.length != end - start) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[start + i]) return false;
  }
  return true;
}

Future<void> until(bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsedMilliseconds > 3000) throw StateError('fixture timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class Fixture {
  final cdn = FakeCdn(video)..audioBytes = audio;
  final scheduler = BtrScheduler();
  final metrics = BtrMetrics(BtrMode.combined);
  late final BtrTransport transport;
  late final Map<String, String> urls;
  Future<void> start() async {
    await cdn.start();
    transport = BtrTransport(
      mode: BtrMode.combined,
      metrics: metrics,
      scheduler: scheduler,
      network: FakeNetwork(
        scheduler,
        metrics,
        cdn,
        stallTimeout: const Duration(seconds: 3),
        attemptTimeout: const Duration(seconds: 5),
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
    transport.adaptive.connectionBps = mib / .6;
  }

  Future<void> close() async {
    await transport.close();
    await cdn.close();
  }

  Map<String, Object> counts() => {
    'networkBytes': metrics.networkBytes,
    'deliveredBytes': metrics.deliveredBytes,
    'upstreamRequests': cdn.requests.length,
    'hedges': metrics.hedges,
    'peakConnections': scheduler.peak,
    'peakVideoReservation': transport.tracks['video']!.peakReservedBytes,
    'activeAfter': scheduler.active,
    'queuedAfter': scheduler.queued,
  };
}

Future<Map<String, Object?>> steady() async {
  final f = Fixture();
  await f.start();
  f.cdn.handler = (_, _, _) async {
    await Future<void>.delayed(const Duration(milliseconds: 15));
    return false;
  };
  try {
    final watch = Stopwatch()..start();
    final result = await Future.wait([
      fetchLocal(f.urls['video']!, range: 'bytes=0-${8 * mib - 1}'),
      fetchLocal(f.urls['audio']!, range: 'bytes=0-${2 * mib - 1}'),
    ]);
    watch.stop();
    await until(() => f.metrics.deliveredBytes == 10 * mib);
    return {
      'scenario': 'steady-dual-track',
      'elapsedUs': watch.elapsedMicroseconds,
      'exact':
          exact(result[0], video, 0, 8 * mib) &&
          exact(result[1], audio, 0, 2 * mib),
      ...f.counts(),
    };
  } finally {
    await f.close();
  }
}

Future<Map<String, Object?>> overlap(bool seek) async {
  final f = Fixture();
  await f.start();
  f.transport.adaptive.connectionBps = 65536 / .6;
  final gate = Completer<void>();
  f.cdn.handler = (_, range, _) async {
    if (range.start < 3 * mib) await gate.future;
    return false;
  };
  final old = fetchLocal(f.urls['video']!, range: 'bytes=65536-${2 * mib - 1}')
      .then<bool>(
        (b) => exact(b, video, 65536, 2 * mib),
        onError: (Object _) => false,
      );
  try {
    await until(() => f.scheduler.videoActive == 7);
    if (seek) f.transport.seek();
    final watch = Stopwatch()..start();
    int? headUs;
    final fresh =
        fetchLocal(
          f.urls['video']!,
          range: 'bytes=${4 * mib}-${4 * mib + 65535}',
        ).then<bool>((b) {
          headUs = watch.elapsedMicroseconds;
          return exact(b, video, 4 * mib, 4 * mib + 65536);
        }, onError: (Object _) => false);
    final beforeRelease = await Future.any([
      fresh,
      Future<bool>.delayed(const Duration(milliseconds: 700), () => false),
    ]);
    gate.complete();
    final oldExact = await old, freshExact = await fresh;
    if (oldExact && freshExact) {
      await until(() => f.metrics.deliveredBytes == 2 * mib);
    }
    return {
      'scenario': seek ? 'overlap-new-generation' : 'overlap-same-generation',
      'headBefore700msRelease': beforeRelease,
      'headUs': headUs,
      'oldExact': oldExact,
      'freshExact': freshExact,
      ...f.counts(),
    };
  } finally {
    if (!gate.isCompleted) gate.complete();
    await old;
    await f.close();
  }
}

class GateResponse implements HttpResponse {
  GateResponse(this.inner, this.entered, this.release);
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

class GateRequest implements HttpRequest {
  GateRequest(this.inner, Completer<void> entered, Completer<void> release)
    : response = GateResponse(inner.response, entered, release);
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

Future<Map<String, Object?>> completedPrefetch() async {
  final f = Fixture();
  await f.start();
  final entered = Completer<void>(),
      release = Completer<void>(),
      done = Completer<void>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) async {
    await f.transport.tracks['video']!.serve(GateRequest(r, entered, release));
    done.complete();
  });
  final old =
      fetchLocal(
        'http://127.0.0.1:${server.port}/old',
        range: 'bytes=65536-2162687',
      ).then<bool>(
        (b) => exact(b, video, 65536, 2162688),
        onError: (Object _) => false,
      );
  try {
    await entered.future;
    await until(() => f.scheduler.active == 0);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    f.transport.seek();
    final fresh = await fetchLocal(
      f.urls['video']!,
      range: 'bytes=${4 * mib}-${4 * mib + 65535}',
    );
    final watch = Stopwatch()..start();
    release.complete();
    final oldExact = await old;
    await done.future;
    return {
      'scenario': 'completed-prefetch',
      'oldExact': oldExact,
      'freshExact': exact(fresh, video, 4 * mib, 4 * mib + 65536),
      'oldResumeUs': watch.elapsedMicroseconds,
      'firstPrefetchFetches': f.cdn.requests
          .where((r) => r.$2.start == 131072)
          .length,
      ...f.counts(),
    };
  } finally {
    if (!release.isCompleted) release.complete();
    await old;
    await server.close(force: true);
    await f.close();
  }
}

Future<void> main() async {
  final results = <Map<String, Object?>>[];
  // Three small samples show local timing spread; not a load/endurance test.
  for (var trial = 0; trial < 3; trial++) {
    for (final run in [
      steady,
      () => overlap(false),
      () => overlap(true),
      completedPrefetch,
    ]) {
      results.add({'trial': trial + 1, ...await run()});
    }
  }
  print(
    const JsonEncoder.withIndent('  ').convert({
      'variant': Platform.environment['BTR_VARIANT'],
      'scope':
          'loopback Fake CDN HTTP bytes; no native player or public network',
      'results': results,
    }),
  );
}
