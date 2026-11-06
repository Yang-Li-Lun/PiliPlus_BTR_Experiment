import 'dart:collection';

/// Observations only: pending response.done or a successful socket flush cannot
/// establish that the native player still intends to consume this GET.
class BtrProxyTrace {
  BtrProxyTrace(
    this.id,
    this.track,
    this.method,
    this.generation,
    this.admittedAt,
  );

  final int id, generation, admittedAt;
  final String track, method;
  Map<String, Object?> Function()? demandState;
  bool Function()? holdsExecutionSlot;
  bool serverCloseRequested = false;
  bool serverDeadlineApplied = false;
  String responseDone = 'pending';
  int? responseDoneAt;
  int? releasedAt;

  Map<String, Object?> snapshot(int at) => {
    'proxyRequest': id,
    'track': track,
    'method': method,
    'generation': generation,
    'admittedAtMs': admittedAt,
    'ageMs': at - admittedAt,
    'phase': 'handler-wait',
    ...?demandState?.call(),
    'holdsExecutionSlot': holdsExecutionSlot?.call() ?? false,
    'responseDone': responseDone,
    'responseDoneAtMs': responseDoneAt,
    'serverCloseRequested': serverCloseRequested,
    'serverDeadlineApplied': serverDeadlineApplied,
    'releasedAtMs': releasedAt,
    'consumerValidity': 'unobservable',
  };
}

/// A separate bounded history preserves capacity decisions when hedge events
/// overflow the general event ring. No timers, IO, cancellation or scheduling.
class BtrProxyDiagnostics {
  BtrProxyDiagnostics({required this.now, required this.capacity});

  static const lifecycleLimit = 64;
  static const rejectionLimit = 4;
  final int Function() now;
  final Map<String, Object> Function() capacity;
  final _active = <int, BtrProxyTrace>{};
  final _lifecycle = Queue<Map<String, Object?>>();
  final _rejections = Queue<Map<String, Object?>>();
  int _droppedLifecycle = 0, _droppedRejections = 0;

  void admitted(BtrProxyTrace trace) {
    _active[trace.id] = trace;
    record('admitted', trace);
  }

  void record(String event, BtrProxyTrace trace) {
    final at = now();
    if (_lifecycle.length == lifecycleLimit) {
      _lifecycle.removeFirst();
      _droppedLifecycle++;
    }
    _lifecycle.add({
      'atMs': at,
      'event': event,
      ...trace.snapshot(at),
      ...capacity(),
    });
  }

  void responseFinished(BtrProxyTrace trace, {required bool error}) {
    trace
      ..responseDone = error ? 'error' : 'completed'
      ..responseDoneAt = now();
    record('response-done', trace);
  }

  void released(BtrProxyTrace trace) {
    trace.releasedAt = now();
    _active.remove(trace.id);
    record('released', trace);
    // Late response.done observations need only the final scalar state.
    final finalDemandState = trace.demandState?.call();
    trace
      ..holdsExecutionSlot = null
      ..demandState = finalDemandState == null ? null : () => finalDemandState;
  }

  Map<String, Object> rejected({
    required int request,
    required String cause,
    required int generation,
    required int waitMs,
    String? track,
  }) {
    final at = now();
    final decision = <String, Object>{
      'atMs': at,
      'proxyRequest': request,
      'capacityCause': cause,
      'generation': generation,
      'admissionWaitMs': waitMs,
      'track': ?track,
      ...capacity(),
      'trackedResponses': _active.length,
    };
    if (_rejections.length == rejectionLimit) {
      _rejections.removeFirst();
      _droppedRejections++;
    }
    _rejections.add({
      ...decision,
      'responses': [for (final trace in _active.values) trace.snapshot(at)],
    });
    return decision;
  }

  Map<String, Object?> snapshot() {
    final at = now();
    return {
      'schema': 1,
      'atMs': at,
      'consumerValidity': 'unobservable; socket progress is not player intent',
      'activeResponses': [
        for (final trace in _active.values) trace.snapshot(at),
      ],
      'rejections': _rejections.toList(),
      'lifecycle': _lifecycle.toList(),
      'droppedLifecycle': _droppedLifecycle,
      'droppedRejections': _droppedRejections,
      'lifecycleLimit': lifecycleLimit,
      'rejectionLimit': rejectionLimit,
    };
  }
}
