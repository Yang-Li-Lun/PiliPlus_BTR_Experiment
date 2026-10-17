import 'package:PiliPlus/pages/setting/widgets/btr_monitor.dart';
import 'package:PiliPlus/services/btr/diagnostics_export.dart';
import 'package:PiliPlus/services/btr/playback.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BtrExperimentPage extends StatefulWidget {
  const BtrExperimentPage({super.key});
  @override
  State<BtrExperimentPage> createState() => _BtrExperimentPageState();
}

class _BtrExperimentPageState extends State<BtrExperimentPage> {
  late BtrSettings settings = BtrPlayback.selectedSettings;
  bool _saving = false;
  bool _diagnosticBusy = false;

  Future<void> _diagnostics({required bool export}) async {
    if (_diagnosticBusy) return;
    setState(() => _diagnosticBusy = true);
    String message;
    try {
      if (export) {
        // Freeze and serialize before opening the system picker. Playback may
        // continue or end while the user chooses a destination.
        final result = await BtrDiagnosticsExport.save(
          BtrPlayback.diagnosticReport(),
        );
        message = switch (result) {
          BtrExportResult.saved => '完整診斷已儲存，UTF-8 檔案內容核對成功。',
          BtrExportResult.cancelled => '已取消匯出診斷。',
          BtrExportResult.noSpace => '儲存空間不足，診斷未完整儲存；請釋放空間後重試。',
          BtrExportResult.verificationFailed => '檔案內容核對失敗，未確認完整儲存；請重新匯出。',
          BtrExportResult.failed => '無法完成儲存或覆讀核對，請檢查位置、權限及空間後重試。',
        };
      } else {
        await Clipboard.setData(
          ClipboardData(text: BtrPlayback.compactDiagnosticReport()),
        );
        message = '已複製精簡診斷；完整快照請使用 JSON 匯出。';
      }
    } catch (_) {
      message = export ? '診斷匯出失敗，請重試。' : '複製診斷失敗，請重試或匯出 JSON。';
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void initState() {
    super.initState();
    _migrate();
  }

  Future<void> _migrate() async {
    try {
      await BtrPlayback.settingsStore.load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('舊模式遷移未能寫入；本次仍使用整合模式。')));
      }
    }
  }

  Future<void> _save(BtrSettings value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await BtrPlayback.saveSettings(value);
      if (mounted) setState(() => settings = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('設定儲存失敗，請重試。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BTR 功能設定')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '模式、線程與 CDN 設定於重新開啟影片或切換畫質時生效；監控顯示設定即時生效。適用於 Android DASH 隨選影片。',
        ),
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
        const Text('多線程設定'),
        SwitchListTile(
          title: const Text('自動調整線程'),
          subtitle: const Text('保留目前的 8→12→16 調整策略'),
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
                  selected: count == settings.manualThreads,
                  onSelected: _saving
                      ? null
                      : (_) => _save(settings.copyWith(manualThreads: count)),
                ),
            ],
          ),
        const Text(
          '手動值是並行上限。Android 目前保留全域 16 連線與每軌 4 MiB 有序視窗保護；高設定值仍受此限制。CDN 拒絕可再降低實際上限，不保證跑滿。',
        ),
        const Divider(),
        const Text('CDN 偏好'),
        for (final host in <String?>[null, ...BtrSourcePolicy.switcherHosts])
          ListTile(
            enabled: !_saving,
            title: Text(host ?? '自動優選（預設）'),
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
        const Text('監控設定'),
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
        BtrMonitor(session: () => BtrPlayback.current),
        TextButton.icon(
          onPressed: _diagnosticBusy ? null : () => _diagnostics(export: true),
          icon: const Icon(Icons.save_alt),
          label: const Text('匯出完整診斷（JSON）'),
        ),
        TextButton.icon(
          onPressed: _diagnosticBusy ? null : () => _diagnostics(export: false),
          icon: const Icon(Icons.copy),
          label: const Text('複製精簡診斷'),
        ),
        if (_diagnosticBusy) const LinearProgressIndicator(),
        const Text(
          '僅保留最近 8 次播放、每次最多 128 個事件及 32 次 Seek；顯示開關不影響錯誤計數。紀錄不含完整 URL、Cookie、Token 或帳號資訊。',
        ),
      ],
    ),
  );
}
