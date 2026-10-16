import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:test_api/scaffolding.dart';
import 'package:matcher/expect.dart';

import 'fake_cdn.dart';

void main() {
  late FakeCdn cdn;
  late BtrScheduler scheduler;
  late BtrTransport transport;
  late BtrMetrics metrics;
  late Map<String, String> urls;
  final data = Uint8List.fromList(
    List.generate(6 * 1024 * 1024 + 133, (i) => (i * 97 + (i ~/ 131)) % 251),
  );

  Future<void> start({
    BtrMode mode = BtrMode.combined,
    bool audio = false,
    bool peerOnly = false,
    Duration stall = const Duration(milliseconds: 150),
    BtrSettings settings = const BtrSettings(),
  }) async {
    metrics = BtrMetrics(mode);
    scheduler = BtrScheduler();
    transport = BtrTransport(
      mode: mode,
      metrics: metrics,
      settings: settings,
      scheduler: scheduler,
      network: FakeNetwork(scheduler, metrics, cdn, stallTimeout: stall),
    );
    urls = await transport.start([
      BtrTrackSpec(
        kind: 'video',
        urls: [
          peerOnly ? 'https://a.mcdn.bilivideo.cn/upgcxcode/video.m4s' : 'https://origin.bilivideo.com/upgcxcode/video.m4s?token=never-log',
        ],
      ),
      if (audio)
        BtrTrackSpec(
          kind: 'audio',
          urls: ['https://origin.bilivideo.com/upgcxcode/audio.m4s'],
        ),
    ]);
  }

  setUp(() async {
    cdn = FakeCdn(data);
    await cdn.start();
  });
  tearDown(() async {
    await transport.close();
    await cdn.close();
  });

  test(
    'peer-only DASH fails closed without contacting a peer or native fallback',
    () async {
      await start(peerOnly: true);
      await expectLater(fetchLocal(urls['video']!), throwsA(anything));
      expect(cdn.requests, isEmpty);
      expect(transport.tracks['video']!.terminal, isTrue);
    },
  );

  test('same length and ETag with different CDN bytes never mix', () async {
    final alternate = Uint8List.fromList(data.map((b) => b ^ 0x33).toList());
    cdn.handler = (r, range, n) async {
      if (!r.uri.path.contains(BtrSourcePolicy.preferred)) return false;
      r.response.statusCode = 206;
      r.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/${alternate.length}',
      );
      r.response.headers.set('etag', '"fixture-v1"');
      r.response.contentLength = range.length;
      r.response.add(
        Uint8List.sublistView(alternate, range.start, range.end + 1),
      );
      await r.response.close();
      return true;
    };
    await start();
    expect(await fetchLocal(urls['video']!), orderedEquals(alternate));
    expect(
      cdn.requests
          .where((r) => r.$2.start > 0)
          .every((r) => r.$1.contains(BtrSourcePolicy.preferred)),
      isTrue,
    );
  });

  test('all rejected CDN responses stop after bounded discovery without retry loop', () async {
    cdn.handler = (r, range, n) async {
      r.response.statusCode = 403;
      await r.response.close();
      return true;
    };
    await start();
    await expectLater(fetchLocal(urls['video']!), throwsA(anything));
    await transport.settled;
    expect(cdn.requests.length, inInclusiveRange(1, 9));
    final before = cdn.requests.length;
    await expectLater(fetchLocal(urls['video']!), throwsA(anything));
    expect(cdn.requests.length, before);
    expect(scheduler.active, 0);
  });

  test(
    'unsupported Range on preferred host selects a validated backup',
    () async {
      cdn.handler = (r, range, n) async {
        if (!r.uri.path.contains(BtrSourcePolicy.preferred)) return false;
        r.response.statusCode = 200;
        await r.response.close();
        return true;
      };
      await start();
      expect(
        await fetchLocal(urls['video']!, range: 'bytes=12345-98765'),
        orderedEquals(data.sublist(12345, 98766)),
      );
      expect(
        transport.tracks['video']!.sample!.identity.uri.host,
        isNot(BtrSourcePolicy.preferred),
      );
    },
  );

  test(
    'parallel shuffled responses preserve every byte and bounded order',
    () async {
      final audioData = Uint8List.fromList(data.map((b) => b ^ 0x55).toList());
      cdn
        ..audioBytes = audioData
        ..handler = (r, range, n) async {
          if (range.start == 65536) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          return false;
        };
      await start(audio: true);
      final results = await Future.wait([
        fetchLocal(urls['video']!),
        fetchLocal(urls['audio']!),
      ]);
      expect(results[0], orderedEquals(data));
      expect(results[1], orderedEquals(audioData));
      await transport.settled;
      expect(scheduler.peak, inInclusiveRange(2, 8));
      expect(metrics.deliveredBytes, 2 * data.length);
      for (final track in transport.tracks.values) {
        expect(track.peakReservedBytes, lessThanOrEqualTo(4 * 1024 * 1024));
      }
      expect(metrics.snapshot().toString(), isNot(contains('never-log')));
      expect(scheduler.active, 0);
    },
  );

  test('retry resumes a verified partial prefix with exact If-Range', () async {
    var broken = false;
    cdn.handler = (r, range, n) async {
      if (!broken && range.start == 65536) {
        broken = true;
        r.response.statusCode = 206;
        r.response.headers.set(
          'content-range',
          'bytes ${range.start}-${range.end}/${data.length}',
        );
        r.response.headers.set('etag', '"fixture-v1"');
        r.response.contentLength = range.length;
        r.response.add(data.sublist(range.start, range.start + 32768));
        await r.response.flush();
        r.response.deadline = Duration.zero;
        return true;
      }
      return false;
    };
    await start();
    expect(await fetchLocal(urls['video']!), orderedEquals(data));
    expect(
      cdn.requests.any((q) => q.$2.start == 98304 && q.$3 == '"fixture-v1"'),
      isTrue,
    );
    expect(metrics.resumedBytes, greaterThanOrEqualTo(32768));
    expect(scheduler.active, 0);
  });

  for (final fault in ['etag', 'range', 'encoding', 'redirect', 'overrun']) {
    test('$fault corruption never yields successful media and fails boundedly', () async {
      cdn.handler = (r, range, n) async {
        if (range.start == 0) return false; // discovery only
        r.response.statusCode = fault == 'redirect' ? 302 : 206;
        r.response.headers.set(
          'content-range',
          'bytes ${range.start + (fault == 'range' ? 1 : 0)}-${range.end}/${data.length}',
        );
        r.response.headers.set(
          'etag',
          fault == 'etag' ? '"different"' : '"fixture-v1"',
        );
        if (fault == 'redirect') {
          r.response.headers.set(
            'location',
            'https://example.invalid/forbidden',
          );
        }
        if (fault == 'encoding') {
          r.response.headers.set('content-encoding', 'gzip');
        }
        r.response.add(data.sublist(range.start, range.end + 1));
        if (fault == 'overrun') r.response.add([9]);
        await r.response.close();
        return true;
      };
      await start();
      await expectLater(fetchLocal(urls['video']!), throwsA(anything));
      expect(cdn.requests.length, lessThan(35));
      expect(transport.tracks['video']!.terminal, isTrue);
      final count = cdn.requests.length;
      await expectLater(fetchLocal(urls['video']!), throwsA(anything));
      expect(cdn.requests.length, count);
      expect(scheduler.active, 0);
    });
  }

  for (final tag in <String?>[null, 'W/"weak"']) {
    test('validator $tag uses one response without segmentation', () async {
      cdn.etag = tag;
      await start();
      expect(await fetchLocal(urls['video']!), orderedEquals(data));
      expect(cdn.requests.where((q) => q.$2.end == data.length - 1).length, 1);
      expect(transport.tracks['video']!.peakReservedBytes, 0);
      expect(metrics.hedges, 0);
    });
  }

  test(
    'CDN preference selects a validated source while retaining segmented transport',
    () async {
      const preferred = 'upos-sz-mirrorcos.bilivideo.com';
      await start(settings: const BtrSettings(preferredCdn: preferred));
      expect(await fetchLocal(urls['video']!), orderedEquals(data));
      expect(
        transport.tracks['video']!.sample!.identity.uri.host,
        preferred,
      );
      expect(cdn.requests.length, greaterThan(2));
      expect(transport.tracks['video']!.peakReservedBytes, greaterThan(0));
    },
  );

  test(
    'unavailable preferred source falls back; equal ETag never permits mixing',
    () async {
      cdn.handler = (r, range, n) async {
        if (r.uri.path.contains(BtrSourcePolicy.preferred)) {
          r.response.statusCode = 403;
          await r.response.close();
          return true;
        }
        return false;
      };
      await start();
      expect(await fetchLocal(urls['video']!), orderedEquals(data));
      final used = cdn.requests
          .where((q) => q.$2.start > 0)
          .map((q) => q.$1.split('/')[1])
          .toSet();
      expect(used.length, 1);
      expect(used, isNot(contains(BtrSourcePolicy.preferred)));
    },
  );

  test(
    'seek cancels old work and new offset is exact, including suffix range',
    () async {
      cdn.handler = (r, range, n) async {
        if (range.start > 0 && range.start < 500000) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return false;
      };
      await start(stall: const Duration(seconds: 1));
      final old = fetchLocal(urls['video']!);
      final failedOld = expectLater(old, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      transport.seek();
      final next = await fetchLocal(
        urls['video']!,
        range: 'bytes=1000000-1100000',
      );
      expect(next, orderedEquals(data.sublist(1000000, 1100001)));
      await failedOld;
      expect(
        await fetchLocal(urls['video']!, range: 'bytes=-100'),
        orderedEquals(data.sublist(data.length - 100)),
      );
      expect(transport.tracks['video']!.terminal, isFalse);
      expect(scheduler.active, 0);
    },
  );

  test(
    'HEAD reports metadata; invalid range causes no media request',
    () async {
      await start();
      final client = HttpClient();
      try {
        final req = await client.headUrl(Uri.parse(urls['video']!));
        req.headers.set('range', 'bytes=100-150');
        final response = await req.close();
        expect(response.statusCode, 200);
        expect(response.contentLength, data.length);
        expect(await response.fold<int>(0, (s, v) => s + v.length), 0);
        final count = cdn.requests.length;
        await expectLater(
          fetchLocal(urls['video']!, range: 'bytes=99999999-'),
          throwsA(anything),
        );
        expect(cdn.requests.length, count);
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'capability, Host and browser Origin restrictions reject locally',
    () async {
      await start();
      await expectLater(
        fetchLocal(urls['video']!.replaceFirst('/video', '/unknown')),
        throwsA(anything),
      );
      await expectLater(
        fetchLocal(urls['video']!, headers: {'Origin': 'https://evil.invalid'}),
        throwsA(anything),
      );
      await expectLater(
        fetchLocal(urls['video']!, headers: {'Host': 'evil.invalid'}),
        throwsA(anything),
      );
      expect(cdn.requests, isEmpty);
    },
  );

  test(
    'head hedge rescues stalled connection and releases losing socket',
    () async {
      var held = false;
      cdn.handler = (r, range, n) async {
        if (range.start == 1000000 && !held) {
          held = true;
          await Future<void>.delayed(const Duration(milliseconds: 1300));
        }
        return false;
      };
      await start(stall: const Duration(seconds: 2));
      await transport.tracks['video']!.initialize();
      transport.adaptive.pieceMs = 0;
      final watch = Stopwatch()..start();
      expect(
        await fetchLocal(urls['video']!, range: 'bytes=1000000-1065535'),
        orderedEquals(data.sublist(1000000, 1065536)),
      );
      expect(watch.elapsedMilliseconds, lessThan(1250));
      expect(metrics.hedges, 1);
      expect(scheduler.active, 0);
    },
  );

  test(
    'closing session during discovery drains requests and listener',
    () async {
      cdn.handler = (r, range, n) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return false;
      };
      await start();
      final fetch = expectLater(fetchLocal(urls['video']!), throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transport.close();
      await fetch;
      expect(scheduler.active, 0);
      expect(scheduler.queued, 0);
      await expectLater(fetchLocal(urls['video']!), throwsA(anything));
    },
  );

  for (final count in [4, 128]) {
    test(
      'manual $count keeps byte correctness, refusal backoff and bounded cleanup',
      () async {
        var refused = false;
        cdn.handler = (r, range, n) async {
          if (range.start > 0 && !refused) {
            refused = true;
            r.response.statusCode = 429;
            await r.response.close();
            return true;
          }
          return false;
        };
        await start(
          audio: true,
          settings: BtrSettings(autoConcurrency: false, manualThreads: count),
        );
        final results = await Future.wait([
          fetchLocal(urls['video']!),
          fetchLocal(urls['audio']!),
        ]);
        for (final result in results) {
          expect(result, orderedEquals(data));
        }
        await transport.settled;
        expect(scheduler.limit, count.clamp(2, 16) ~/ 2);
        expect(scheduler.peak, lessThanOrEqualTo(count.clamp(2, 16)));
        expect(metrics.retries, greaterThan(0));
        expect(metrics.requestFailures, greaterThan(0));
        expect(metrics.deliveredByTrack, {
          'video': data.length,
          'audio': data.length,
        });
        expect(metrics.networkByTrack.keys, containsAll(['video', 'audio']));
        final snapshot = transport.snapshot();
        expect(snapshot['configuredConcurrencyLimit'], count);
        expect(snapshot['activeConnections'], 0);
        expect(snapshot['queuedConnections'], 0);
        for (final track in transport.tracks.values) {
          expect(track.peakReservedBytes, lessThanOrEqualTo(4 * 1024 * 1024));
        }
      },
    );
  }

  test('failed user-preferred CDN uses validated fallback and reports failure without secrets', () async {
    const preferred = 'upos-sz-mirrorcos.bilivideo.com';
    cdn.handler = (r, range, n) async {
      if (!r.uri.path.contains(preferred)) return false;
      r.response.statusCode = 403;
      await r.response.close();
      return true;
    };
    await start(settings: const BtrSettings(preferredCdn: preferred));
    expect(await fetchLocal(urls['video']!), orderedEquals(data));
    expect(
      transport.tracks['video']!.sample!.identity.uri.host,
      isNot(preferred),
    );
    expect(transport.tracks['video']!.selectionState, 'selected');
    expect(metrics.discoveryFailures, greaterThan(0));
    final report = '${metrics.snapshot()} ${transport.snapshot()}';
    expect(report, contains('source-failed'));
    for (final secret in ['never-log', 'https://', 'Cookie', 'Authorization']) {
      expect(report, isNot(contains(secret)));
    }
  });

  test('original mode never creates a proxy or makes a CDN request', () async {
    metrics = BtrMetrics(BtrMode.original);
    transport = BtrTransport(mode: BtrMode.original, metrics: metrics);
    await expectLater(
      transport.start([
        BtrTrackSpec(
          kind: 'video',
          urls: ['https://origin.bilivideo.com/video.m4s'],
        ),
      ]),
      throwsStateError,
    );
    expect(transport.tracks, isEmpty);
    expect(cdn.requests, isEmpty);
    expect(metrics.snapshot()['networkBytesIncludingProbesAndHedges'], isNull);
  });
}
