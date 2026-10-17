/// Keeps explicit play/pause intent separate from mpv's automatic EOF pause.
/// Native seek completion does not unpause `keep-open=yes` playback. Only the
/// latest seek may restore that intent; a new source or explicit pause wins.
class PlaybackSeekIntent {
  bool _playRequested = false;
  bool _resumePending = false;
  int _intentRevision = 0;
  int _seekRevision = 0;
  Duration? _target;
  Duration? _lastPosition;
  bool _commandCompleted = false;
  Duration? get pendingTarget => _target;
  int get seekRevision => _seekRevision;
  bool get playRequested => _playRequested;
  int get revision => _intentRevision;

  int requestPlaying(bool playing) {
    _playRequested = playing;
    _resumePending = false;
    return ++_intentRevision;
  }

  bool isCurrent(int revision) => revision == _intentRevision;

  void reset({bool playing = false}) {
    requestPlaying(playing);
    _seekRevision++;
    _target = null;
    _lastPosition = null;
    _commandCompleted = false;
  }

  void position(Duration position) {
    final previous = _lastPosition;
    _lastPosition = position;
    if (_commandCompleted &&
        _target != null &&
        previous != null &&
        position > previous &&
        (position - _target!).inMilliseconds.abs() < 2500) {
      _target = null;
    }
  }

  /// Seeking deliberately to the end must still publish natural completion.
  /// An EOF for a different, pending target cannot finish that seek.
  bool acceptCompleted(Duration duration) {
    if (_target != null && duration > Duration.zero && _target! >= duration) {
      _target = null;
      _resumePending = false;
    }
    return _target == null;
  }

  Future<bool> seek({
    required bool completed,
    required Future<void> Function(bool Function() isCurrent) perform,
    required Future<void> Function() resume,
    bool Function()? isCurrentSource,
    Duration? target,
    Future<void> Function(Future<void> Function())? serialize,
  }) async {
    final revision = ++_seekRevision;
    _target = target;
    _lastPosition = null;
    _commandCompleted = false;
    final intentRevision = _intentRevision;
    bool isCurrentSeek() =>
        revision == _seekRevision && (isCurrentSource?.call() ?? true);
    if (completed && _playRequested) _resumePending = true;

    var performed = false;
    Future<void> execute() async {
      if (!isCurrentSeek()) return;
      await perform(isCurrentSeek);
      if (!isCurrentSeek()) return;
      performed = true;
      _commandCompleted = true;
      _lastPosition = null;
      // Carry pending EOF intent across coalesced seeks, including a seek
      // queued after the first native command has cleared completed.
      if (_resumePending &&
          _playRequested &&
          intentRevision == _intentRevision) {
        _resumePending = false;
        await resume();
      }
    }

    if (serialize == null) {
      await execute();
    } else {
      await serialize(execute);
    }
    return performed && isCurrentSeek();
  }
}
