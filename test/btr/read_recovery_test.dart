import 'package:PiliPlus/services/btr/read_recovery.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('unknown duration is not fabricated EOF evidence, read failure is', () {
    final r = BtrReadRecovery();
    expect(r.acceptCompleted(Duration.zero, Duration.zero, null), true);
    r.record('HTTP error 503 Service Unavailable', const Duration(seconds: 7));
    expect(r.acceptCompleted(Duration.zero, Duration.zero, null), false);
    expect(r.resumePosition, const Duration(seconds: 7));
  });

  test('buffered or paused position updates cannot clear read failure', () {
    final r = BtrReadRecovery()
      ..record('tcp: ffurl_read returned -5', const Duration(seconds: 10))
      ..position(const Duration(seconds: 10), advancing: false)
      ..position(const Duration(seconds: 11), advancing: false);
    expect(r.failed, true);
    r.position(const Duration(seconds: 12), advancing: true);
    expect(r.failed, false);
    expect(
      r.acceptCompleted(
        const Duration(seconds: 120),
        const Duration(seconds: 120),
        null,
      ),
      true,
    );
  });

  test('reset on new seek/load invalidates old recovery evidence', () {
    final r = BtrReadRecovery()
      ..record(
        'HTTP error 503 Service Unavailable',
        const Duration(seconds: 10),
      );
    final previous = r.revision;
    r.reset();
    expect(r.revision, greaterThan(previous));
    expect(r.failed, false);
    expect(r.resumePosition, isNull);
    expect(r.abnormalCompleted, false);
  });

  test(
    'audio/decoder/unknown messages never become read failure by guessing',
    () {
      for (final text in [
        'audio output failed',
        'Could not open codec',
        'unexpected EOF',
        'https://secret/?token=secret',
        'Received MPV_EVENT_REPLY with unregistered ID 1',
      ]) {
        expect(BtrReadRecovery.classify(text), isNull);
      }
    },
  );
}
