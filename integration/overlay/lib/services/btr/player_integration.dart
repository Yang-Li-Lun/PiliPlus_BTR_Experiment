part of '../../plugin/pl_player/controller.dart';

// BTR source, seek, recovery and diagnostic hooks share the controller's source/seek ownership. Keep these
// private to this library; transport and policy remain independent modules.
extension _BtrPlayerIntegration on PlPlayerController {
  Future<void> _stopTerminalBtr(
    BtrPlayback session, {
    bool stalled = false,
  }) async {
    final generation = _btrOpenGeneration;
    if (_taskScope.closed ||
        !identical(_btrPlayback, session) ||
        _btrFailedGeneration == generation ||
        (!stalled &&
            session.transport?.tracks.values.any((track) => track.terminal) !=
                true)) {
      return;
    }
    final player = _videoPlayerController;
    _btrFailedGeneration = generation;
    if (_btrSourceIsCurrent?.call() ?? true) {
      _seekIntent.requestPlaying(false);
      dataStatus.value = DataStatus.error;
      isBuffering.value = false;
      playerStatus = .paused;
      _updatePlaybackState();
      SmartDialog.showToast(
        stalled ? '播放恢復後仍無進展，請重新開啟影片或改用原始模式' : '實驗傳輸已停止，請重新開啟影片或改用原始模式',
      );
    }
    try {
      // Capture the player before the await; a stale failure must not pause a
      // replacement source or publish its status after the source has changed.
      await Future.wait([
        if (player != null) player.pause(),
        session.close(),
      ]);
    } catch (error) {
      if (kDebugMode) debugPrint('terminal BTR pause failed: $error');
    }
    if (_taskScope.closed ||
        generation != _btrOpenGeneration ||
        !identical(_btrPlayback, session) ||
        !(_btrSourceIsCurrent?.call() ?? true)) {
      return;
    }
    audioSessionHandler?.setActive(false);
  }

  void _scheduleBtrReadRecovery(BtrPlayback session) {
    if (_taskScope.closed || !identical(session, _btrPlayback)) return;
    final pendingSeek = _seekIntent.pendingTarget != null;
    final recoverSeek =
        pendingSeek &&
        (session.readRecovery.failed ||
            session.transport?.currentSeekHasLocalFailure == true);
    if (_processing ||
        _reopening ||
        _btrAutomaticReopens >= 1 ||
        (pendingSeek && !recoverSeek)) {
      session.metrics.event('player-reopen-skipped', {
        'reason': _btrAutomaticReopens >= 1
            ? 'retry-budget'
            : _processing || _reopening
            ? 'opening'
            : 'seek-pending',
      });
      return;
    }
    // Keep the first deadline: repeated native errors must not starve recovery.
    if (_retryTimer?.isActive == true) return;
    final generation = _btrOpenGeneration;
    final seekRevision = _seekIntent.seekRevision;
    final readRevision = session.readRecovery.revision;
    _retryTimer = Timer(const Duration(seconds: 3), () {
      _retryTimer = null;
      if (!_taskScope.closed &&
          generation == _btrOpenGeneration &&
          identical(session, _btrPlayback) &&
          seekRevision == _seekIntent.seekRevision &&
          readRevision == session.readRecovery.revision &&
          (recoverSeek
              ? _seekIntent.pendingTarget != null &&
                    (session.readRecovery.failed ||
                        session.transport?.currentSeekHasLocalFailure == true)
              : session.readRecovery.abnormalCompleted ||
                    (isBuffering.value && session.readRecovery.failed))) {
        refreshPlayer(automatic: true, recoverSeek: recoverSeek);
      }
    });
  }

  void _checkBtrReadStall(BtrPlayback session) {
    final player = _videoPlayerController;
    if (player == null ||
        session.transport == null ||
        _taskScope.closed ||
        !identical(session, _btrPlayback) ||
        !(_btrSourceIsCurrent?.call() ?? true) ||
        _btrFailedGeneration == _btrOpenGeneration) {
      return;
    }
    final waiting =
        player.state.buffering || session.readRecovery.abnormalCompleted;
    final eligible = _seekIntent.playRequested && !_processing && !_reopening;
    // A classified native read error can arrive while open/reopen owns the
    // source queue. Reconsider that latched evidence after opening finishes;
    // no second native error or proxy failure is required to arm the timer.
    if (eligible &&
        session.readRecovery.failed &&
        (waiting || _seekIntent.pendingTarget != null) &&
        _btrAutomaticReopens < 1) {
      _scheduleBtrReadRecovery(session);
    }
    if (!session.readRecovery.observeStall(
      now: session.metrics.now(),
      position: player.state.position,
      waiting: waiting,
      eligible: eligible,
      failureAt: session.transport!.currentReadFailureAt,
    )) {
      return;
    }
    if (_btrAutomaticReopens >= 1) {
      session.metrics.event('player-recovery-exhausted', {
        'reason': 'read-stall',
      });
      _stopTerminalBtr(session, stalled: true);
      return;
    }
    if (_retryTimer?.isActive != true) {
      session.metrics.event('player-read-stall', {
        'seekRevision': _seekIntent.seekRevision,
        'positionMs': player.state.position.inMilliseconds,
      });
    }
    _scheduleBtrReadRecovery(session);
  }

  bool _handleBtrNativeError(String event) {
    final session = _btrPlayback;
    if (session?.transport == null) return false;
    if (_taskScope.closed || !(_btrSourceIsCurrent?.call() ?? true)) {
      return true;
    }
    if (session!.transport!.tracks.values.any((track) => track.terminal)) {
      _stopTerminalBtr(session);
      return true;
    }
    if (!session.readRecovery.record(
      event,
      _videoPlayerController!.state.position,
    )) {
      return false;
    }
    session.metrics.event('native-read-failure', {
      'kind': BtrReadRecovery.classify(event)!,
      'localFailureObserved': session.transport!.currentSeekHasLocalFailure,
      'seekRevision': _seekIntent.seekRevision,
    });
    _scheduleBtrReadRecovery(session);
    return true;
  }

  bool _acceptBtrCompleted(Player player) {
    final session = _btrPlayback;
    if (session?.transport == null) return true;
    if (session!.readRecovery.acceptCompleted(
      player.state.position,
      player.state.duration,
      _seekIntent.pendingTarget,
    )) {
      return true;
    }
    session.metrics.event('player-completed-suppressed', {
      'reason': session.readRecovery.failed
          ? 'read-failure'
          : 'unconfirmed-eof',
      'positionMs': player.state.position.inMilliseconds,
      'durationMs': player.state.duration.inMilliseconds,
    });
    if (session.readRecovery.failed ||
        session.transport!.currentSeekHasLocalFailure) {
      _scheduleBtrReadRecovery(session);
    }
    if (_seekIntent.pendingTarget != null) {
      unawaited(_recoverBtrSeekEof(player));
    }
    return false;
  }

  Future<void> _recoverBtrSeekEof(Player player) async {
    final session = _btrPlayback;
    final revision = _seekIntent.seekRevision;
    final generation = _btrOpenGeneration;
    final target = _seekIntent.pendingTarget;
    if (session?.transport == null || target == null) return;
    bool eligible() =>
        !_taskScope.closed &&
        generation == _btrOpenGeneration &&
        revision == _seekIntent.seekRevision &&
        identical(player, _videoPlayerController) &&
        identical(session, _btrPlayback) &&
        (_btrSourceIsCurrent?.call() ?? true) &&
        _seekIntent.playRequested &&
        _seekIntent.pendingTarget == target &&
        _btrFailedGeneration != generation;
    try {
      await _sourceSequence.runCurrent((isCurrent) async {
        // A command reply is not a playback-restart barrier. Handle an EOF
        // that arrived AFTER it with one real seek to the still-pending target.
        // Classified read failures keep their existing bounded recovery path.
        if (!isCurrent() ||
            !eligible() ||
            !player.state.completed ||
            session!.readRecovery.failed ||
            session.transport!.currentReadFailureAt != null ||
            !_seekIntent.claimEofRecovery(revision)) {
          return;
        }
        session.metrics.event('seek-eof-correction', {
          'targetMs': target.inMilliseconds,
          'seekRevision': revision,
        });
        await player.seek(target);
        if (!isCurrent() || !eligible()) return;
        await _resumeAfterSeek(player);
      });
    } catch (_) {
      session!.metrics.seekCommand('failed', target.inMilliseconds);
    }
  }

  Future<void> _resumeAfterSeek(Player player) async {
    // Match the locked native seek/play contract: clear a late EOF flag inside
    // the SAME native lock as play's synchronous completed/replay decision.
    // Keep media-kit's playing notification and pause bookkeeping intact.
    await player.lock.synchronized(() async {
      if (!_seekIntent.playRequested ||
          _taskScope.closed ||
          !identical(player, _videoPlayerController) ||
          !(_btrSourceIsCurrent?.call() ?? true)) {
        return;
      }
      player.state.completed = false;
      await player.play(synchronized: false);
      _btrPlayback?.metrics.nativeCompleted(false);
    });
  }

  Future<bool> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
    bool Function() isCurrent, [
    int? rotate,
  ]) async {
    final generation = ++_btrOpenGeneration;
    final previousBtr = _btrPlayback;
    if (previousBtr?.transport != null) {
      // Keep the old HTTP responses alive until native consumption has stopped.
      // A failed stop must leave their owner intact instead of truncating GETs.
      await _videoPlayerController?.stop();
    }
    _btrPlayback = null;
    await previousBtr?.close();
    if (_taskScope.closed || !isCurrent() || generation != _btrOpenGeneration) {
      return false;
    }
    final (session, preparedSource) = await BtrPlayback.prepare(
      dataSource,
      isLive,
      nativeCacheSeconds: dataSource is NetworkSource && !isLive
          ? double.tryParse(buffer['cache-secs'] ?? '')
          : null,
      nativePlaybackRate: playbackSpeed,
    );
    if (!isCurrent() || generation != _btrOpenGeneration || _playerCount == 0) {
      await session?.close();
      return false;
    }
    _btrPlayback = session;
    _btrSourceIsCurrent = isCurrent;
    dataSource = preparedSource;
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (player == null) return false;
      if (_playerCount == 0 ||
          !isCurrent() ||
          generation != _btrOpenGeneration) {
        await session?.close();
        _removeListeners();
        await _taskScope.release(player);
        player = null;
        _videoController = null;
        return false;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    if (_taskScope.closed || !isCurrent() || generation != _btrOpenGeneration) {
      return false;
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
      'video-rotate': ?rotate?.toString(),
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    if (session != null) {
      session.attach(
        player,
        onTerminalFailure: () => _stopTerminalBtr(session),
        onReadStall: () => _checkBtrReadStall(session),
      );
    }
    try {
      session?.metrics.playerOpening('source', seekTo?.inMilliseconds ?? 0);
      final historyRevision =
          session?.transport != null &&
              seekTo != null &&
              _seekIntent.pendingTarget == null
          ? _seekIntent.beginSource(seekTo)
          : null;
      await player.open(
        Media(video, start: seekTo, extras: extras.isEmpty ? null : extras),
        play: false,
      );
      if (historyRevision != null) _seekIntent.sourceOpened(historyRevision);
      return isCurrent() &&
          generation == _btrOpenGeneration &&
          _btrFailedGeneration != generation &&
          _playerCount > 0;
    } catch (_) {
      await session?.close();
      if (identical(_btrPlayback, session)) _btrPlayback = null;
      rethrow;
    }
  }

  Future<void>? _refreshBtrPlayer({
    bool automatic = false,
    bool recoverSeek = false,
  }) {
    final session = _btrPlayback;
    if (_taskScope.closed ||
        _processing ||
        _reopening ||
        !(_btrSourceIsCurrent?.call() ?? true) ||
        _btrFailedGeneration == _btrOpenGeneration) {
      return null;
    }
    if (dataSource is FileSource) {
      return null;
    }
    if (automatic && session?.transport != null) {
      if ((_seekIntent.pendingTarget != null &&
              !(recoverSeek &&
                  (session!.readRecovery.failed ||
                      session.transport!.currentSeekHasLocalFailure))) ||
          _btrAutomaticReopens >= 1) {
        session!.metrics.event('player-reopen-skipped', {
          'reason': _btrAutomaticReopens >= 1 ? 'retry-budget' : 'seek-pending',
        });
        return null;
      }
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _reopening = true;
      var media = ctr.current.last;
      final target =
          _seekIntent.pendingTarget ??
          session?.readRecovery.resumePosition ??
          ctr.state.position;
      final seekRevision = _seekIntent.seekRevision;
      final readRevision = session?.readRecovery.revision;
      if (!isLive) media = media.copyWith(start: target);
      return _sourceSequence
          .runCurrent((isCurrent) async {
            if (!isCurrent() ||
                _taskScope.closed ||
                !identical(ctr, _videoPlayerController)) {
              return;
            }
            // A queued retry must not unload a newer seek's current stream.
            if (automatic && seekRevision != _seekIntent.seekRevision) {
              session?.metrics.event('player-reopen-skipped', {
                'reason': 'new-seek',
              });
              return;
            }
            // The timer may have fired before this operation obtained the
            // source queue. Timeline progress in that wait invalidates the
            // read evidence for non-seek recovery as well as seek recovery.
            if (automatic &&
                session?.transport != null &&
                readRevision != session!.readRecovery.revision) {
              session.metrics.event('player-reopen-skipped', {
                'reason': 'read-evidence-stale',
              });
              return;
            }
            if (automatic &&
                recoverSeek &&
                session?.readRecovery.failed != true &&
                session?.transport?.currentSeekHasLocalFailure != true) {
              session?.metrics.event('player-reopen-skipped', {
                'reason': 'local-failure-stale',
              });
              return;
            }
            if (automatic && session?.transport != null) _btrAutomaticReopens++;
            session?.metrics.playerOpening(
              automatic
                  ? (recoverSeek ? 'seek-read-error' : 'read-error')
                  : 'user',
              target.inMilliseconds,
            );
            try {
              await ctr.stop();
              // stop is the ownership boundary: only now may all old GETs retire.
              await session?.transport?.retirePlayerRequests();
              if (!isCurrent() ||
                  _taskScope.closed ||
                  !identical(session, _btrPlayback) ||
                  _btrFailedGeneration == _btrOpenGeneration) {
                return;
              }
              // A BTR seek during stop owns the new load's start position too.
              if (!isLive && session?.transport != null) {
                media = media.copyWith(
                  start: _seekIntent.pendingTarget ?? target,
                );
              }
              session?.readRecovery.reset();
              await ctr.open(media, play: false);
              if (!isCurrent() || _taskScope.closed) return;
              if (_seekIntent.playRequested) {
                if (session?.transport != null) {
                  await _resumeAfterSeek(ctr);
                } else {
                  await ctr.play();
                }
              }
              session?.metrics.event('player-open-ended', {
                'outcome': 'command-complete',
              });
            } catch (_) {
              session?.metrics.event('player-open-ended', {
                'outcome': 'failed',
              });
              if (isCurrent()) dataStatus.value = DataStatus.error;
            }
          })
          .whenComplete(() => _reopening = false);
    }
    return null;
  }

  Future<void> _seekBtrPlayer(Duration position, {bool isSeek = false}) async {
    _cancelSubForSeek();
    _retryTimer?.cancel();
    _retryTimer = null;
    final player = _videoPlayerController;
    if (player == null || _taskScope.closed) return;
    final generation = _btrOpenGeneration;
    final session = _btrPlayback;
    final completed = player.state.completed;
    try {
      final current = await _seekIntent.seek(
        completed: completed,
        // keep-open can pause during the command, after the captured EOF flag.
        // Original mode retains its existing seek/resume behavior.
        needsResume: session?.transport == null
            ? null
            : () => !player.state.playing || player.state.completed,
        target: position,
        serialize: (operation) =>
            _sourceSequence.runCurrent((_) => operation()),
        isCurrentSource: () =>
            !_taskScope.closed &&
            generation == _btrOpenGeneration &&
            identical(player, _videoPlayerController),
        perform: (isCurrent) async {
          if (isSeek &&
              session?.transport == null &&
              player.state.playing &&
              !completed) {
            // Keep the original playing seek's buffer synchronization, but a
            // fully buffered/paused EOF source need not emit another event.
            await player.stream.buffer
                .timeout(
                  const Duration(milliseconds: 250),
                  onTimeout: (sink) => sink.add(player.state.buffer),
                )
                .first;
          }
          if (!isCurrent() ||
              _taskScope.closed ||
              generation != _btrOpenGeneration ||
              !identical(player, _videoPlayerController)) {
            return;
          }
          danmakuController?.clear();
          session?.seek(position);
          final transport = session?.transport;
          if (!isLive &&
              transport != null &&
              transport.seekRequiresPlayerRetirement &&
              player.current.isNotEmpty) {
            final media = player.current.last;
            _reopening = true;
            session!.metrics.playerOpening(
              'seek-capacity',
              position.inMilliseconds,
            );
            try {
              // The native stop establishes that old GETs have no consumers.
              // A seek generation or blocked write alone cannot establish it.
              await player.stop();
              await transport.retirePlayerRequests();
              if (_taskScope.closed ||
                  generation != _btrOpenGeneration ||
                  _btrFailedGeneration == generation ||
                  !identical(session, _btrPlayback) ||
                  !identical(player, _videoPlayerController)) {
                return;
              }
              session.readRecovery.reset();
              await player.open(
                media.copyWith(start: _seekIntent.pendingTarget ?? position),
                play: false,
              );
              session.metrics.event('player-open-ended', {
                'outcome': 'command-complete',
              });
            } finally {
              _reopening = false;
            }
          } else {
            await player.seek(position);
          }
          session?.metrics.seekCommand(
            'command-complete',
            position.inMilliseconds,
          );
        },
        resume: () async {
          if (player.state.duration > Duration.zero &&
              position >= player.state.duration) {
            return;
          }
          // NativePlayer.play replays from zero if a late eof-reached event
          // reasserted completed after seek's command reply. Resume the chosen
          // position without entering that replay branch or issuing loadfile.
          await _resumeAfterSeek(player);
          if (_seekIntent.playRequested && !_taskScope.closed) {
            audioSessionHandler?.setActive(true);
          }
        },
      );
      if (current &&
          generation == _btrOpenGeneration &&
          identical(player, _videoPlayerController)) {
        if (playerStatus.isCompleted && !player.state.completed) {
          playerStatus = player.state.playing ? .playing : .paused;
          _updatePlaybackState(position: position);
        }
        _updateIOSPip(position);
      }
    } catch (e) {
      session?.metrics.seekCommand('failed', position.inMilliseconds);
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  void _attachBtrSurfaceProbe(Player player) {
    if (const bool.fromEnvironment('BTR_DEVICE_TEST')) {
      final probe = BtrSurfaceProbe();
      // Appended after the Android controller's surface load/unload hooks.
      player.onLoadHooks.add(() {
        if (_taskScope.closed) return;
        _btrPlayback?.metrics.event(
          'native-surface-load',
          probe.loaded((key) => BtrNativeProperty.read(player, key)),
        );
      });
      player.onUnloadHooks.add(() {
        if (_taskScope.closed) return;
        _btrPlayback?.metrics.event(
          'native-surface-unload',
          probe.unloaded((key) => BtrNativeProperty.read(player, key)),
        );
      });
    }
  }

  void _observeBtrPosition(Player player, Duration position) {
    final wasSeeking = _seekIntent.pendingTarget != null;
    final btrSeek = _btrPlayback?.transport != null;
    _seekIntent.position(
      position,
      requireProgress: btrSeek,
      advancing:
          !btrSeek ||
          (player.state.playing &&
              !player.state.buffering &&
              !player.state.completed),
    );
    _btrPlayback?.readRecovery.position(
      position,
      advancing:
          _seekIntent.pendingTarget == null &&
          player.state.playing &&
          !player.state.buffering,
    );
    if (wasSeeking &&
        _seekIntent.pendingTarget == null &&
        position < player.state.duration &&
        player.state.completed) {
      // Native seek's reply is not a playback-restart barrier. Only actual
      // forward progress near the target can dismiss a late EOF flag.
      player.state.completed = false;
      _btrPlayback?.metrics.nativeCompleted(false);
      playerStatus = player.state.playing ? .playing : .paused;
    }
  }
}
