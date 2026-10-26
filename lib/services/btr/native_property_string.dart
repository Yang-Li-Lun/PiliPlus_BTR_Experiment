import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The query borrows the name; each returned string has its own release API.
abstract final class BtrNativePropertyString {
  static String read(
    String property, {
    required Pointer<Uint8> Function(Pointer<Uint8>) query,
    required void Function(Pointer<Uint8>) releaseValue,
    Allocator allocator = calloc,
  }) {
    final name = property.toNativeUtf8(allocator: allocator).cast<Uint8>();
    try {
      final value = query(name);
      if (value == nullptr) return '';
      try {
        return value.cast<Utf8>().toDartString();
      } finally {
        releaseValue(value);
      }
    } finally {
      allocator.free(name);
    }
  }
}
