import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:PiliPlus/services/btr/settings_controller.dart';
import 'package:material_ui/material_ui.dart';

/// BTR controls only. Diagnostics is read-only and provided by the app binding.
class BtrSettingsPanel extends StatefulWidget {
  const BtrSettingsPanel({
    required this.controller,
    required this.diagnostics,
    super.key,
  });
  final BtrSettingsController controller;
  final Widget diagnostics;
  @override
  State<BtrSettingsPanel> createState() => _BtrSettingsPanelState();
}

class _BtrSettingsPanelState extends State<BtrSettingsPanel> {
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.controller.load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('設定遷移未能儲存；目前使用已讀取的設定。')),
        );
      }
    }
  }

  Future<void> _save(BtrSettings value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.save(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('設定儲存失敗，請重試。')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, child) {
      final settings = widget.controller.current;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _heading('播放模式'),
          const Text('模式、線程與 CDN 於下次播放或切換畫質生效；監控顯示立即生效。'),
          for (final mode in BtrMode.values)
            ListTile(
              enabled: !_saving,
              title: Text(mode.label),
              subtitle: Text(
                mode == BtrMode.original
                    ? '原版播放器與傳輸，完全繞過 BTR'
                    : '多線程下載與智慧 CDN 切換（預設）',
              ),
              leading: Icon(
                mode == settings.mode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              onTap: () => _save(settings.copyWith(mode: mode)),
            ),
          const Divider(),
          _heading('多線程傳輸'),
          SwitchListTile(
            title: const Text('自動調整線程'),
            subtitle: const Text('8→12→16，依播放需求與來源狀態調整'),
            value: settings.autoConcurrency,
            onChanged: _saving
                ? null
                : (value) => _save(settings.copyWith(autoConcurrency: value)),
          ),
          if (!settings.autoConcurrency)
            Wrap(
              spacing: 8,
              children: [
                for (final count in BtrSettings.threadChoices)
                  ChoiceChip(
                    label: Text('$count'),
                    tooltip:
                        'Android 生效上限 ${count.clamp(1, BtrScheduler.resourceLimit)}',
                    selected: count == settings.manualThreads,
                    onSelected: _saving
                        ? null
                        : (_) => _save(settings.copyWith(manualThreads: count)),
                  ),
              ],
            ),
          ListTile(
            title: Text(
              '已保存上限：${settings.autoConcurrency ? 16 : settings.manualThreads}',
            ),
            subtitle: Text(
              'Android 生效上限：${settings.autoConcurrency ? BtrScheduler.resourceLimit : settings.manualThreads.clamp(1, BtrScheduler.resourceLimit)} 個上游請求',
            ),
          ),
          const Text(
            '手動值是並行上限。Android 目前保留全域 16 連線與每軌 4 MiB 有序視窗保護；高設定值仍受此限制。CDN 拒絕可再降低實際上限，不保證跑滿。',
          ),
          const Divider(),
          _heading('CDN 來源'),
          for (final host in <String?>[null, ...BtrSourcePolicy.switcherHosts])
            ListTile(
              enabled: !_saving,
              title: Text(switch (host) {
                null => '自動優選（預設）',
                BtrSourcePolicy.preferred => 'ALI-OV',
                'upos-sz-mirrorali.bilivideo.com' => 'ALI',
                _ => 'COS',
              }),
              leading: Icon(
                settings.preferredCdn == host
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              onTap: () => _save(
                settings.copyWith(preferredCdn: host, clearCdn: host == null),
              ),
            ),
          const Text(
            '偏好只調整合格來源優先次序，失敗時仍驗證備援。保留 MCDN／P2P 過濾與媒體身分驗證，不跨 CDN 拼接分段。實際採用來源見下方監控。',
          ),
          const Divider(),
          _heading('監控顯示'),
          SwitchListTile(
            title: const Text('顯示即時監控'),
            value: settings.monitorEnabled,
            onChanged: _saving
                ? null
                : (v) => _save(settings.copyWith(monitorEnabled: v)),
          ),
          SwitchListTile(
            title: const Text('提供詳細診斷資訊'),
            subtitle: const Text('詳細內容預設收合'),
            value: settings.detailedDiagnostics,
            onChanged: _saving
                ? null
                : (v) => _save(settings.copyWith(detailedDiagnostics: v)),
          ),
          SwitchListTile(
            title: const Text('顯示錯誤資訊'),
            value: settings.showErrors,
            onChanged: _saving
                ? null
                : (v) => _save(settings.copyWith(showErrors: v)),
          ),
          SwitchListTile(
            title: const Text('顯示傳輸事件'),
            value: settings.showTransfers,
            onChanged: _saving
                ? null
                : (v) => _save(settings.copyWith(showTransfers: v)),
          ),
          const Divider(),

          _heading('即時狀態與診斷'),
          widget.diagnostics,
        ],
      );
    },
  );
}
