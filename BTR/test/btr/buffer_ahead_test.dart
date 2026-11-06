import 'dart:convert';

import 'package:PiliPlus/services/btr/buffer_ahead.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  double? read(
    List<Map<String, num>> ranges,
    double position, {
    num? duration,
  }) => BtrBufferAhead.read(
    (_) => jsonEncode({
      'seekable-ranges': ranges,
      'cache-duration': ?duration,
    }),
    position,
  );

  test('tail at 4079 seconds is not 2420 seconds of playable buffer', () {
    expect(
      read([
        {'start': 4000, 'end': 4079.722},
      ], 1659.116),
      0,
    );
    expect(
      read([
        {'start': 4000, 'end': 4079.722},
        {'start': 1650, 'end': 1662},
      ], 1659),
      3,
    );
  });
  test('joins only contiguous ranges and respects forward duration', () {
    final ranges = [
      {'start': 45, 'end': 50},
      {'start': 8, 'end': 12},
      {'start': 11, 'end': 20},
      {'start': 20, 'end': 25},
    ];
    expect(read(ranges, 10), 15);
    expect(read(ranges, 10, duration: 2), 2);
    expect(read([], 10), 0);
  });
  test('unavailable, malformed and nonfinite observations remain unknown', () {
    expect(BtrBufferAhead.read((_) => 'unavailable', 0), isNull);
    expect(BtrBufferAhead.read((_) => '{}', 0), isNull);
    expect(
      BtrBufferAhead.read((_) => throw StateError('unsupported'), 0),
      isNull,
    );
    expect(
      read([
        {'start': 2, 'end': 1},
      ], 1),
      isNull,
    );
    expect(read([], double.nan), isNull);
  });
}
