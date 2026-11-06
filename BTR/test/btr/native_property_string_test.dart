import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:PiliPlus/services/btr/native_property_string.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

class _TrackedAllocator implements Allocator {
  final live = <Pointer>{};

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final value = calloc.allocate<T>(byteCount, alignment: alignment);
    live.add(value);
    return value;
  }

  @override
  void free(Pointer pointer) {
    expect(live.remove(pointer), true);
    calloc.free(pointer);
  }
}

void main() {
  test('native name and returned string use their matching release APIs', () {
    final names = _TrackedAllocator();
    var released = 0;
    final result = BtrNativePropertyString.read(
      'wid',
      allocator: names,
      query: (name) {
        expect(name.cast<Utf8>().toDartString(), 'wid');
        return '123'.toNativeUtf8(allocator: calloc).cast<Uint8>();
      },
      releaseValue: (value) {
        released++;
        calloc.free(value);
      },
    );
    expect(result, '123');
    expect(names.live, isEmpty);
    expect(released, 1);
  });

  test('null native property still frees its name without freeing null', () {
    final names = _TrackedAllocator();
    expect(
      BtrNativePropertyString.read(
        'unsupported',
        allocator: names,
        query: (_) => nullptr,
        releaseValue: (_) => fail('null has no owned result'),
      ),
      '',
    );
    expect(names.live, isEmpty);
  });

  test('query failure frees name; invalid UTF-8 also frees native result', () {
    final names = _TrackedAllocator();
    expect(
      () => BtrNativePropertyString.read(
        'wid',
        allocator: names,
        query: (_) => throw StateError('query'),
        releaseValue: (_) => fail('query produced no result'),
      ),
      throwsStateError,
    );
    expect(names.live, isEmpty);
    var released = 0;
    expect(
      () => BtrNativePropertyString.read(
        'wid',
        allocator: names,
        query: (_) {
          final bytes = calloc<Uint8>(2);
          bytes[0] = 255;
          return bytes;
        },
        releaseValue: (value) {
          released++;
          calloc.free(value);
        },
      ),
      throwsFormatException,
    );
    expect(names.live, isEmpty);
    expect(released, 1);
  });

  test('result release failure cannot leak the independent property name', () {
    final names = _TrackedAllocator();
    expect(
      () => BtrNativePropertyString.read(
        'wid',
        allocator: names,
        query: (_) => '123'.toNativeUtf8(allocator: calloc).cast<Uint8>(),
        releaseValue: (value) {
          calloc.free(value);
          throw StateError('release');
        },
      ),
      throwsStateError,
    );
    expect(names.live, isEmpty);
  });
}
