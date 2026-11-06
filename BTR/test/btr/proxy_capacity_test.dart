import 'dart:async';

import 'package:PiliPlus/services/btr/proxy_capacity.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test(
    'blocked writers lend execution slots without releasing response ownership',
    () async {
      final capacity = BtrProxyCapacity();
      final token = BtrCancel();
      final slots = List.generate(8, (_) => capacity.admit()!);
      expect(capacity.admit(), isNull);
      await Future.wait(slots.take(4).map((s) => s.acquire(token)));
      final draining = Completer<void>();
      final blocked = Completer<void>();
      final flush = slots.first.flush(
        draining.future,
        token,
        onBlocked: blocked.complete,
      );
      await blocked.future;
      await slots[4].acquire(token);
      expect(capacity.active, 4);
      expect(capacity.responses, 8);
      expect(capacity.parked, 1);
      draining.complete();
      slots[4].close();
      await flush;
      await slots.first.acquire(token);
      for (final slot in slots) {
        slot.close();
      }
      expect(capacity.active, 0);
      expect(capacity.responses, 0);
      expect(capacity.parked, 0);
      expect(capacity.peak, 4);
    },
  );

  test(
    'cancelling queued admission and parked flush releases all capacity',
    () async {
      final capacity = BtrProxyCapacity();
      final token = BtrCancel();
      final slots = List.generate(5, (_) => capacity.admit()!);
      await Future.wait(slots.take(4).map((s) => s.acquire(token)));
      final queued = expectLater(
        slots[4].acquire(token),
        throwsA(isA<BtrCancelled>()),
      );
      token.cancel();
      await queued;
      for (final slot in slots) {
        slot.close();
      }
      final writer = capacity.admit()!, writerToken = BtrCancel();
      await writer.acquire(writerToken);
      final blocked = Completer<void>(), draining = Completer<void>();
      final flushed = expectLater(
        writer.flush(draining.future, writerToken, onBlocked: blocked.complete),
        throwsA(isA<BtrCancelled>()),
      );
      await blocked.future;
      writerToken.cancel();
      draining.complete();
      await flushed;
      writer.close();
      expect(capacity.responses, 0);
      expect(capacity.active, 0);
      expect(capacity.parked, 0);
    },
  );
}
