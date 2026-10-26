/// Bounded local-consumer idle time; upstream deadlines remain independent.
abstract final class BtrLocalWriteBudget {
  static const base = Duration(seconds: 15);
  static const maximum = Duration(seconds: 75);

  static Duration forNativeCache({
    double? cacheSeconds,
    double playbackRate = 1,
  }) {
    if (cacheSeconds == null ||
        !cacheSeconds.isFinite ||
        cacheSeconds <= 0 ||
        !playbackRate.isFinite ||
        playbackRate <= 0) {
      return base;
    }
    final wallSeconds = cacheSeconds / playbackRate;
    if (!wallSeconds.isFinite) return maximum;
    final seconds = (wallSeconds + base.inSeconds).clamp(
      base.inSeconds.toDouble(),
      maximum.inSeconds.toDouble(),
    );
    return Duration(milliseconds: (seconds * 1000).ceil());
  }

  static void validate(Duration timeout) {
    if (timeout <= Duration.zero || timeout > maximum) {
      throw ArgumentError.value(
        timeout,
        'localWriteIdleTimeout',
        'must be positive and at most 75 seconds',
      );
    }
  }
}
