/// Keeps explicit play/pause intent separate from mpv's automatic EOF pause.
/// Native seek completion does not unpause `keep-open=yes` playback. Only the
/// latest seek may restore that intent; a new source or explicit pause wins.
class PlaybackSeekIntent {
  bool _playRequested = false;
  bool _resumePending = false;
  int _intentRevision = 0;
  int _seekRevision = 0;
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
  }

  Future<bool> seek({
    required bool completed,
    required Future<void> Function(bool Function() isCurrent) perform,
    required Future<void> Function() resume,
    bool Function()? isCurrentSource,
  }) async {
    final revision = ++_seekRevision;
    final intentRevision = _intentRevision;
    bool isCurrentSeek() =>
        revision == _seekRevision && (isCurrentSource?.call() ?? true);
    if (completed && _playRequested) _resumePending = true;

    await perform(isCurrentSeek);
    if (!isCurrentSeek()) return false;
    // Carry pending EOF intent across overlapping seeks even after the first
    // native seek has already cleared PlayerState.completed.
    if (_resumePending && _playRequested && intentRevision == _intentRevision) {
      _resumePending = false;
      await resume();
    }
    return isCurrentSeek();
  }
}
