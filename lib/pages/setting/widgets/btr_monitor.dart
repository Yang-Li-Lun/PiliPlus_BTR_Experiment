import 'dart:async';

import 'package:PiliPlus/services/btr/monitor_data.dart';
import 'package:PiliPlus/services/btr/playback.dart';
import 'package:material_ui/material_ui.dart';

/// Refresh only this small subtree, only while it is mounted and enabled.
/// No diagnostic JSON serialization, extra mpv polling, or network requests.
class BtrMonitor extends StatelessWidget {
  const BtrMonitor({required this.session, this.compact = false, super.key});
  final BtrPlayback? Function() session;
  final bool compact;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: BtrPlayback.settingsRevision,
    builder: (context, revision, child) {
      if (!BtrPlayback.selectedSettings.monitorEnabled) {
        return compact
            ? const SizedBox.shrink()
            : const Text('即時監控已關閉；仍可複製有界診斷紀錄。');
      }
      return _Readout(session: session, compact: compact);
    },
  );
}

class _Readout extends StatefulWidget {
  const _Readout({required this.session, required this.compact});
  final BtrPlayback? Function() session;
  final bool compact;
  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
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
    final session = widget.session();
    if (session == null) {
      return widget.compact
          ? const SizedBox.shrink()
          : const Text('目前沒有適用的播放工作階段。');
    }
    final data = session.snapshot();
    final m = BtrMonitorData(data);
    final prefs = BtrPlayback.selectedSettings;
    final threads =
        '${BtrMonitorData.count(data['activeConnections'])} / ${BtrMonitorData.count(data['concurrencyLimit'])}';
    final network = BtrMonitorData.bytes(data['networkBps5s'], rate: true);
    final delivery = BtrMonitorData.bytes(
      data['loopbackDeliveredBps5s'],
      rate: true,
    );
    if (widget.compact) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0x99000000),
          borderRadius: BorderRadius.all(Radius.circular(5)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text(
            '${session.mode.label} · ${m.state} · 線程 $threads\n實收 $network · 交付 $delivery\n緩衝 ${BtrMonitorData.seconds(data['bufferAheadSeconds'])}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              height: 1.3,
            ),
          ),
        ),
      );
    }
    Widget line(String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text('$title：$value'),
    );
    String speed(String key, String track) =>
        BtrMonitorData.bytes(m.trackValue(key, track), rate: true);
    final seeks = data['seekTimelineMs'];
    final events = m.visibleEvents(
      errors: prefs.showErrors,
      transfers: prefs.showTransfers,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line('本次播放', '${session.mode.label} · ${m.state}'),
        line('上游並行請求／目前上限', threads),
        line(
          '設定上限／資源上限',
          '${BtrMonitorData.count(data['configuredConcurrencyLimit'])} / ${BtrMonitorData.count(data['resourceConcurrencyLimit'])}',
        ),
        line(
          '影片／音訊線程／排隊',
          '${BtrMonitorData.count(data['videoConnections'])} / ${BtrMonitorData.count(data['audioConnections'])} / ${BtrMonitorData.count(data['queuedConnections'])}',
        ),
        line(
          'HTTP 實收',
          '$network（影片 ${speed('networkBpsByTrack5s', 'video')}；音訊 ${speed('networkBpsByTrack5s', 'audio')}）',
        ),
        line(
          '有效交付',
          '$delivery（影片 ${speed('loopbackDeliveredBpsByTrack5s', 'video')}；音訊 ${speed('loopbackDeliveredBpsByTrack5s', 'audio')}）',
        ),
        line('影片 CDN', m.cdn('video')),
        line('音訊 CDN', m.cdn('audio')),
        if (prefs.showErrors)
          for (final kind in ['video', 'audio'])
            if (m.track(kind)?['lastFailure'] case final failure?)
              line('${kind == 'video' ? '影片' : '音訊'}最近傳輸／選源失敗', '$failure'),
        line(
          '緩衝／卡頓',
          '${BtrMonitorData.seconds(data['bufferAheadSeconds'])} / ${BtrMonitorData.count(data['bufferingEvents'])} 次',
        ),
        line(
          '起播／最近 Seek',
          '${BtrMonitorData.milliseconds(data['startupTimelineMs'])} / ${data['seekPending'] == true ? '恢復中' : BtrMonitorData.milliseconds(seeks is List && seeks.isNotEmpty ? seeks.last : null)}',
        ),
        line(
          '選源失敗／下載失敗／終止',
          '${BtrMonitorData.count(data['discoveryFailures'])} / ${BtrMonitorData.count(data['requestFailures'])} / ${BtrMonitorData.count(data['terminalFailures'])}',
        ),
        line(
          '重試／Hedge',
          '${BtrMonitorData.count(data['retries'])} / ${BtrMonitorData.count(data['hedges'])}',
        ),
        line(
          '需求取消／上游取消／續傳',
          '${BtrMonitorData.count(data['cancellations'])} / ${BtrMonitorData.count(data['upstreamCancellations'])} / ${BtrMonitorData.count(data['resumes'])}',
        ),
        line(
          '累計實收／有效交付',
          '${BtrMonitorData.bytes(data['networkBytesIncludingProbesAndHedges'])} / ${BtrMonitorData.bytes(data['loopbackDeliveredBytes'])}',
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '速率為最近 5 秒平均，僅涵蓋實際經 BTR 的軌道。實收為已讀 HTTP body，含選源、重試及 Hedge；不含協定開銷。有效交付是送入本機播放器 socket 的資料，並非解碼量。原始模式與未取得資料顯示「未取得」。',
          ),
        ),
        if (prefs.detailedDiagnostics)
          ExpansionTile(
            title: const Text('詳細診斷'),
            children: [
              line(
                '原生主 demuxer 速率',
                BtrMonitorData.bytes(
                  data['nativeMainDemuxInputBps'],
                  rate: true,
                ),
              ),
              line(
                '原生 packet queue 大小',
                BtrMonitorData.bytes(data['nativeMainDemuxQueueBytes']),
              ),
              line('續傳重用前綴', BtrMonitorData.bytes(data['resumedPrefixBytes'])),
              line('事件捨棄數', BtrMonitorData.count(data['eventsDropped'])),
              for (final kind in ['video', 'audio'])
                if (m.track(kind) case final track?) ...[
                  line('$kind 身分驗證', '${track['identity']}'),
                  line('$kind 選源健康', '${track['health']}'),
                ],
            ],
          ),
        if (prefs.showErrors || prefs.showTransfers)
          ExpansionTile(
            title: const Text('錯誤與傳輸事件'),
            children: [
              if (events.isEmpty) const Text('目前沒有符合顯示設定的事件。'),
              for (final event in events.reversed.take(24))
                ListTile(
                  dense: true,
                  title: Text('${event['ms']} ms · ${event['event']}'),
                  subtitle: Text(
                    '${Map.of(event)
                      ..remove('ms')
                      ..remove('event')}',
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
