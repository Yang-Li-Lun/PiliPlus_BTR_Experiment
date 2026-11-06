/// Presentation helpers keep unknown/native-only observations distinct from 0.
class BtrMonitorData {
  const BtrMonitorData(this.data);
  final Map<String, Object?> data;

  static String count(Object? value) => value is num ? '$value' : '未取得';
  static String bytes(Object? value, {bool rate = false}) {
    if (value is! num) return '未取得';
    final suffix = rate ? '/s' : '';
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(2)} MiB$suffix';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KiB$suffix';
    return '${value.toStringAsFixed(0)} B$suffix';
  }

  static String seconds(Object? value) =>
      value is num ? '${value.toStringAsFixed(1)} 秒' : '未取得';
  static String milliseconds(Object? value) =>
      value is num ? '${value.toStringAsFixed(0)} ms' : '尚未完成';

  String get state => switch (data['playbackState']) {
    'playing' => '播放中',
    'paused' => '暫停',
    'buffering' => '緩衝中',
    'seeking' => 'Seek 恢復中',
    'completed' => '播放結束',
    'closed' => '已關閉',
    _ => '未取得',
  };

  Object? trackValue(String key, String track) {
    final map = data[key];
    return map is Map ? map[track] : null;
  }

  Map? track(String kind) {
    final tracks = data['tracks'];
    if (tracks is List) {
      for (final item in tracks) {
        if (item is Map && item['kind'] == kind) return item;
      }
    }
    return null;
  }

  String cdn(String kind) {
    final t = track(kind);
    if (t == null) return '未經 BTR／未取得';
    final result = switch (t['selection']) {
      'selected' => '已驗證選用',
      'selecting' => '選源中',
      'failed' => '選源失敗',
      _ => '等待請求',
    };
    return '${t['host'] ?? '尚未選定'} · $result${t['terminal'] == true ? ' · 已停止' : ''}';
  }

  List<Map> visibleEvents({required bool errors, required bool transfers}) {
    const errorKinds = {
      'source-failed',
      'transfer-ended',
      'request-failed',
      'player-error',
      'native-fallback',
    };
    final events = data['events'];
    if (events is! List) return const [];
    return events
        .whereType<Map>()
        .where(
          (e) => errorKinds.contains(e['event']) ? errors : transfers,
        )
        .toList();
  }
}
