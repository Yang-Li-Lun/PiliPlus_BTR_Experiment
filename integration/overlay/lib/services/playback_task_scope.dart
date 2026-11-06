import 'dart:async';

/// Playback owners register before their first asynchronous initialization.
/// Only AudioHandler.onTaskRemoved closes all owners; UI lifecycle changes do
/// not affect these scopes. A normal owner disposal closes just its own scope.
class PlaybackTaskScope {
  PlaybackTaskScope({this.onClose}) {
    _active.add(this);
  }

  static final _active = <PlaybackTaskScope>{};
  final FutureOr<void> Function()? onClose;
  final _releases = Map<Object, Future<void> Function()>.identity();
  final _pending = <Future<void>>{};
  final _releaseErrors = <(Object, StackTrace)>[];
  bool _closed = false;
  bool get closed => _closed;
  Future<void>? _closing;

  /// A resource created after close is disposed before returning null. close()
  /// also waits for this disposal, including creation of native player surfaces.
  Future<T?> acquire<T extends Object>(
    Future<T> Function() initialize,
    Future<void> Function(T) release,
  ) {
    if (_closed) return Future.value();
    final result = Future.sync(() async {
      final value = await initialize();
      if (_closed) {
        await _release(() => release(value));
        return null;
      }
      _releases[value] = () => release(value);
      return value;
    });
    // Observe errors here without replacing the result delivered to the owner.
    late final Future<void> pending;
    pending = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(pending));
    _pending.add(pending);
    return result;
  }

  Future<void> release(Object value) async {
    final release = _releases.remove(value);
    if (release == null) return;
    final pending = _release(release);
    _pending.add(pending);
    try {
      await pending;
    } finally {
      _pending.remove(pending);
    }
  }

  Future<void> _release(Future<void> Function() release) async {
    try {
      await release();
    } catch (error, stack) {
      _releaseErrors.add((error, stack));
    }
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    final completion = Completer<void>();
    _closing = completion.future;
    completion.complete(_finishClose());
    return completion.future;
  }

  Future<void> _finishClose() async {
    final releases = _releases.values.toList();
    _releases.clear();
    try {
      // Start every cleanup even if one owner or resource throws.
      await Future.wait([
        Future.sync(onClose ?? () {}),
        ...releases.map(Future<void>.sync),
        ..._pending,
      ]);
      if (_releaseErrors case [(final error, final stack), ...]) {
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      _releases.clear();
      _active.remove(this);
    }
  }

  static Future<void> closeAll() => Future.wait(
    _active.toList().map((scope) => scope.close()),
  );
}
