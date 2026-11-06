import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/btr/diagnostics.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

Map<String, Object?> session({bool ended = false, int noise = 0}) {
  final metrics = BtrMetrics(BtrMode.combined, clock: () => 120000)
    ..playing = true
    ..ended = ended
    ..nativeTracks(1, true)
    ..sampleNativeAv(
      (key) => switch (key) {
        'current-ao' => 'aaudio',
        'current-vo' => 'gpu',
        'audio-pts' => '123.5',
        'time-pos' => '123.52',
        'avsync' => '0.02',
        _ => '',
      },
    )
    ..received('video', 5000000)
    ..received('audio', 100000)
    ..delivered('video', 3000000)
    ..delivered('audio', 90000)
    ..hedges = noise ~/ 2
    ..resumes = noise ~/ 2;
  for (var i = 0; i < noise; i++) {
    metrics.event(i.isEven ? 'hedge' : 'resume', {
      'track': 'video',
      'prefixBytes': i * 32768,
    });
  }
  metrics
    ..event('request-failed', {'phase': 'body', 'reason': 'timeout'})
    ..event('demand-ended', {
      'stage': 'proxy-write',
      'reason': 'timeout',
      'outcome': 'local-error',
    })
    ..seek(123000)
    ..playerError(
      'https://secret.invalid/?token=secret Cookie: private',
      transportTerminal: false,
    )
    ..nativeLog(
      'ao/private-device',
      'error',
      'Authorization: secret ETag: private',
    );
  final data = metrics.snapshot();
  final events = data.remove('events');
  return {
    ...data,
    'sessionSettings': {'mode': 'combined', ...const BtrSettings().options},
    'activeConnections': 12,
    'queuedConnections': 4,
    'concurrencyLimit': 16,
    'videoConnections': 10,
    'audioConnections': 2,
    'activeProxyHandlers': 3,
    'peakProxyHandlers': 4,
    'proxyHandlerLimit': 4,
    'proxyCapacityRejections': 2,
    'proxyLocalResponseFailures': 1,
    'tracks': [
      for (final track in ['video', 'audio'])
        {
          'kind': track,
          'host': '$track.bilivideo.com',
          'selection': 'selected',
          'identity': 'single-origin-strong-etag',
          'terminal': false,
          'activeDemands': 2,
          'orderedReservationBytes': 4 * 1024 * 1024,
          'demands': [
            for (var id = 0; id < 2; id++)
              {
                'request': id,
                'generation': 3,
                'stage': 'upstream',
                'ageMs': 1500,
                'progressAgeMs': 700,
                'deliveredBytes': 65536,
                'orderedReservationBytes': 2 * 1024 * 1024,
                'prefetchDeprioritized': id == 0,
              },
          ],
          'health': {
            for (var i = 0; i < 9; i++)
              'cdn$i.bilivideo.com': {'state': 'healthy', 'bps': 1000000},
          },
        },
    ],
    'events': events,
  };
}

Map<String, Object?> report({Map<String, Object?>? current, int history = 0}) =>
    BtrDiagnostics.report(
      selectedSettings: {'mode': 'combined', ...const BtrSettings().options},
      current: current,
      recent: List.generate(history, (_) => session(ended: true, noise: 350)),
    );

void main() {
  test(
    'full report retains every snapshot field, counters, events and history',
    () {
      final data = report(current: session(noise: 350), history: 8);
      final json = BtrDiagnostics.full(data);
      expect(jsonDecode(json), data);
      expect((data['recent'] as List).length, 8);
      final current = data['current'] as Map;
      expect((current['events'] as List).length, 128);
      expect(current['eventsDropped'], greaterThan(200));
      expect(current['hedges'], 175);
      expect(current['resumes'], 175);
      expect(json.length, greaterThan(20000));
    },
  );

  test('long UTF-8 JSON survives real file write/read with exact bytes', () async {
    final data = report(current: session(noise: 350), history: 8);
    data['units'] = '${data['units']}; 診斷測試 🎬';
    final text = BtrDiagnostics.full(data);
    final bytes = BtrDiagnostics.utf8Bytes(text);
    final base = Directory('${Directory.current.path}/.dart_tool');
    await base.create(recursive: true);
    final dir = await base.createTemp('btr-export-');
    try {
      final file = File('${dir.path}/diagnostics.json');
      await file.writeAsBytes(bytes, flush: true);
      final read = await file.readAsBytes();
      expect(read, bytes);
      expect(await file.length(), bytes.length);
      expect(utf8.decode(read), text);
      expect(jsonDecode(utf8.decode(read)), data);
      expect(bytes.length, greaterThan(text.length));
      // Record the measured UTF-8 size in the test evidence.
      // ignore: avoid_print
      print(
        'Long diagnostic: ${text.length} characters / ${bytes.length} UTF-8 bytes; 8 recent sessions; exact disk read-back PASS',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('normal short session remains complete and parseable', () {
    final data = report(current: session());
    expect(jsonDecode(BtrDiagnostics.full(data)), data);
    expect(
      (jsonDecode(BtrDiagnostics.compact(data)) as Map)['current'],
      isNotNull,
    );
  });

  test(
    'compact keeps performance, tracks, CDN and GET generations before events',
    () {
      final json = BtrDiagnostics.compact(
        report(current: session(noise: 350), history: 8),
      );
      final compact = jsonDecode(json) as Map;
      final current = compact['current'] as Map;
      for (final key in [
        'schema',
        'buildId',
        'sessionSettings',
        'playbackState',
        'elapsedMs',
        'startupTimelineMs',
        'seekTimelineMs',
        'bufferingEvents',
        'networkBps5s',
        'loopbackDeliveredBps5s',
        'networkBpsByTrack5s',
        'loopbackDeliveredBpsByTrack5s',
        'activeConnections',
        'queuedConnections',
        'concurrencyLimit',
        'videoConnections',
        'audioConnections',
        'activeProxyHandlers',
        'proxyHandlerLimit',
        'requestFailures',
        'terminalFailures',
        'retries',
        'hedges',
        'resumes',
        'upstreamCancellations',
        'proxyCapacityRejections',
        'proxyLocalResponseFailures',
        'eventsDropped',
        'nativeAvProbe',
        'nativeAudioSelected',
        'nativeErrorKinds',
      ]) {
        expect(current.containsKey(key), isTrue, reason: key);
      }
      final tracks = current['tracks'] as List;
      expect(tracks.length, 2);
      expect((tracks[0] as Map)['host'], 'video.bilivideo.com');
      expect((tracks[1] as Map)['host'], 'audio.bilivideo.com');
      expect(((tracks[0] as Map)['demands'] as List)[0]['generation'], 3);
      expect(current['hedges'], 175);
      expect(current['resumes'], 175);
      expect((current['nativeAvProbe'] as Map)['audio-pts'], 123.5);
      expect(json.indexOf('"tracks"'), lessThan(json.indexOf('"events"')));
      expect(
        json.indexOf('"activeConnections"'),
        lessThan(json.indexOf('"events"')),
      );
      expect(
        utf8.encode(json).length,
        lessThanOrEqualTo(BtrDiagnostics.compactBudgetBytes),
      );
      // ignore: avoid_print
      print('Compact diagnostic: ${utf8.encode(json).length} UTF-8 bytes');
    },
  );

  test('compact summarizes noise and labels omitted context without mutating full data', () {
    final source = report(current: session(noise: 350), history: 8);
    final before = BtrDiagnostics.full(source);
    final compact = jsonDecode(BtrDiagnostics.compact(source)) as Map;
    final current = compact['current'] as Map;
    final events = current['events'] as List;
    expect(events.length, lessThanOrEqualTo(6));
    expect(
      events.any((e) => e['event'] == 'hedge' || e['event'] == 'resume'),
      isFalse,
    );
    expect((current['eventSummary'] as Map)['counts']['hedge'], greaterThan(0));
    expect(events.any((e) => e['event'] == 'seek'), isTrue);
    expect(current.containsKey('previousNativeAvProbe'), isFalse);
    expect((compact['omissions'] as Map)['fullExport'], contains('JSON'));
    expect(BtrDiagnostics.full(source), before);
  });

  test('byte-budget overflow is structural, explicit and retains critical evidence', () {
    final current = session();
    // Future growth in a critical track snapshot is never silently sliced.
    (current['tracks'] as List).first['futureDiagnostic'] = 'x' * 15000;
    final compact = jsonDecode(
      BtrDiagnostics.compact(report(current: current, history: 8)),
    ) as Map;
    expect(compact['sizePolicy']['exceeded'], isTrue);
    expect(compact['current']['tracks'], current['tracks']);
    expect(compact['current']['events'], isEmpty);
    expect(compact['recent'], isEmpty);
  });

  test('empty and original mode preserve unknown metrics and version', () {
    final empty = report();
    for (final text in [
      BtrDiagnostics.full(empty),
      BtrDiagnostics.compact(empty),
    ]) {
      final decoded = jsonDecode(text) as Map;
      expect(decoded['current'], isNull);
      expect(decoded['recent'], isEmpty);
      expect(decoded['buildId'], 'unidentified');
    }
    final m = BtrMetrics(BtrMode.original).snapshot();
    final compact =
        jsonDecode(BtrDiagnostics.compact(report(current: m))) as Map;
    expect(compact['current']['networkBps5s'], isNull);
    expect(compact['current']['loopbackDeliveredBps5s'], isNull);
    expect(compact['current']['retries'], isNull);
    expect((compact['current'] as Map).containsKey('tracks'), isFalse);
    expect(compact['omissions']['recentSessions'], 0);
  });

  test('latest ended session is retained when no session is active', () {
    final compact =
        jsonDecode(BtrDiagnostics.compact(report(history: 8))) as Map;
    expect(compact['current'], isNull);
    expect(compact['recent'].length, 1);
    expect(compact['recent'][0]['sessionEnded'], isTrue);
    expect(compact['recent'][0]['tracks'].length, 2);
    expect(compact['omissions']['recentSessions'], 7);
  });

  test('privacy-safe error categories survive full and compact exports', () {
    final source = report(current: session(noise: 350), history: 8);
    for (final text in [
      BtrDiagnostics.full(source),
      BtrDiagnostics.compact(source),
    ]) {
      for (final secret in [
        'secret',
        'private-device',
        'https://',
        'Cookie:',
        'Authorization:',
        'ETag:',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('single-origin-strong-etag'));
      expect(text, contains('"units"'));
    }
  });

  test('export filename contains only build and UTC timestamp', () {
    final name = BtrDiagnostics.fileName(DateTime.utc(2026, 10, 18, 4, 5, 6));
    expect(name, 'btr-unidentified-2026-10-18T04-05-06-000Z.json');
    expect(name, matches(RegExp(r'^btr-[A-Za-z0-9._-]+\.json$')));
  });
}
