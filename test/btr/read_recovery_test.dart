import 'package:PiliPlus/services/btr/read_recovery.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('stall requires recent transport evidence and no position progress', () {
    final r = BtrReadRecovery();
    bool poll(int now, int position, {int? failureAt, bool eligible = true}) =>
        r.observeStall(
          now: now,
          position: Duration(milliseconds: position),
          waiting: true,
          eligible: eligible,
          failureAt: failureAt,
        );
    expect(poll(0, 0), false);
    expect(poll(20000, 0), false);
    expect(poll(20000, 1, failureAt: 19000), false);
    expect(poll(34999, 1, failureAt: 30000), false);
    expect(poll(35000, 1, failureAt: 30000), true);
    r.reset();
    expect(poll(40000, 1, failureAt: 30000), false);
    expect(poll(60000, 1, failureAt: 30000), false);
    expect(poll(60000, 1, failureAt: 60000, eligible: false), false);
    expect(poll(60001, 1, failureAt: 60000), false);
    expect(poll(75001, 1, failureAt: 60000), true);
  });

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
