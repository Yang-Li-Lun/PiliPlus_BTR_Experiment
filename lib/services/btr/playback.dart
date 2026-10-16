import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:media_kit/media_kit.dart';

class BtrPlayback {
  static const settingKey = 'btrExperimentModeV1';
  static BtrMode get selectedMode =>
      BtrMode.parse(GStorage.setting.get(settingKey));
  static BtrPlayback? current;
  static final recent = <Map<String, Object?>>[];

  BtrPlayback(this.mode) : metrics = BtrMetrics(mode);
  final BtrMode mode;
  final BtrMetrics metrics;
  BtrTransport? transport;
  Timer? _meter;
  final _subscriptions = <StreamSubscription>[];
  bool _closed = false;

  static Future<(BtrPlayback?, DataSource)> prepare(
    DataSource source,
    bool live,
  ) async {
    if (!Platform.isAndroid || live || source is! NetworkSource) {
      return (null, source);
    }
    final playback = BtrPlayback(selectedMode);
    current = playback;
    if (playback.mode == BtrMode.original || source.videoCandidates.isEmpty) {
      playback.metrics.transportMeasured = false;
      playback.metrics.event('native-path');
      return (playback, source);
    }
    final transport = BtrTransport(
      mode: playback.mode,
      metrics: playback.metrics,
      headers: {'User-Agent': BrowserUa.pc, 'Referer': HttpString.baseUrl},
    );
    playback.transport = transport;
    try {
      final urls = await transport.start([
        BtrTrackSpec(kind: 'video', urls: source.videoCandidates),
        if (source.audioCandidates.isNotEmpty)
          BtrTrackSpec(kind: 'audio', urls: source.audioCandidates),
      ]);
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
      playback.transport = null;
      playback.metrics.transportMeasured = false;
      playback.metrics.event('native-fallback', {
        'reason': 'local-service-unavailable',
      });
      return (playback, source);
    }
  }

  void attach(Player player) {
    _subscriptions.add(player.stream.buffering.listen(metrics.buffering));
    _subscriptions.add(
      player.stream.position.listen((p) {
        metrics.position(p.inMilliseconds, player.state.playing);
      }),
    );
    _subscriptions.add(
      player.stream.error.listen((_) {
        metrics.playerErrors++;
      }),
    );
    _meter = Timer.periodic(const Duration(milliseconds: 500), (_) {
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
    metrics.seek(position.inMilliseconds);
    transport?.seek();
  }

  Map<String, Object?> snapshot() => {
    ...metrics.snapshot(),
    'activeConnections': transport?.scheduler.active,
    'peakConnections': transport?.scheduler.peak,
    'concurrencyLimit': transport?.scheduler.limit,
    'tracks': transport?.tracks.values
        .map(
          (t) => {
            'kind': t.spec.kind,
            'host': t.sample?.identity.uri.host,
            'identity': t.sample == null
                ? 'pending'
                : t.sample!.identity.canSegment
                ? 'single-origin-strong-etag'
                : 'single-response',
            'peakOrderedReservationBytes': t.peakReservedBytes,
            'terminal': t.terminal,
            'health': t.health,
          },
        )
        .toList(),
  };

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _meter?.cancel();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await transport?.close();
    recent.add(snapshot());
    if (recent.length > 8) recent.removeAt(0);
    if (identical(current, this)) current = null;
  }
}
