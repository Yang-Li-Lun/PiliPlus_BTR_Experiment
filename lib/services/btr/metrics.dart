import 'dart:collection';

import 'package:PiliPlus/services/btr/policy.dart';

/// 250 ms buckets bound storage independently of the number of HTTP chunks.
class _ByteRate {
  final samples = Queue<(int, int)>();
  void add(int at, int bytes) {
    final bucket = at ~/ 250 * 250;
    if (samples.isNotEmpty && samples.last.$1 == bucket) {
      final last = samples.removeLast();
      samples.add((bucket, last.$2 + bytes));
    } else {
      samples.add((bucket, bytes));
    }
    rate(at);
  }

  double rate(int at) {
    while (samples.isNotEmpty && at - samples.first.$1 >= 5000) {
      samples.removeFirst();
    }
    return samples.fold<int>(0, (sum, s) => sum + s.$2) / 5;
  }
}

class BtrMetrics {
  BtrMetrics(this.mode, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    openedAt = now();
  }
  final BtrMode mode;
  bool transportMeasured = false;
  final int Function() now;
  late final int openedAt;
  int networkBytes = 0;
  int deliveredBytes = 0;
  int failures = 0;
  int discoveryFailures = 0;
  int requestFailures = 0;
  int terminalFailures = 0;
  int retries = 0;
  int resumes = 0;
  int upstreamCancellations = 0;
  int cancellations = 0;
  int hedges = 0;
  int resumedBytes = 0;
  int bufferingEvents = 0;
  int playerErrors = 0;
  bool? separateAudioExpected;
  int? nativeAudioTracks;
  int? maxNativeAudioTracks;
  int? audioTracksBeforeCompleted;
  bool? audioSelectedBeforeCompleted;
  int playerOpenCount = 0;
  int seekCommandFailures = 0;
  bool? nativeAudioSelected;
  double? nativePlayerVolume;
  int? startupMs;
  bool? playing;
  bool? completed;
  double? bufferAheadSeconds;
  bool ended = false;
  final seekMs = Queue<int>();
  int? _seekAt;
  int? _seekTarget;
  int? _previousPosition;
  bool? _buffering;
  int? nativeQueueBytes;
  int? nativeInputBps;
  final events = Queue<Map<String, Object>>();
  final deliveredByTrack = <String, int>{};
  final networkByTrack = <String, int>{};
  final _networkRates = <String, _ByteRate>{};
  final _deliveryRates = <String, _ByteRate>{};
  int droppedEvents = 0;

  void registerTrack(String track) {
    transportMeasured = true;
    deliveredByTrack.putIfAbsent(track, () => 0);
    networkByTrack.putIfAbsent(track, () => 0);
    _networkRates.putIfAbsent(track, _ByteRate.new);
    _deliveryRates.putIfAbsent(track, _ByteRate.new);
  }

  void received(String track, int bytes) {
    registerTrack(track);
    networkBytes += bytes;
    networkByTrack[track] = networkByTrack[track]! + bytes;
    _networkRates[track]!.add(now(), bytes);
  }

  void event(String kind, [Map<String, Object> fields = const {}]) {
    if (events.length == 128) {
      events.removeFirst();
      droppedEvents++;
    }
    events.add({'ms': now() - openedAt, 'event': kind, ...fields});
  }

  void delivered(String track, int bytes) {
    registerTrack(track);
    deliveredBytes += bytes;
    deliveredByTrack.update(track, (v) => v + bytes, ifAbsent: () => bytes);
    _deliveryRates[track]!.add(now(), bytes);
  }

  void seek(int positionMs) {
    _seekAt = now();
    _seekTarget = positionMs;
    _previousPosition = null;
    event('seek', {'targetMs': positionMs});
  }

  void seekCommand(String outcome, int targetMs) {
    if (outcome == 'failed') seekCommandFailures++;
    event('seek-command', {'outcome': outcome, 'targetMs': targetMs});
  }

  void playerOpening(String reason, int targetMs) {
    playerOpenCount++;
    event('player-open', {
      'reason': reason,
      'open': playerOpenCount,
      'targetMs': targetMs,
    });
  }

  void nativeTracks(int count, bool? selected) {
    if (nativeAudioTracks != count || nativeAudioSelected != selected) {
      event('native-audio-state', {
        'count': count,
        'selected': ?selected,
        'completed': completed == true,
        'open': playerOpenCount,
      });
    }
    nativeAudioTracks = count;
    nativeAudioSelected = selected;
    final previous = maxNativeAudioTracks;
    maxNativeAudioTracks = previous == null || count > previous
        ? count
        : previous;
  }

  void nativeCompleted(bool value) {
    if (value && completed != true) {
      audioTracksBeforeCompleted = nativeAudioTracks;
      audioSelectedBeforeCompleted = nativeAudioSelected;
      event('player-completed', {
        'audioTracksBefore': ?nativeAudioTracks,
        'audioSelectedBefore': ?nativeAudioSelected,
        'seekPending': _seekAt != null,
      });
    }
    completed = value;
  }

  // Categorize native errors without storing URLs, signed queries, codec names,
  // file paths or arbitrary decoder messages. A category is not a root cause.
  void playerError(String message, {required bool transportTerminal}) {
    playerErrors++;
    final lower = message.toLowerCase();
    final category = lower.contains('http://127.0.0.1')
        ? 'proxy-read'
        : lower.contains('audio') || lower.contains('ao/')
        ? 'audio'
        : lower.contains('codec') || lower.contains('decoder')
        ? 'decoder'
        : lower.contains('http') || lower.contains('ffurl_read')
        ? 'network'
        : 'other';
    event('player-error', {
      'category': category,
      'transportTerminal': transportTerminal,
      'seekPending': _seekAt != null,
    });
  }

  void buffering(bool value) {
    if (value && _buffering != true && startupMs != null && _seekAt == null) {
      bufferingEvents++;
    }
    _buffering = value;
  }

  // Position advancement is stronger evidence than the playing flag alone.
  // These are player timeline metrics, not decoded-frame/AV-sync acceptance.
  void position(int positionMs, bool playing) {
    final previous = _previousPosition;
    _previousPosition = positionMs;
    if (!playing ||
        _buffering == true ||
        previous == null ||
        positionMs <= previous) {
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
    final measured = mode != BtrMode.original && transportMeasured;
    final networkRates = {
      for (final entry in _networkRates.entries)
        entry.key: ended ? 0.0 : entry.value.rate(now()),
    };
    final deliveryRates = {
      for (final entry in _deliveryRates.entries)
        entry.key: ended ? 0.0 : entry.value.rate(now()),
    };
    return {
      'schema': 2,
      'mode': mode.name,
      'sessionEnded': ended,
      'elapsedMs': now() - openedAt,
      'playbackState': ended
          ? 'closed'
          : completed == true
          ? 'completed'
          : playing == null
          ? null
          : _seekAt != null
          ? 'seeking'
          : _buffering == true
          ? 'buffering'
          : playing == true
          ? 'playing'
          : 'paused',
      'bufferAheadSeconds': bufferAheadSeconds,
      'startupTimelineMs': startupMs,
      'seekTimelineMs': seekMs.toList(),
      'seekPending': _seekAt != null,
      'bufferingEvents': playing == null && startupMs == null
          ? null
          : bufferingEvents,
      'transportFailures': measured ? failures : null,
      'discoveryFailures': measured ? discoveryFailures : null,
      'requestFailures': measured ? requestFailures : null,
      'terminalFailures': measured ? terminalFailures : null,
      'playerErrors': playing == null ? null : playerErrors,
      'separateAudioExpected': separateAudioExpected,
      'nativeAudioTrackCount': nativeAudioTracks,
      'maxNativeAudioTrackCount': maxNativeAudioTracks,
      'nativeAudioTracksBeforeCompleted': audioTracksBeforeCompleted,
      'nativeAudioSelectedBeforeCompleted': audioSelectedBeforeCompleted,
      'playerOpenCount': playerOpenCount,
      'seekCommandFailures': seekCommandFailures,
      'nativeAudioSelected': nativeAudioSelected,
      'nativePlayerVolume': nativePlayerVolume,
      'networkBytesIncludingProbesAndHedges': measured ? networkBytes : null,
      'networkBps5s': measured
          ? networkRates.values.fold<double>(0, (a, b) => a + b)
          : null,
      'networkBpsByTrack5s': measured ? networkRates : null,
      'networkBytesByTrack': measured
          ? Map<String, int>.of(networkByTrack)
          : null,
      'loopbackDeliveredBytes': measured ? deliveredBytes : null,
      'deliveredByTrack': measured
          ? Map<String, int>.of(deliveredByTrack)
          : null,
      'loopbackDeliveredBpsByTrack5s': measured ? deliveryRates : null,
      'loopbackDeliveredBps5s': measured
          ? deliveryRates.values.fold<double>(0, (a, b) => a + b)
          : null,
      'nativeMainDemuxQueueBytes': nativeQueueBytes,
      'nativeMainDemuxInputBps': nativeInputBps,
      'retries': measured ? retries : null,
      'hedges': measured ? hedges : null,
      'resumes': measured ? resumes : null,
      'resumedPrefixBytes': measured ? resumedBytes : null,
      'cancellations': measured ? cancellations : null,
      'upstreamCancellations': measured ? upstreamCancellations : null,
      'eventsDropped': droppedEvents,
      'events': events.toList(),
    };
  }
}
