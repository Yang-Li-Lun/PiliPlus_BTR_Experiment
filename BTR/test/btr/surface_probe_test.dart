import 'dart:convert';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/surface_probe.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test(
    'same reported handle across unload and reload does not change ownership',
    () {
      final probe = BtrSurfaceProbe();
      expect(probe.loaded((_) => '12345678901234'), {
        'load': 1,
        'unloads': 0,
        'widNonzero': true,
      });
      expect(probe.unloaded((_) => '0'), {
        'load': 1,
        'unloads': 1,
        'widKnown': true,
        'widCleared': true,
      });
      expect(
        probe.loaded((_) => '12345678901234')['widSameAsPreviousLoad'],
        true,
      );
      expect(
        probe.loaded((_) => '22345678901234')['widSameAsPreviousLoad'],
        false,
      );
    },
  );

  test(
    'unknown observations do not fabricate reuse or retain native values',
    () {
      final probe = BtrSurfaceProbe()..loaded((_) => '12345678901234');
      for (final raw in [
        '',
        '0',
        '-1',
        'secret.invalid/?token=x',
        '9' * 100000,
      ]) {
        final result = probe.loaded((_) => raw);
        expect(result['widNonzero'], false);
        expect(result.containsKey('widSameAsPreviousLoad'), false);
        expect(jsonEncode(result), isNot(contains('12345678901234')));
      }
      expect(
        probe
            .loaded((_) => '12345678901234')
            .containsKey('widSameAsPreviousLoad'),
        false,
      );
      expect(probe.unloaded((_) => throw StateError('secret')), {
        'load': 7,
        'unloads': 1,
        'widKnown': false,
      });
      expect(probe.unloaded((_) => '12345678901234')['widCleared'], false);
    },
  );

  test(
    'video pipeline reads are opt-in and reject arbitrary driver strings',
    () {
      final metrics = BtrMetrics(BtrMode.combined);
      final keys = <String>[];
      metrics.sampleNativeAv((key) {
        keys.add(key);
        return 'no';
      });
      expect(keys, isNot(contains('hwdec-current')));
      expect(metrics.nativeAvProbe!.containsKey('hwdec-current'), false);
      for (final value in ['mediacodec', 'mediacodec-copy', 'no']) {
        metrics.sampleNativeAv((_) => value, includeVideoPipeline: true);
        expect(metrics.nativeAvProbe!['hwdec-current'], value);
      }
      metrics.sampleNativeAv(
        (_) => 'https://secret.invalid/?token=x',
        includeVideoPipeline: true,
      );
      expect(metrics.nativeAvProbe!['hwdec-current'], null);
      expect(jsonEncode(metrics.snapshot()), isNot(contains('secret.invalid')));
      expect(metrics.playerErrors, 0);
      expect(metrics.bufferingEvents, 0);
    },
  );
}
