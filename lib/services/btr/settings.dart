import 'package:PiliPlus/services/btr/policy.dart';

/// Immutable per-session transport settings. Display preferences may update live.
class BtrSettings {
  const BtrSettings({
    this.mode = BtrMode.combined,
    this.autoConcurrency = true,
    this.manualThreads = 8,
    this.preferredCdn,
    this.monitorEnabled = true,
    this.detailedDiagnostics = false,
    this.showErrors = true,
    this.showTransfers = false,
  });

  static const threadChoices = [4, 8, 16, 32, 64, 128];
  final BtrMode mode;
  final bool autoConcurrency;
  final int manualThreads;
  final String? preferredCdn;
  final bool monitorEnabled, detailedDiagnostics, showErrors, showTransfers;

  factory BtrSettings.decode(Object? mode, Object? options) {
    final map = options is Map ? options : const {};
    bool flag(String key, bool fallback) =>
        map[key] is bool ? map[key] as bool : fallback;
    return BtrSettings(
      mode: BtrMode.parse(mode), // Includes both retired experimental values.
      autoConcurrency: flag('autoConcurrency', true),
      manualThreads:
          map['manualThreads'] is int &&
              threadChoices.contains(map['manualThreads'])
          ? map['manualThreads'] as int
          : 8,
      preferredCdn: BtrSourcePolicy.switcherHosts.contains(map['preferredCdn'])
          ? map['preferredCdn'] as String
          : null,
      monitorEnabled: flag('monitorEnabled', true),
      detailedDiagnostics: flag('detailedDiagnostics', false),
      showErrors: flag('showErrors', true),
      showTransfers: flag('showTransfers', false),
    );
  }

  Map<String, Object?> get options => {
    'autoConcurrency': autoConcurrency,
    'manualThreads': manualThreads,
    'preferredCdn': preferredCdn,
    'monitorEnabled': monitorEnabled,
    'detailedDiagnostics': detailedDiagnostics,
    'showErrors': showErrors,
    'showTransfers': showTransfers,
  };

  BtrSettings copyWith({
    BtrMode? mode,
    bool? autoConcurrency,
    int? manualThreads,
    String? preferredCdn,
    bool clearCdn = false,
    bool? monitorEnabled,
    bool? detailedDiagnostics,
    bool? showErrors,
    bool? showTransfers,
  }) => BtrSettings.decode((mode ?? this.mode).name, {
    'autoConcurrency': autoConcurrency ?? this.autoConcurrency,
    'manualThreads': manualThreads ?? this.manualThreads,
    'preferredCdn': clearCdn ? null : preferredCdn ?? this.preferredCdn,
    'monitorEnabled': monitorEnabled ?? this.monitorEnabled,
    'detailedDiagnostics': detailedDiagnostics ?? this.detailedDiagnostics,
    'showErrors': showErrors ?? this.showErrors,
    'showTransfers': showTransfers ?? this.showTransfers,
  });
}

/// Uses the app's existing settings box; injectable for disk-backed Hive tests.
class BtrSettingsStore {
  const BtrSettingsStore(this.read, this.write);
  static const modeKey = 'btrExperimentModeV1';
  static const optionsKey = 'btrSettingsV2';
  final Object? Function(String) read;
  final Future<void> Function(Map<String, Object?>) write;

  BtrSettings get current =>
      BtrSettings.decode(read(modeKey), read(optionsKey));

  Future<BtrSettings> load() async {
    final settings = current;
    final oldMode = read(modeKey);
    if (oldMode == 'threaded' || oldMode == 'switcher') {
      await write({modeKey: settings.mode.name});
    }
    return settings;
  }

  Future<void> save(BtrSettings settings) => write({
    modeKey: settings.mode.name,
    optionsKey: settings.options,
  });
}
