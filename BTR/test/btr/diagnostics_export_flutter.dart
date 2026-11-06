import 'dart:convert';

import 'package:PiliPlus/services/btr/diagnostics_export.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Channel contract tests only; these do not operate an Android document provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('piliplus/btr_diagnostics_export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('large UTF-8 JSON reaches native save unchanged and success requires verified byte count', () async {
    final json = jsonEncode({'資料': List.filled(30000, '影音🎬')});
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'save');
      final args = call.arguments as Map;
      expect(args['name'], matches(RegExp(r'^btr-[A-Za-z0-9._-]+\.json$')));
      final bytes = args['bytes'] as Uint8List;
      expect(bytes, utf8.encode(json));
      expect(jsonDecode(utf8.decode(bytes)), jsonDecode(json));
      return {'status': 'saved', 'bytes': bytes.length};
    });
    expect(await BtrDiagnosticsExport.save(json), BtrExportResult.saved);
  });

  test('native cancellation is reported explicitly', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'status': 'cancelled'},
    );
    expect(await BtrDiagnosticsExport.save('{}'), BtrExportResult.cancelled);
  });

  for (final entry in {
    'no-space': BtrExportResult.noSpace,
    'verification-failed': BtrExportResult.verificationFailed,
    'write-failed': BtrExportResult.failed,
    'picker-unavailable': BtrExportResult.failed,
    'activity-detached': BtrExportResult.failed,
  }.entries) {
    test(
      'native ${entry.key} preserves failure without raw provider text',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: entry.key,
            message: 'content://private-device/secret?token=secret',
          ),
        );
        expect(await BtrDiagnosticsExport.save('{}'), entry.value);
      },
    );
  }

  for (final reply in [
    null,
    {'status': 'saved', 'bytes': 1},
    {'status': 'unknown'},
  ]) {
    test('unconfirmed native reply $reply never reports success', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => reply);
      expect(
        await BtrDiagnosticsExport.save('{}'),
        BtrExportResult.verificationFailed,
      );
    });
  }
}
