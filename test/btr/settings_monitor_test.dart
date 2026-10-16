import 'dart:io';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/monitor_data.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:hive_ce/hive.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  late Directory directory;
  late Box<dynamic> box;
  BtrSettingsStore store() => BtrSettingsStore(
    (key) => box.get(key),
    (values) => box.putAll(values),
  );

  setUp(() async {
    final base = Directory('${Directory.current.path}/.dart_tool');
    await base.create(recursive: true);
    directory = await base.createTemp('btr-settings-');
    Hive.init(directory.path);
    box = await Hive.openBox<dynamic>('btr-test-settings');
  });
  tearDown(() async {
    await box.close();
    await directory.delete(
      recursive: true,
    ); // Only this test's generated folder.
  });

  for (final old in ['original', 'threaded', 'switcher', 'combined']) {
    test(
      'Hive reopen preserves/migrates $old and unrelated settings',
      () async {
        await box.putAll({
          BtrSettingsStore.modeKey: old,
          'outsideBtr': 'untouched',
        });
        final result = await store().load();
        final expected = old == 'original'
            ? BtrMode.original
            : BtrMode.combined;
        expect(result.mode, expected);
        await box.close();
        box = await Hive.openBox<dynamic>('btr-test-settings');
        expect(box.get(BtrSettingsStore.modeKey), expected.name);
        expect(store().current.mode, expected);
        expect(box.get('outsideBtr'), 'untouched');
      },
    );
  }

  test(
    'all settings survive disk reopen; session snapshot remains immutable',
    () async {
      final before = store().current;
      const settings = BtrSettings(
        mode: BtrMode.original,
        autoConcurrency: false,
        manualThreads: 128,
        preferredCdn: 'upos-sz-mirrorcos.bilivideo.com',
        monitorEnabled: false,
        detailedDiagnostics: true,
        showErrors: false,
        showTransfers: true,
      );
      await store().save(settings);
      await box.close();
      box = await Hive.openBox<dynamic>('btr-test-settings');
      expect(store().current.options, settings.options);
      expect(store().current.mode, BtrMode.original);
      expect(before.mode, BtrMode.combined);
      expect(before.autoConcurrency, isTrue);
      expect(before.preferredCdn, isNull);
    },
  );

  test('malformed persisted settings cannot inject hosts or concurrency', () {
    final s = BtrSettings.decode('threaded', {
      'autoConcurrency': 'false',
      'manualThreads': 1024,
      'preferredCdn': 'https://a.mcdn.bilivideo.cn/v.m4s?secret=x',
      'monitorEnabled': 0,
    });
    expect(s.mode, BtrMode.combined);
    expect(s.autoConcurrency, isTrue);
    expect(s.manualThreads, 8);
    expect(s.preferredCdn, isNull);
    expect(s.monitorEnabled, isTrue);
    final spec = BtrTrackSpec(
      kind: 'video',
      urls: ['https://origin.bilivideo.com/v.m4s?token=fixture'],
    );
    final normal = BtrSourcePolicy.candidates(spec, BtrMode.combined);
    expect(
      BtrSourcePolicy.candidates(
        spec,
        BtrMode.combined,
        preferredHost: 'a.mcdn.bilivideo.cn',
      ),
      normal,
    );
    expect(
      BtrSourcePolicy.candidates(
        spec,
        BtrMode.combined,
        preferredHost: BtrSourcePolicy.switcherHosts[2],
      ).toSet(),
      normal.toSet(),
    );
    expect(
      s
          .copyWith(preferredCdn: BtrSourcePolicy.preferred)
          .copyWith(clearCdn: true)
          .preferredCdn,
      isNull,
    );
  });

  test(
    'track and total rates separate network/probe/hedge bytes from delivery',
    () {
      var now = 0;
      final m = BtrMetrics(BtrMode.combined, clock: () => now);
      expect(m.snapshot()['networkBps5s'], isNull);
      expect(m.snapshot()['retries'], isNull);
      expect(m.snapshot()['bufferAheadSeconds'], isNull);
      m.registerTrack('video');
      expect(m.snapshot()['networkBps5s'], 0);
      expect(
        BtrMonitorData(m.snapshot()).trackValue('networkBpsByTrack5s', 'audio'),
        isNull,
      );
      m
        ..received('video', 10000)
        ..received('audio', 5000)
        ..delivered('video', 6000)
        ..delivered('audio', 4000);
      final data = m.snapshot();
      expect(data['networkBytesIncludingProbesAndHedges'], 15000);
      expect(data['loopbackDeliveredBytes'], 10000);
      expect(data['networkBps5s'], 3000);
      expect(data['loopbackDeliveredBps5s'], 2000);
      expect(data['networkBpsByTrack5s'], {'video': 2000.0, 'audio': 1000.0});
      expect(data['loopbackDeliveredBpsByTrack5s'], {
        'video': 1200.0,
        'audio': 800.0,
      });
      now = 6000;
      expect(m.snapshot()['networkBps5s'], 0);
      expect(m.snapshot()['loopbackDeliveredBps5s'], 0);
      expect(m.snapshot()['loopbackDeliveredBytes'], 10000);
      final original = BtrMetrics(BtrMode.original)..playing = false;
      final native = original.snapshot();
      for (final key in [
        'networkBps5s',
        'deliveredByTrack',
        'hedges',
        'retries',
        'resumes',
        'transportFailures',
      ]) {
        expect(native[key], isNull, reason: key);
      }
    },
  );

  test(
    'presentation preserves unknown values, state, failure and event filters',
    () {
      expect(BtrMonitorData.count(null), '未取得');
      expect(BtrMonitorData.bytes(null, rate: true), '未取得');
      expect(BtrMonitorData.bytes(0, rate: true), '0 B/s');
      expect(BtrMonitorData.seconds(null), '未取得');
      final m = BtrMetrics(BtrMode.combined)
        ..event('source-failed', {
          'host': 'origin.bilivideo.com',
          'reason': 'range-status',
        })
        ..event('hedge')
        ..event('player-error')
        ..playing = true;
      final view = BtrMonitorData(m.snapshot());
      expect(view.state, '播放中');
      expect(view.visibleEvents(errors: true, transfers: false).length, 2);
      expect(
        view.visibleEvents(errors: false, transfers: true).single['event'],
        'hedge',
      );
      expect(view.visibleEvents(errors: false, transfers: false), isEmpty);
      expect(view.cdn('audio'), contains('未取得'));
      m.ended = true;
      expect(BtrMonitorData(m.snapshot()).state, '已關閉');
      const failed = BtrMonitorData({
        'tracks': [
          {
            'kind': 'video',
            'host': null,
            'selection': 'failed',
            'terminal': true,
          },
        ],
      });
      expect(failed.cdn('video'), contains('選源失敗'));
    },
  );
}
