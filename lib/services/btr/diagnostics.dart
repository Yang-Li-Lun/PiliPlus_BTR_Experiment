import 'dart:convert';
import 'dart:typed_data';

/// Only consumes the existing privacy-safe snapshots. Called on user action,
/// never by the transport, chunk callbacks or monitoring timer.
abstract final class BtrDiagnostics {
  static const buildId = String.fromEnvironment(
    'BTR_BUILD_ID',
    defaultValue: 'unidentified',
  );
  static const compactBudgetBytes = 12 * 1024;
  static const units =
      'bytes; rates are 5-second averages of observed HTTP body bytes and '
      'loopback socket delivery, not decoded media or full wire traffic';

  static Map<String, Object?> report({
    required Map<String, Object?> selectedSettings,
    required Map<String, Object?>? current,
    required List<Map<String, Object?>> recent,
  }) => {
    'schema': 2,
    'buildId': buildId,
    'selectedSettings': selectedSettings,
    'current': current,
    'recent': recent,
    'units': units,
  };

  static String full(Map<String, Object?> report) =>
      const JsonEncoder.withIndent('  ').convert(report);

  static Uint8List utf8Bytes(String json) =>
      Uint8List.fromList(utf8.encode(json));

  static String fileName(DateTime time) {
    final safeBuild = buildId.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    final stamp = time.toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    return 'btr-$safeBuild-$stamp.json';
  }

  static const _importantEvents = {
    'source-failed',
    'transfer-ended',
    'request-failed',
    'player-error',
    'native-error-origin',
    'seek',
    'seek-command',
    'player-open',
    'player-open-ended',
    'player-reopen-skipped',
    'player-recovery-exhausted',
    'player-read-stall',
    'native-read-failure',
    'seek-eof-correction',
    'player-completed',
    'player-completed-suppressed',
    'native-audio-state',
    'proxy-rejected',
    'prefetch-reclaimed',
    'native-fallback',
    'native-video-fallback',
    'native-audio-fallback',
  };
  static const _historicalProbes = {
    'previousNativeAvProbe',
    'nativeAvBeforeCompleted',
    'nativeAvAtFirstError',
    'nativeAvAtLastError',
  };

  static Map<String, Object?> _session(Map source, int eventLimit) {
    final events = (source['events'] as List?) ?? const [];
    final counts = <String, int>{};
    final important = <Object?>[];
    for (final event in events.whereType<Map>()) {
      final kind = event['event'];
      if (kind is! String) continue;
      counts.update(kind, (n) => n + 1, ifAbsent: () => 1);
      if (_importantEvents.contains(kind) ||
          (kind == 'demand-ended' &&
              event['outcome'] != 'complete' &&
              event['outcome'] != 'cancelled')) {
        important.add(event);
      }
    }
    return {
      for (final entry in source.entries)
        if (entry.key != 'events' && !_historicalProbes.contains(entry.key))
          entry.key as String: entry.value,
      'eventSummary': {
        'scope':
            'retained event window only; lifetime hedges/resumes/retries '
            'and failures are the session counters above',
        'retained': events.length,
        'counts': counts,
        'omitted': events.length - important.length.clamp(0, eventLimit),
      },
      'events': important
          .skip((important.length - eventLimit).clamp(0, important.length))
          .toList(),
    };
  }

  /// Soft byte budget: remove optional events, then history. If future critical
  /// snapshots alone exceed it, explicitly report overflow and retain them.
  /// No string slicing, null-to-zero conversion or synthetic throughput values.
  static String compact(Map<String, Object?> source) {
    final history = (source['recent'] as List?) ?? const [];
    final current = source['current'] as Map?;
    var eventLimit = 6;
    var historyLimit = history.isEmpty ? 0 : 1;
    Map<String, Object?> make({bool exceeded = false}) => {
      'schema': source['schema'],
      'buildId': source['buildId'],
      'format': 'compact',
      'selectedSettings': source['selectedSettings'],
      'current': current == null ? null : _session(current, eventLimit),
      'recent': history.reversed
          .take(historyLimit)
          .whereType<Map>()
          .map((s) => _session(s, eventLimit))
          .toList(),
      'units': source['units'],
      'omissions': {
        'recentSessions': history.length - historyLimit,
        'historicalNativeAvProbes': true,
        'events':
            'hedge/resume/retry and normal demand events summarized; '
            'at most $eventLimit recent important events per included session',
        'fullExport': '請使用「匯出完整診斷（JSON）」取得所有已保留快照。',
      },
      'sizePolicy': {
        'targetUtf8Bytes': compactBudgetBytes,
        'exceeded': exceeded,
        'strategy':
            'drop optional events, then history; preserve current '
            '(or latest ended) metrics, tracks, demands and counters even on overflow',
      },
    };
    var json = jsonEncode(make());
    if (utf8.encode(json).length <= compactBudgetBytes) return json;
    eventLimit = 0;
    json = jsonEncode(make());
    if (utf8.encode(json).length <= compactBudgetBytes) return json;
    // The latest ended session is the primary evidence when nothing is active.
    if (current != null) historyLimit = 0;
    json = jsonEncode(make());
    if (utf8.encode(json).length <= compactBudgetBytes) return json;
    return jsonEncode(make(exceeded: true));
  }
}
