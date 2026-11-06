import 'dart:ffi' show Void;

import 'package:PiliPlus/services/btr/native_property_string.dart';
import 'package:media_kit/media_kit.dart';

/// Used by the new DEV probes; does not change media or player options.
abstract final class BtrNativeProperty {
  static String read(NativePlayer player, String property) {
    player.throwIfDisposed();
    return BtrNativePropertyString.read(
      property,
      query: (name) =>
          NativePlayer.mpv.mpv_get_property_string(player.ctx, name),
      releaseValue: (value) => NativePlayer.mpv.mpv_free(value.cast<Void>()),
    );
  }
}
