import 'dart:collection';

import 'package:PiliPlus/services/btr/policy.dart';

class BtrMetrics {
  BtrMetrics(this.mode, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    openedAt = now();
  }
  final BtrMode mode;
  bool transportMeasured = true;
  final int Function() now;
  late final int openedAt;
  int networkBytes = 0;
  int deliveredBytes = 0;
  int failures = 0;
  int cancellations = 0;
  int hedges = 0;
  int resumedBytes = 0;
  int bufferingEvents = 0;
  int playerErrors = 0;
  int? startupMs;
  final seekMs = Queue<int>();
  int? _seekAt;
  int? _seekTarget;
  int? _previousPosition;
  bool _buffering = false;
  int? nativeQueueBytes;
  int? nativeInputBps;
  final events = Queue<Map<String, Object>>();
  final deliveredByTrack = <String, int>{};
  final _deliveries = Queue<(int, int)>();
  int droppedEvents = 0;

  void event(String kind, [Map<String, Object> fields = const {}]) {
    if (events.length == 128) {
      events.removeFirst();
      droppedEvents++;
    }
    events.add({'ms': now() - openedAt, 'event': kind, ...fields});
  }

  void delivered(String track, int bytes) {
    deliveredBytes += bytes;
    deliveredByTrack.update(track, (v) => v + bytes, ifAbsent: () => bytes);
    final at = now();
    if (_deliveries.isNotEmpty && at - _deliveries.last.$1 < 250) {
      final last = _deliveries.removeLast();
      _deliveries.add((last.$1, last.$2 + bytes));
    } else {
      _deliveries.add((at, bytes));
    }
    _prune();
  }

  void _prune() {
    while (_deliveries.isNotEmpty && now() - _deliveries.first.$1 > 5000) {
      _deliveries.removeFirst();
    }
  }

  void seek(int positionMs) {
    _seekAt = now();
    _seekTarget = positionMs;
    _previousPosition = null;
    event('seek');
  }

  void buffering(bool value) {
    if (value && !_buffering && startupMs != null && _seekAt == null) {
      bufferingEvents++;
    }
    _buffering = value;
  }

  // Position advancement is stronger evidence than the playing flag alone.
  // These are player timeline metrics, not decoded-frame/AV-sync acceptance.
  void position(int positionMs, bool playing) {
    final previous = _previousPosition;
    _previousPosition = positionMs;
    if (!playing || _buffering || previous == null || positionMs <= previous) {
      return;
    }
    startupMs ??= now() - openedAt;
    if (_seekAt != null && (positionMs - _seekTarget!).abs() < 2500) {
      if (seekMs.length == 32) seekMs.removeFirst();
      seekMs.add(now() - _seekAt!);
      _seekAt = _seekTarget = null;
    }
  }

  Map<String, Object?> snapshot() {
    _prune();
    return {
      'schema': 1,
      'mode': mode.name,
      'elapsedMs': now() - openedAt,
      'startupTimelineMs': startupMs,
      'seekTimelineMs': seekMs.toList(),
      'seekPending': _seekAt != null,
      'bufferingEvents': bufferingEvents,
      'transportFailures': failures,
      'playerErrors': playerErrors,
      'networkBytesIncludingProbesAndHedges':
          mode == BtrMode.original || !transportMeasured ? null : networkBytes,
      'loopbackDeliveredBytes': mode == BtrMode.original || !transportMeasured
          ? null
          : deliveredBytes,
      'deliveredByTrack': Map<String, int>.of(deliveredByTrack),
      'loopbackDeliveredBps5s': mode == BtrMode.original || !transportMeasured
          ? null
          : _deliveries.fold<int>(0, (s, b) => s + b.$2) / 5,
      'nativeMainDemuxQueueBytes': nativeQueueBytes,
      'nativeMainDemuxInputBps': nativeInputBps,
      'hedges': hedges,
      'resumedPrefixBytes': resumedBytes,
      'cancellations': cancellations,
      'eventsDropped': droppedEvents,
      'events': events.toList(),
    };
  }
}
