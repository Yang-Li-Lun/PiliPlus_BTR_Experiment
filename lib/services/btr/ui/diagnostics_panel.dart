import 'package:PiliPlus/pages/setting/widgets/btr_monitor.dart';
import 'package:PiliPlus/services/btr/diagnostics_export.dart';
import 'package:PiliPlus/services/btr/playback.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BtrDiagnosticsPanel extends StatefulWidget {
  const BtrDiagnosticsPanel({super.key});
  @override
  State<BtrDiagnosticsPanel> createState() => _BtrDiagnosticsPanelState();
}

class _BtrDiagnosticsPanelState extends State<BtrDiagnosticsPanel> {
  bool _diagnosticBusy = false;

  Future<void> _diagnostics({
    required bool export,
    bool deviceTest = false,
  }) async {
    if (_diagnosticBusy) return;
    setState(() => _diagnosticBusy = true);
    String message;
    try {
      if (export) {
        // Freeze and serialize before opening the system picker. Playback may
        // continue or end while the user chooses a destination.
        final report = BtrPlayback.diagnosticReport();
        final result = deviceTest
            ? await BtrDiagnosticsExport.saveDeviceTest(report)
            : await BtrDiagnosticsExport.save(report);
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
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
      if (BtrDiagnosticsExport.deviceTest)
        TextButton.icon(
          onPressed: _diagnosticBusy
              ? null
              : () => _diagnostics(export: true, deviceTest: true),
          icon: const Icon(Icons.save_alt),
          label: const Text('保存實機量測 JSON（App 專屬目錄）'),
        ),
      if (_diagnosticBusy) const LinearProgressIndicator(),
      const Text(
        '僅保留最近 8 次播放、每次最多 128 個事件及 32 次 Seek；顯示開關不影響錯誤計數。紀錄不含完整 URL、Cookie、Token 或帳號資訊。',
      ),
    ],
  );
}
