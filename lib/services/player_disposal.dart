import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';

/// The locked media-kit native player stops/unloads immediately in dispose(),
/// then schedules mpv_terminate_destroy on a five-second Timer (real.dart).
/// Keep the Dart engine alive until that timer has run before stopping Android's
/// AudioService. No dependency source or mpv handle is modified here.
Future<void> disposePlaybackPlayer(Player player) async {
  await player.dispose();
  if (Platform.isAndroid) {
    await Future<void>.delayed(const Duration(seconds: 5));
  }
}
