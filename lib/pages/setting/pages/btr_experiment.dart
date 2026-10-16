import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/services/btr/playback.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BtrExperimentPage extends StatefulWidget {
  const BtrExperimentPage({super.key});
  @override
  State<BtrExperimentPage> createState() => _BtrExperimentPageState();
}

class _BtrExperimentPageState extends State<BtrExperimentPage> {
  late BtrMode mode = BtrPlayback.selectedMode;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = BtrPlayback.current;
    final report = const JsonEncoder.withIndent('  ').convert({
      'selectedMode': mode.name,
      'current': active?.snapshot(),
      'recent': BtrPlayback.recent,
    });
    return Scaffold(
      appBar: AppBar(title: const Text('BTR Android 實驗')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('選擇後，重新開啟影片或切換畫質生效。適用於 Android DASH 隨選影片；直播、離線、投屏保留原行為。'),
          const SizedBox(height: 12),
          for (final value in BtrMode.values)
            ListTile(
              title: Text(value.label),
              leading: Icon(
                value == mode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              onTap: () async {
                await GStorage.setting.put(BtrPlayback.settingKey, value.name);
                if (mounted) setState(() => mode = value);
              },
            ),
          const Divider(),
          Text('本次播放：${active?.mode.label ?? '尚無播放紀錄'}'),
          const Text(
            '起播與 Seek：以播放器時間開始前進計時。緩衝次數排除起播和 Seek。傳輸交付量不等於已解碼畫面。原始模式不經代理，代理位元組數顯示 null。',
          ),
          const SizedBox(height: 8),
          const Text(
            '保留最近 8 次播放與有界事件紀錄；不記錄帳號、簽名網址、Cookie。尚未完成 Android 實機播放驗收。',
          ),
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            icon: const Icon(Icons.copy),
            label: const Text('複製比較紀錄'),
          ),
          SelectableText(report, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
