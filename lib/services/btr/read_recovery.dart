/// Evidence for one native load/seek, independent of proxy error arrival order.
/// A network log is a read failure signal, not attribution to a CDN or socket.
class BtrReadRecovery {
  bool failed = false;
  bool abnormalCompleted = false;
  Duration? resumePosition;
  Duration? _previousPosition;
  int revision = 0;
  int? _stallSince;
  Duration? _stallPosition;

  /// A stationary clock alone is not a transport failure. Require prolonged
  /// waiting AND recent, same-generation proxy/head failure evidence.
  bool observeStall({
    required int now,
    required Duration position,
    required bool waiting,
    required bool eligible,
    required int? failureAt,
  }) {
    if (!eligible || !waiting) {
      _stallSince = null;
      _stallPosition = null;
      return false;
    }
    if (_stallPosition == null || position != _stallPosition) {
      _stallSince = now;
      _stallPosition = position;
    }
    if (_stallSince == null ||
        now - _stallSince! < 15000 ||
        failureAt == null ||
        failureAt < _stallSince! - 1000 ||
        now - failureAt > 30000) {
      return false;
    }
    failed = true;
    resumePosition ??= position;
    return true;
  }

  static String? classify(String message) {
    final text = message.trim();
    if (RegExp(
      r'\bHTTP error [45]\d\d\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'http-status';
    }
    if (RegExp(r'\bffurl_read returned\s+').hasMatch(text)) {
      return 'native-read';
    }
    if ((text.startsWith('Failed to open ') ||
            text.startsWith('Can not open external file ')) &&
        text.contains('http://127.0.0.1:')) {
      return 'proxy-open';
    }
    return null;
  }

  bool record(String message, Duration position) {
    if (classify(message) == null) return false;
    failed = true;
    resumePosition ??= position;
    return true;
  }

  void reset() {
    failed = abnormalCompleted = false;
    resumePosition = _previousPosition = null;
    _stallSince = null;
    _stallPosition = null;
    revision++;
  }

  void position(Duration position, {required bool advancing}) {
    final previous = _previousPosition;
    _previousPosition = position;
    if (advancing && previous != null && position > previous) {
      reset();
      _previousPosition = position;
    }
  }

  bool acceptCompleted(Duration position, Duration duration, Duration? target) {
    // An explicit seek to the end is completion; a target elsewhere is not.
    if (duration > Duration.zero && target != null && target >= duration) {
      reset();
      return true;
    }
    final premature =
        duration > Duration.zero &&
        position + const Duration(seconds: 2) < duration;
    if (target != null || failed || premature) {
      abnormalCompleted = true;
      resumePosition ??= target ?? position;
      return false;
    }
    return true;
  }
}
