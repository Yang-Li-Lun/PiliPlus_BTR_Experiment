import 'package:PiliPlus/services/btr/settings_service.dart';
import 'package:PiliPlus/services/btr/ui/diagnostics_panel.dart';
import 'package:PiliPlus/services/btr/ui/settings_panel.dart';
import 'package:material_ui/material_ui.dart';

/// Shared route from upstream playback settings and the player menu.
class BtrExperimentPage extends StatelessWidget {
  const BtrExperimentPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BTR 專屬設定')),
    body: BtrSettingsPanel(
      controller: BtrPreferences.controller,
      diagnostics: const BtrDiagnosticsPanel(),
    ),
  );
}
