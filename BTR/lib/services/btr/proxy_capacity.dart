import 'dart:async';

import 'package:PiliPlus/services/btr/local_write_budget.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';

/// Four executing requests; writers lend slots at backpressure or chunk boundaries.
/// Their response and current bytes stay alive. Total admitted responses,
/// including waiters and blocked writers, are bounded separately at eight.
class BtrProxyCapacity {
  static const activeLimit = 4;
  static const responseLimit = 8;
  int active = 0;
  int responses = 0;
  int parked = 0;
  int peak = 0;
  int suspensions = 0;
  int cooperativeYields = 0;
  final _waiters = <Completer<void>>[];

  BtrProxySlot? admit() {
    if (responses >= responseLimit) return null;
    responses++;
    return BtrProxySlot._(this);
  }

  void _wake() {
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}

class BtrProxySlot {
  BtrProxySlot._(this.owner);
  final BtrProxyCapacity owner;
  bool _held = false;
  bool _closed = false;
  bool get holdsExecutionSlot => _held;

  Future<void> acquire(BtrCancel token) async {
    while (!_held) {
      token.check();
      if (_closed) throw const BtrCancelled();
      if (owner.active < BtrProxyCapacity.activeLimit) {
        owner.active++;
        if (owner.active > owner.peak) owner.peak = owner.active;
        _held = true;
        return;
      }
      final changed = Completer<void>();
      owner._waiters.add(changed);
      try {
        await token.bind(changed.future);
      } finally {
        owner._waiters.remove(changed);
      }
    }
  }

  void _release() {
    if (!_held) return;
    _held = false;
    owner.active--;
    owner._wake();
  }

  Future<void> flush(
    Future<void> flushing,
    BtrCancel token, {
    Duration idleTimeout = BtrLocalWriteBudget.base,
    required void Function() onBlocked,
  }) async {
    BtrLocalWriteBudget.validate(idleTimeout);
    var blocked = false;
    final timer = Timer(const Duration(milliseconds: 100), () {
      blocked = true;
      owner.parked++;
      owner.suspensions++;
      _release();
      onBlocked();
    });
    try {
      // Cancellation settles the timed future too, so retired writers do not
      // leave a long-lived deadline timer retaining their response futures.
      await token.bind(flushing).timeout(idleTimeout);
    } finally {
      timer.cancel();
      if (blocked) owner.parked--;
    }
    // Continuously consumed responses also need to admit waiting audio/seek
    // requests. Keep response ownership and bytes; the caller reacquires before
    // producing another chunk. Let awakened waiters run before that reacquire.
    if (_held && owner._waiters.isNotEmpty) {
      owner.cooperativeYields++;
      _release();
      await token.bind(Future<void>.delayed(Duration.zero));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    owner.responses--;
    owner._wake();
  }
}
