import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test(
    'AV probes are bounded numeric observations and retain pre-EOF evidence',
    () {
      var now = 1000;
      final m = BtrMetrics(BtrMode.combined, clock: () => now);
      expect(m.snapshot()['nativeAvProbe'], isNull);
      m
        ..sampleNativeAv(
          (key) => switch (key) {
            'audio-pts' => '12.5',
            'mute' => 'no',
            'audio-out-params/samplerate' => '48000',
            _ => '',
          },
        )
        ..nativeCompleted(true);
      now += 500;
      m.sampleNativeAv((key) => key == 'audio-pts' ? 'NaN' : 'secret-device');
      expect(m.nativeAvProbe!['audio-pts'], isNull);
      expect(m.previousNativeAvProbe!['audio-pts'], 12.5);
      expect(m.nativeAvBeforeCompleted!['mute'], false);
      for (var i = 0; i < 200; i++) {
        m.sampleNativeAv((_) => throw StateError('secret'));
      }
      expect(m.nativeAvProbe!.length, 10);
      expect(m.snapshot().toString(), isNot(contains('secret')));
      m
        ..nativeLog('secret-device', 'error', 'private URL')
        ..nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable')
        ..nativeLog('ad', 'error', 'secret codec')
        ..nativeLog('ffmpeg', 'warn', 'HTTP error 503 Service Unavailable');
      final events = m.events
          .where((e) => e['event'] == 'native-error-origin')
          .toList();
      expect(events.length, 3);
      expect(events[0]['origin'], 'other');
      expect(events[1]['readKind'], 'http-status');
      expect(events[2]['origin'], 'ad');
      expect(m.snapshot().toString(), isNot(contains('secret')));
    },
  );

  test(
    'EOF reset retains earlier observed audio and distinct open/seek failures',
    () {
      final metrics = BtrMetrics(BtrMode.combined)
        ..playerOpening('source', 0)
        ..nativeTracks(1, true)
        ..nativeCompleted(true)
        ..nativeTracks(0, null) // locked media-kit EOF event reset
        ..seekCommand('failed', 40000);
      final data = metrics.snapshot();
      expect(data['nativeAudioTrackCount'], 0);
      expect(data['maxNativeAudioTrackCount'], 1);
      expect(data['nativeAudioTracksBeforeCompleted'], 1);
      expect(data['nativeAudioSelectedBeforeCompleted'], true);
      expect(data['seekCommandFailures'], 1);
      expect(data['playerOpenCount'], 1);
      expect(data['terminalFailures'], null);
    },
  );
  test('player error context contains categories without native secrets', () {
    final metrics = BtrMetrics(BtrMode.combined)
      ..seek(10000)
      ..playerError(
        'Failed to open http://127.0.0.1/private?token=never-log',
        transportTerminal: false,
      )
      ..playerError(
        'Could not open codec secret-decoder',
        transportTerminal: true,
      )
      ..playerError('audio output secret-device', transportTerminal: false);
    expect(metrics.playerErrors, 3);
    final errors = metrics.events
        .where((e) => e['event'] == 'player-error')
        .toList();
    expect(errors[0]['category'], 'proxy-read');
    expect(errors[0]['transportTerminal'], false);
    expect(errors[0]['seekPending'], true);
    expect(errors[1]['category'], 'decoder');
    expect(errors[1]['transportTerminal'], true);
    expect(errors[2]['category'], 'audio');
    final report = metrics.snapshot().toString();
    for (final sensitive in ['http://', 'private', 'never-log', 'secret-']) {
      expect(report, isNot(contains(sensitive)));
    }
  });

  test('unobserved native audio state remains unknown', () {
    final snapshot = BtrMetrics(BtrMode.combined).snapshot();
    expect(snapshot['nativeAudioTrackCount'], isNull);
    expect(snapshot['nativeAudioSelected'], isNull);
    expect(snapshot['nativePlayerVolume'], isNull);
  });
}
