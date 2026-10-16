// Scheduling concepts adapted from Bilibili-thread-ripper (MIT).
// Copyright (c) 2026 Bilibili-thread-ripper contributors; see third_party/BTR-LICENSE.txt.
import 'dart:async';
import 'dart:math' as math;

class BtrCancelled implements Exception {
  const BtrCancelled();
}

class BtrCancel {
  final _done = Completer<void>();
  final Set<void Function()> _listeners = {};
  bool get cancelled => _done.isCompleted;
  Future<void> get done => _done.future;
  void check() {
    if (cancelled) throw const BtrCancelled();
  }

  void Function() listen(void Function() callback) {
    if (cancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (cancelled) return;
    _done.complete();
    for (final callback in _listeners.toList()) {
      callback();
    }
    _listeners.clear();
  }

  Future<T> bind<T>(Future<T> future) async {
    final result = Completer<T>();
    final unlink = listen(() {
      if (!result.isCompleted) result.completeError(const BtrCancelled());
    });
    future.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    try {
      return await result.future;
    } finally {
      unlink();
    }
  }
}

class _Waiter {
  _Waiter(this.token, this.audio, this.priority, this.order);
  final BtrCancel token;
  final bool audio;
  final int Function() priority;
  final int order;
  final completer = Completer<void Function()>();
  void Function()? unlink;
}

/// Shared across both tracks, including discovery, retries and hedge copies.
/// One slot is reserved for audio and one for a demanded head rescue.
class BtrScheduler {
  BtrScheduler({int limit = 8}) : _limit = limit.clamp(2, 16);
  int _limit;
  int get limit => _limit;
  set limit(int value) {
    _limit = value.clamp(2, 16);
    _drain();
  }

  int active = 0;
  int videoActive = 0;
  int audioActive = 0;
  int peak = 0;
  int _sequence = 0;
  final _queue = <_Waiter>[];
  int get queued => _queue.length;

  Future<void Function()> acquire(
    BtrCancel token, {
    required bool audio,
    required int Function() priority,
  }) {
    token.check();
    final w = _Waiter(token, audio, priority, _sequence++);
    _queue.add(w);
    w.unlink = token.listen(() {
      if (_queue.remove(w)) w.completer.completeError(const BtrCancelled());
    });
    _drain();
    return w.completer.future;
  }

  void _drain() {
    _queue.sort((a, b) {
      final rank = b.priority().compareTo(a.priority());
      return rank == 0 ? a.order.compareTo(b.order) : rank;
    });
    while (active < _limit && _queue.isNotEmpty) {
      final i = _queue.indexWhere(
        (w) => w.audio
            ? audioActive < math.max(2, _limit ~/ 4)
            : videoActive < _limit - 1,
      );
      if (i < 0) return;
      final w = _queue.removeAt(i);
      w.unlink?.call();
      active++;
      if (!w.audio) videoActive++;
      if (w.audio) audioActive++;
      peak = math.max(peak, active);
      var released = false;
      w.completer.complete(() {
        if (released) return;
        released = true;
        active--;
        if (!w.audio) videoActive--;
        if (w.audio) audioActive--;
        _drain();
      });
    }
  }
}

/// Android cap 16, versus the browser's 64. Counts useful ordered delivery,
/// never hedge waste. Only saturated demand may start a ten-second trial.
class BtrAdaptive {
  BtrAdaptive(this.scheduler, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final BtrScheduler scheduler;
  final int Function() now;
  static const ladder = [8, 12, 16];
  final _samples = <(int, int)>[];
  int _changed = 0;
  int _restUntil = 0;
  int? _trialFrom;
  int _trialAt = 0;
  double _baseline = 0;
  double connectionBps = 0;
  double pieceMs = 0;
  double ahead = 0;
  bool playing = false;
  bool buffering = false;

  double get throughput {
    final at = now();
    _samples.removeWhere((s) => at - s.$1 > 5000);
    if (_samples.isEmpty) return 0;
    return _samples.fold<int>(0, (sum, s) => sum + s.$2) *
        1000 /
        math.max(1000, _samples.last.$1 - _samples.first.$1 + 250);
  }

  void delivered(int bytes) {
    final at = now();
    if (_samples.isNotEmpty && at - _samples.last.$1 < 250) {
      final last = _samples.removeLast();
      _samples.add((last.$1, last.$2 + bytes));
    } else {
      _samples.add((at, bytes));
    }
    if (_trialFrom != null && at - _trialAt >= 10000) {
      if (scheduler.queued > 0 && throughput <= _baseline) {
        scheduler.limit = _trialFrom!;
        _restUntil = at + 90000;
      }
      _trialFrom = null;
    }
  }

  void demand({
    required bool playing,
    required bool buffering,
    required double ahead,
  }) {
    this.playing = playing;
    this.buffering = buffering;
    this.ahead = ahead;
    final at = now();
    if (!playing ||
        ahead >= 6 ||
        scheduler.active < scheduler.limit - 1 ||
        scheduler.queued == 0 ||
        at < _restUntil ||
        at - _changed < 2500 ||
        _trialFrom != null ||
        throughput <= 0) {
      return;
    }
    final next = ladder.where((v) => v > scheduler.limit).firstOrNull;
    if (next == null) return;
    _baseline = throughput;
    _trialFrom = scheduler.limit;
    _trialAt = _changed = at;
    scheduler.limit = next;
  }

  void pushback() {
    if (now() < _restUntil) return; // one refusal batch, one backoff
    scheduler.limit = ladder.lastWhere(
      (v) => v < scheduler.limit,
      orElse: () => 8,
    );
    _restUntil = now() + 180000;
    _trialFrom = null;
  }

  void sample(int bytes, int ms) {
    if (bytes < 48 * 1024 || ms <= 0) return;
    final bps = bytes * 1000 / ms;
    connectionBps = connectionBps == 0 ? bps : connectionBps * .7 + bps * .3;
    pieceMs = pieceMs == 0 ? ms.toDouble() : pieceMs * .7 + ms * .3;
  }

  int get pieceSize =>
      (connectionBps * .6 ~/ 65536 * 65536).clamp(65536, 1024 * 1024);
  int get hedgeMs =>
      pieceMs == 0 ? 900 : (pieceMs * 1.5).round().clamp(250, 900);
}
