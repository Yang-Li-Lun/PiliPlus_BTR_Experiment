import 'dart:async';

import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:PiliPlus/services/btr/settings_controller.dart';
import 'package:PiliPlus/services/btr/ui/settings_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'migration and saves serialize; failures leave future saves usable',
    () async {
      final data = <String, Object?>{
        BtrSettingsStore.modeKey: 'threaded',
        'defaultCDNService': 3,
        'playerPreference': 'unchanged',
      };
      final migration = Completer<void>();
      var fail = false;
      final controller = BtrSettingsController(
        BtrSettingsStore(
          (key) => data[key],
          (values) async {
            if (values.length == 1) await migration.future;
            if (fail) throw StateError('disk write failed');
            data.addAll(values);
          },
        ),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final loaded = controller.load();
      final saved = controller.save(
        const BtrSettings(mode: BtrMode.original, manualThreads: 64),
      );
      migration.complete();
      await loaded;
      await saved;
      expect(controller.current.mode, BtrMode.original);
      expect(controller.current.manualThreads, 64);
      expect(notifications, 2);
      fail = true;
      await expectLater(controller.save(const BtrSettings()), throwsStateError);
      expect(controller.current.mode, BtrMode.original);
      expect(notifications, 2);
      fail = false;
      await controller.save(controller.current.copyWith(showTransfers: true));
      expect(controller.current.showTransfers, isTrue);
      expect(data['defaultCDNService'], 3);
      expect(data['playerPreference'], 'unchanged');
      controller.dispose();
    },
  );

  testWidgets(
    'all controls persist, reload, preserve limits and notify live readers',
    (tester) async {
      final data = <String, Object?>{BtrSettingsStore.modeKey: 'switcher'};
      BtrSettingsController create() => BtrSettingsController(
        BtrSettingsStore(
          (key) => data[key],
          (values) async => data.addAll(values),
        ),
      );
      var controller = create();
      final sessionSettings = controller.current;
      var liveNotifications = 0;
      controller.addListener(() => liveNotifications++);
      Widget page() => MaterialApp(
        home: Scaffold(
          body: BtrSettingsPanel(
            controller: controller,
            diagnostics: const Text('read-only diagnostics'),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      Future<void> tap(String label, {double delta = 200}) async {
        final target = find.text(label);
        await tester.scrollUntilVisible(target, delta);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await tap('原始 PiliPlus');
      expect(controller.current.mode, BtrMode.original);
      await tap('BTR 整合加速');
      await tap('自動調整線程');
      for (final count in BtrSettings.threadChoices) {
        await tap('$count');
        expect(controller.current.manualThreads, count);
        expect(
          find.text('Android 生效上限：${count.clamp(1, 16)} 個上游請求'),
          findsOneWidget,
        );
      }
      await tap('COS');
      expect(
        controller.current.preferredCdn,
        BtrSourcePolicy.switcherHosts.last,
      );
      await tap('自動優選（預設）', delta: -200);
      expect(controller.current.preferredCdn, isNull);
      await tap('ALI-OV');
      await tap('顯示即時監控');
      await tap('提供詳細診斷資訊');
      await tap('顯示錯誤資訊');
      await tap('顯示傳輸事件');
      final saved = controller.current;
      expect(saved.monitorEnabled, isFalse);
      expect(saved.detailedDiagnostics, isTrue);
      expect(saved.showErrors, isFalse);
      expect(saved.showTransfers, isTrue);
      expect(liveNotifications, greaterThan(10));
      expect(sessionSettings.autoConcurrency, isTrue);
      expect(sessionSettings.manualThreads, 8);
      // Recreate the page and controller from the same persisted keys.
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      controller = create();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(controller.current.options, saved.options);
      expect(controller.current.mode, saved.mode);
      await tester.scrollUntilVisible(find.text('128'), 200);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '128'))
            .selected,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('external preference changes refresh an already open page', (
    tester,
  ) async {
    final data = <String, Object?>{};
    final controller = BtrSettingsController(
      BtrSettingsStore(
        (key) => data[key],
        (values) async => data.addAll(values),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BtrSettingsPanel(
            controller: controller,
            diagnostics: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.save(
      controller.current.copyWith(autoConcurrency: false, manualThreads: 32),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '32')).selected,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
