import 'dart:async';

import 'package:PiliPlus/services/btr/scheduler.dart';

/// Four executing requests; blocked socket writers may lend their slot.
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
    required void Function() onBlocked,
  }) async {
    var blocked = false;
    final timer = Timer(const Duration(milliseconds: 100), () {
      blocked = true;
      owner.parked++;
      owner.suspensions++;
      _release();
      onBlocked();
    });
    try {
      // Preserve the existing response deadline, including suspended time.
      await token.bind(flushing.timeout(const Duration(seconds: 15)));
    } finally {
      timer.cancel();
      if (blocked) owner.parked--;
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
