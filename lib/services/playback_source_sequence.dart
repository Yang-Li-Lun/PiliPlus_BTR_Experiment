/// Serializes source ownership, including native player/surface creation and
/// disposal of the previous source's independent audio/video transport.
class PlaybackSourceSequence {
  Future<void> _settled = Future.value();
  int _revision = 0;

  /// Superseded queued sources never open. A running source can check its
  /// revision after an await before publishing state or starting playback.
  Future<void> run(
    Future<void> Function(bool Function() isCurrent) operation,
  ) {
    final revision = ++_revision;
    bool isCurrent() => revision == _revision;
    final pending = _settled.then((_) async {
      if (isCurrent()) await operation(isCurrent);
    });
    // A failed open must not prevent a subsequent explicit source selection.
    _settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }
}
