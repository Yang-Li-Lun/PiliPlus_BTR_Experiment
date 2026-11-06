import 'package:PiliPlus/services/btr/settings.dart';
import 'package:flutter/foundation.dart';

/// One live view of the persisted BTR preferences. Sessions retain their own
/// immutable snapshot; UI listeners only change display preferences live.
class BtrSettingsController extends ChangeNotifier {
  BtrSettingsController(this.store);

  final BtrSettingsStore store;
  Future<void> _pending = Future<void>.value();
  BtrSettings get current => store.current;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) async {
      await action();
      notifyListeners();
    });
    // A failed write is reported to its caller, without poisoning later saves.
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> load() => _serialize(() async {
    await store.load();
  });
  Future<void> save(BtrSettings settings) =>
      _serialize(() => store.save(settings));
}
