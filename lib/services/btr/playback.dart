import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/btr/diagnostics.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/read_recovery.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:PiliPlus/services/playback_task_scope.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

class BtrPlayback {
  static final settingsStore = BtrSettingsStore(
    (key) => GStorage.setting.get(key),
    (values) => GStorage.setting.putAll(values),
  );
  static BtrSettings get selectedSettings => settingsStore.current;
  static final settingsRevision = ValueNotifier<int>(0);
  static Future<void> saveSettings(BtrSettings settings) async {
    await settingsStore.save(settings);
    settingsRevision.value++;
  }

  static BtrPlayback? current;
  static final recent = <Map<String, Object?>>[];

  BtrPlayback(this.settings) : metrics = BtrMetrics(settings.mode) {
    _taskScope = PlaybackTaskScope(onClose: _closeResources);
  }
  final BtrSettings settings;
  BtrMode get mode => settings.mode;
  final BtrMetrics metrics;
  final readRecovery = BtrReadRecovery();
  BtrTransport? transport;
  Timer? _meter;
  final _subscriptions = <StreamSubscription>[];
  late final PlaybackTaskScope _taskScope;
  bool get _closed => _taskScope.closed;

  static Future<(BtrPlayback?, DataSource)> prepare(
    DataSource source,
    bool live,
  ) async {
    if (!Platform.isAndroid || live || source is! NetworkSource) {
      return (null, source);
    }
    final playback = BtrPlayback(selectedSettings);
    playback.metrics.separateAudioExpected =
        source.audioSource?.isNotEmpty == true;
    try {
      await settingsStore.load();
    } catch (_) {
      playback.metrics.event('settings-migration-failed');
    }
    if (playback._closed) return (null, source);
    current = playback;
    if (playback.mode == BtrMode.original || source.videoCandidates.isEmpty) {
      playback.metrics.transportMeasured = false;
      playback.metrics.event('native-path');
      return (playback, source);
    }
    final transport = BtrTransport(
      mode: playback.mode,
      metrics: playback.metrics,
      settings: playback.settings,
      headers: {'User-Agent': BrowserUa.pc, 'Referer': HttpString.baseUrl},
    );
    playback.transport = transport;
    try {
      final urls = await transport.start([
        BtrTrackSpec(kind: 'video', urls: source.videoCandidates),
        if (source.audioCandidates.isNotEmpty)
          BtrTrackSpec(kind: 'audio', urls: source.audioCandidates),
      ]);
      if (playback._closed) return (null, source);
      playback.metrics.transportMeasured = urls.isNotEmpty;
      if (!urls.containsKey('video')) {
        playback.metrics.event('native-video-fallback');
      }
      if (source.audioSource?.isNotEmpty == true &&
          !urls.containsKey('audio')) {
        playback.metrics.event('native-audio-fallback');
      }
      return (
        playback,
        NetworkSource(
          videoSource: urls['video'] ?? source.videoSource,
          audioSource: urls['audio'] ?? source.audioSource,
        ),
      );
    } catch (_) {
      await transport.close();
      if (playback._closed) return (null, source);
      playback.transport = null;
      playback.metrics.transportMeasured = false;
      playback.metrics.event('native-fallback', {
        'reason': 'local-service-unavailable',
      });
      return (playback, source);
    }
  }

  void attach(
    Player player, {
    void Function()? onTerminalFailure,
    void Function()? onReadStall,
  }) {
    if (_closed) return;
    var terminalReported = false;
    void reportTerminal() {
      if (_closed ||
          terminalReported ||
          transport?.tracks.values.any((track) => track.terminal) != true) {
        return;
      }
      terminalReported = true;
      onTerminalFailure?.call();
    }

    Duration? observedBuffer;
    metrics.playing = player.state.playing;
    _subscriptions.add(player.stream.buffering.listen(metrics.buffering));
    _subscriptions.add(
      player.stream.buffer.listen((value) => observedBuffer = value),
    );
    _subscriptions.add(
      player.stream.playing.listen((value) => metrics.playing = value),
    );
    _subscriptions.add(
      player.stream.completed.listen(metrics.nativeCompleted),
    );
    _subscriptions.add(
      player.stream.position.listen((p) {
        metrics.position(p.inMilliseconds, player.state.playing);
      }),
    );
    _subscriptions.add(
      player.stream.tracks.listen((tracks) {
        final count = tracks.audio
            .where((track) => track.id != 'auto' && track.id != 'no')
            .length;
        metrics.nativeTracks(count, metrics.nativeAudioSelected);
      }),
    );
    _subscriptions.add(
      player.stream.track.listen((track) {
        final selected = track.audio.id == 'auto'
            ? null
            : track.audio.id != 'no';
        // Unknown until a track-list event has actually been observed.
        if (metrics.nativeAudioTracks case final count?) {
          metrics.nativeTracks(count, selected);
        }
      }),
    );
    _subscriptions.add(
      player.stream.error.listen((message) {
        metrics.playerError(
          message,
          transportTerminal:
              transport?.tracks.values.any((track) => track.terminal) ?? false,
        );
        reportTerminal();
      }),
    );
    if (transport != null) {
      _subscriptions.add(
        player.stream.log.listen((log) {
          metrics.nativeLog(log.prefix, log.level, log.text);
        }),
      );
    }
    _meter = Timer.periodic(const Duration(milliseconds: 500), (_) {
      reportTerminal();
      if (_closed) return;
      onReadStall?.call();
      metrics.nativePlayerVolume = player.state.volume;
      if (transport != null) metrics.sampleNativeAv(player.getProperty);
      metrics.bufferAheadSeconds = observedBuffer == null
          ? null
          : ((observedBuffer! - player.state.position).inMilliseconds / 1000)
                .clamp(0.0, double.infinity);
      transport?.adaptive.demand(
        playing: player.state.playing,
        buffering: player.state.buffering,
        ahead:
            (player.state.buffer - player.state.position).inMilliseconds / 1000,
      );
      try {
        final bytes = int.tryParse(
          player.getProperty('demuxer-cache-state/total-bytes'),
        );
        metrics.nativeQueueBytes = bytes != null && bytes >= 0 ? bytes : null;
        final rate = int.tryParse(player.getProperty('cache-speed'));
        metrics.nativeInputBps = rate != null && rate >= 0 ? rate : null;
      } catch (_) {
        metrics.nativeQueueBytes = null;
        metrics.nativeInputBps = null;
      }
    });
  }

  void seek(Duration position) {
    readRecovery.reset();
    metrics.seek(position.inMilliseconds);
    transport?.seek();
  }

  Map<String, Object?> snapshot() {
    final data = metrics.snapshot();
    final events = data.remove('events');
    return {
      ...data,
      'sessionSettings': {'mode': mode.name, ...settings.options},
      if (transport case final value?) ...value.snapshot(),
      'events': events,
    };
  }

  static Map<String, Object?> diagnosticSnapshot() => BtrDiagnostics.report(
    selectedSettings: {
      'mode': selectedSettings.mode.name,
      ...selectedSettings.options,
    },
    current: current?.snapshot(),
    recent: recent,
  );

  static String diagnosticReport() => BtrDiagnostics.full(diagnosticSnapshot());

  static String compactDiagnosticReport() =>
      BtrDiagnostics.compact(diagnosticSnapshot());

  Future<void> close() => _taskScope.close();

  Future<void> _closeResources() async {
    _meter?.cancel();
    final cancelled = _subscriptions.map((sub) => sub.cancel()).toList();
    _subscriptions.clear();
    await Future.wait([
      if (transport != null) transport!.close(),
      ...cancelled,
    ]);
    metrics.ended = true;
    recent.add(snapshot());
    if (recent.length > 8) recent.removeAt(0);
    if (identical(current, this)) current = null;
  }
}
