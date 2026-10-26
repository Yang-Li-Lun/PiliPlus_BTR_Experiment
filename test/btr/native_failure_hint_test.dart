import 'dart:convert';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/native_failure_hint.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
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
