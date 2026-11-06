import 'dart:convert';
import 'dart:math' as math;

/// Last cached timestamp can belong to a disjoint range near EOF after seek.
/// Only count the cached range containing the current playback position.
abstract final class BtrBufferAhead {
  static double? read(String Function(String) property, double position) {
    try {
      final state = jsonDecode(property('demuxer-cache-state'));
      if (state is! Map ||
          state['seekable-ranges'] is! List ||
          !position.isFinite ||
          position < 0) {
        return null;
      }
      final ranges = state['seekable-ranges'] as List;
      if (ranges.length > 64) return null;
      final valid = <(double, double)>[];
      for (final range in ranges) {
        if (range is! Map) return null;
        final start = range['start'], end = range['end'];
        if (start is! num ||
            end is! num ||
            !start.isFinite ||
            !end.isFinite ||
            end < start) {
          return null;
        }
        valid.add((start.toDouble(), end.toDouble()));
      }
      valid.sort((a, b) => a.$1.compareTo(b.$1));
      var end = position;
      var found = false;
      for (final range in valid) {
        if (range.$1 <= end && range.$2 >= position) {
          end = math.max(end, range.$2);
          found = true;
        }
      }
      if (!found) return 0;
      var ahead = end - position;
      // A range may include old packets behind the demuxer's reader. Its
      // forward duration is an additional upper bound, never a replacement.
      final duration = state['cache-duration'];
      if (duration is num && duration.isFinite && duration >= 0) {
        ahead = math.min(ahead, duration.toDouble());
      }
      return ahead;
    } catch (_) {
      return null;
    }
  }
}
