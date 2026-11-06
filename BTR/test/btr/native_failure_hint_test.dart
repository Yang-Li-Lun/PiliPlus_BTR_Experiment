import 'dart:convert';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/native_failure_hint.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('native component hints admit only fixed mpv libav namespaces', () {
    for (final entry in {
      'ffmpeg/audio': 'ffmpeg-audio',
      'ffmpeg/video': 'ffmpeg-video',
      'ffmpeg/demuxer': 'ffmpeg-demuxer',
      'ffmpeg/private-host': null,
      'ffmpeg/video/private-host': null,
      'other/ffmpeg/video': null,
    }.entries) {
      final metrics = BtrMetrics(BtrMode.combined)
        ..nativeLog(entry.key, 'error', 'unclassified private-message');
      expect(metrics.firstNativeError?['component'], entry.value);
      final encoded = jsonEncode(metrics.snapshot());
      expect(encoded, isNot(contains('private-host')));
      expect(encoded, isNot(contains('private-message')));
    }
  });

  test('HTTP protocol stage hints do not infer status codes or hide errors', () {
    const cases = {
      'URL read error: Immediate exit requested': 'http-read-interrupted',
      'Error reading HTTP response: Immediate exit requested':
          'http-response-interrupted',
      'Error reading HTTP response: Connection reset by peer':
          'http-response-read',
      'URL read error: Input/output error': 'http-url-read',
      'Stream ends prematurely at 123, should be 456': 'http-short-stream',
      'Unexpected offset: expected 123, got 456': 'http-offset-mismatch',
      'Invalid chunk size 123': 'http-invalid-chunk',
      'Malformed HTTP version string.': 'http-invalid-version',
      'overlong headers': 'http-header-size',
      'Failed to reconnect at 123.': 'http-reconnect-failed',
      'Received and expected HTTP method do not match. (GET expected, HEAD received)':
          'http-method-mismatch',
      'Received and autodetected HTTP method did not match (GET autodetected HEAD received)':
          'http-method-mismatch',
    };
    final metrics = BtrMetrics(BtrMode.combined);
    for (final entry in cases.entries) {
      final message =
          'http: ${entry.key} https://private.invalid/?token=secret';
      expect(BtrNativeFailureHint.read(message), {'failureHint': entry.value});
      metrics.nativeLog('ffmpeg/private-child', 'error', message);
    }
    expect(metrics.nativeErrorOrigins, {'ffmpeg': cases.length});
    final encoded = jsonEncode(metrics.snapshot());
    for (final private in [
      'private.invalid',
      'token=',
      'private-child',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
    expect(encoded, isNot(contains('reportedHttpStatus')));
    expect(
      BtrNativeFailureHint.read(
        'https://private.invalid/URL read error: Immediate exit requested',
      ),
      {
        'failureHint': 'unclassified',
      },
    );
  });

  test(
    'mpv AVClass framing is recognized without retaining component data',
    () {
      for (final component in [
        'https',
        'http',
        'tcp',
        'tls',
        'mediacodec',
        'hevc_mediacodec',
        'h264_mediacodec',
        'AVIOContext',
        'AVHWDeviceContext',
      ]) {
        expect(
          BtrNativeFailureHint.read(
            '$component: HTTP error 403 https://secret.invalid/?token=private',
          ),
          {'failureHint': 'reported-http-status', 'reportedHttpStatus': 403},
        );
      }
      final metrics = BtrMetrics(BtrMode.combined)
        ..nativeLog(
          'ffmpeg/video',
          'error',
          'hevc_mediacodec: Failed to release output buffer private-name',
        );
      expect(metrics.nativeErrorOrigins, {'ffmpeg': 1});
      expect(metrics.firstNativeError?['failureHint'], 'codec-release-output');
      final encoded = jsonEncode(metrics.snapshot());
      expect(encoded, isNot(contains('hevc_mediacodec')));
      expect(encoded, isNot(contains('private-name')));
      for (final unknown in [
        'private-host: HTTP error 403',
        'https: https: HTTP error 403',
        'https://secret.invalid/HTTP error 403',
        'https:HTTP error 403',
      ]) {
        expect(BtrNativeFailureHint.read(unknown), {
          'failureHint': 'unclassified',
        });
      }
    },
  );

  test('AImageReader stages retain only a bounded reported status number', () {
    const cases = {
      'newWithUsage failed: ': 'android-image-create',
      'getWindow failed: ': 'android-image-window',
      'acquireLatestImage failed: ': 'android-image-acquire',
      'getHardwareBuffer failed: ': 'android-image-buffer',
    };
    for (final entry in cases.entries) {
      expect(BtrNativeFailureHint.read('${entry.key}-30001 private-address'), {
        'failureHint': entry.value,
        'reportedMediaStatus': -30001,
      });
      for (final malformed in ['-3000100', 'secret', '12private', '--12']) {
        expect(BtrNativeFailureHint.read('${entry.key}$malformed'), {
          'failureHint': entry.value,
        });
      }
    }
    expect(
      BtrNativeFailureHint.read(
        'https://private.invalid/acquireLatestImage failed: -30001',
      ),
      {'failureHint': 'unclassified'},
    );
  });

  test(
    'native video literals distinguish stages without exporting suffixes',
    () {
      const cases = {
        'Error opening/initializing the VO window.': 'video-output-window',
        'Failed to create ANativeWindow': 'native-window-create',
        'Could not choose EGLConfig for private-driver!': 'egl-config',
        'Could not create EGL context for private-driver (error=-1)!':
            'egl-context',
        'Could not create EGL surface!': 'egl-surface',
        'EGL failed to initialize.': 'egl-init',
        'Failed loading EGL functions - double check EGLDisplay?':
            'egl-functions',
        'Initializing texture for hardware decoding failed.':
            'hwdec-texture-init',
        'Mapping hardware decoded surface failed.': 'hwdec-surface-map',
        'Failed mapping hwdec frame? Open a bug!': 'hwdec-frame-map',
        'Could not copy back hardware decoded frame.': 'hwdec-copy-back',
        'Could not copy hardware frame to CPU memory.': 'hwdec-copy-cpu',
        'Ran out of free frames!': 'frame-pool-exhausted',
        'Failed to flush codec': 'codec-flush',
        'Failed to dequeue input buffer (status=-1)': 'codec-dequeue-input',
        'Failed to dequeue output buffer (status=-1)': 'codec-dequeue-output',
        'Failed to queue input buffer (status = -1)': 'codec-queue-input',
        'Failed to release output buffer': 'codec-release-output',
        'release output buffer failed, -1': 'codec-release-output',
        'releaseOutputBufferAtTime failed, -1': 'codec-release-timed-output',
        'Failed to retrieve first frame': 'first-frame-retrieve',
        'Failed presenting frame!': 'frame-present',
        'Failed rendering frame!': 'frame-render',
        'Failed uploading frame!': 'frame-upload',
        'Failed uninitializing buffer, leaking resources!': 'buffer-uninit',
        'Failed uninitializing texture, leaking resources!': 'texture-uninit',
      };
      for (final entry in cases.entries) {
        final message =
            '${entry.key} https://private.invalid/?token=secret 0x1234';
        for (final variant in [message, message.toUpperCase(), '  $message']) {
          expect(BtrNativeFailureHint.read(variant), {
            'failureHint': entry.value,
          });
        }
        // A quoted message inside an arbitrary URL is not a native hint.
        expect(
          BtrNativeFailureHint.read('https://private.invalid/${entry.key}'),
          {
            'failureHint': 'unclassified',
          },
        );
      }
    },
  );

  test(
    'native reported HTTP status is retained without arbitrary suffixes',
    () {
      for (final status in [400, 403, 404, 408, 429, 500, 503]) {
        for (final prefix in ['HTTP error', 'Server returned']) {
          expect(
            BtrNativeFailureHint.read('$prefix $status secret-url?token=x'),
            {
              'failureHint': 'reported-http-status',
              'reportedHttpStatus': status,
            },
          );
        }
      }
    },
  );

  test('URLs and malformed status strings cannot fabricate an HTTP fact', () {
    for (final message in [
      'https://secret.invalid/HTTP error 403 Forbidden',
      'HTTP error 4030',
      'HTTP error 099 Invalid',
      'HTTP error 999 Invalid',
      'Authorization: secret Server returned 403 Forbidden',
      'secret' * 100000,
    ]) {
      expect(BtrNativeFailureHint.read(message), {
        'failureHint': 'unclassified',
      });
    }
  });

  test(
    'canonical failure hints never retain decoder names or private URLs',
    () {
      final cases = {
        'Failed to open https://secret.invalid/?sig=private': 'open-failed',
        'Connection timed out: secret-host': 'connection-timeout',
        'Connection reset by peer: private': 'connection-reset',
        'TLS handshake failed secret-certificate': 'tls-handshake',
        'Invalid data found when processing input private-file': 'invalid-data',
        'Could not open codec secret-decoder': 'codec-open',
        'Could not find codec parameters private-stream': 'codec-parameters',
        'native_window_api_connect returned an error: Invalid argument (-22) private-suffix':
            'surface-connect',
        'Failed to create surface private-name': 'surface-create',
        'Failed to initialize video output private-driver': 'video-output-init',
        'Hardware decoding failed private-codec': 'hardware-decode-failed',
        'End of file private-file': 'end-of-file',
      };
      for (final entry in cases.entries) {
        expect(BtrNativeFailureHint.read(entry.key), {
          'failureHint': entry.value,
        });
      }
    },
  );

  test(
    'diagnostic hints preserve counters, bounds and privacy in both modes',
    () {
      for (final mode in [BtrMode.original, BtrMode.combined]) {
        final metrics = BtrMetrics(mode);
        for (var i = 0; i < 200; i++) {
          metrics
            ..nativeLog(
              'ffmpeg/private-host',
              'error',
              'HTTP error 403 private-url?token=secret',
            )
            ..playerError(
              'Failed to open https://secret.invalid/?sig=private',
              transportTerminal: false,
            );
        }
        expect(metrics.playerErrors, 200);
        expect(metrics.nativeErrorOrigins, {'ffmpeg': 200});
        expect(metrics.events.length, 128);
        final encoded = jsonEncode(metrics.snapshot());
        for (final secret in [
          'private-host',
          'private-url',
          'secret.invalid',
          'sig=',
          'token=',
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
        expect(encoded, contains('reportedHttpStatus'));
        expect(encoded, contains('open-failed'));
      }
    },
  );

  test('buffer transitions retain timing without filtering buffer counts', () {
    var now = 0;
    final metrics = BtrMetrics(BtrMode.combined, clock: () => now)
      ..position(0, true);
    now = 10;
    metrics
      ..position(100, true)
      ..seek(1000)
      ..buffering(true);
    expect(metrics.bufferingEvents, 0);
    metrics
      ..buffering(false)
      ..position(1100, true)
      ..position(1200, true);
    now = 20;
    metrics
      ..buffering(true)
      ..buffering(true);
    expect(metrics.bufferingEvents, 1);
    final transitions = metrics.events
        .where((event) => event['event'] == 'buffering-transition')
        .toList();
    expect(transitions.length, 3);
    expect(transitions.last['ms'], 20);
    expect(transitions.last['seekPending'], false);
  });
}
