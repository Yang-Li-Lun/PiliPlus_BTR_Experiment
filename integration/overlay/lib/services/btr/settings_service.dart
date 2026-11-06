import 'package:PiliPlus/services/btr/settings.dart';
import 'package:PiliPlus/services/btr/settings_controller.dart';
import 'package:PiliPlus/utils/storage.dart';

/// The only app storage binding for BTR. Upstream CDN/player keys are not used.
abstract final class BtrPreferences {
  static final controller = BtrSettingsController(
    BtrSettingsStore(
      (key) => GStorage.setting.get(key),
      (values) => GStorage.setting.putAll(values),
    ),
  );
  static BtrSettings get current => controller.current;
}
