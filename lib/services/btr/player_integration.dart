part of '../../plugin/pl_player/controller.dart';

// BTR recovery hooks share the controller's source/seek ownership. Keep these
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
}
