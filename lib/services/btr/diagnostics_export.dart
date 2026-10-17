import 'dart:io' show File;

import 'package:PiliPlus/services/btr/diagnostics.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum BtrExportResult { saved, cancelled, noSpace, verificationFailed, failed }

abstract final class BtrDiagnosticsExport {
  static const _channel = MethodChannel('piliplus/btr_diagnostics_export');

  static Future<BtrExportResult> save(String json) async {
    final bytes = BtrDiagnostics.utf8Bytes(json);
    final name = BtrDiagnostics.fileName(DateTime.now());
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await _channel.invokeMapMethod<String, Object?>(
          'save',
          {'name': name, 'bytes': bytes},
        );
        if (result?['status'] == 'cancelled') return BtrExportResult.cancelled;
        return result?['status'] == 'saved' && result?['bytes'] == bytes.length
            ? BtrExportResult.saved
            : BtrExportResult.verificationFailed;
      }
      // Reuse the existing picker for desktop; Android needs the original SAF
      // URI and read-back verification, which the locked picker cannot provide.
      final uri = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List(0),
        mimeType: 'application/json',
      );
      if (uri == null) return BtrExportResult.cancelled;
      final file = File(uri.toFilePath());
      await file.writeAsBytes(bytes, flush: true);
      return listEquals(bytes, await file.readAsBytes())
          ? BtrExportResult.saved
          : BtrExportResult.verificationFailed;
    } on PlatformException catch (e) {
      return switch (e.code) {
        'no-space' => BtrExportResult.noSpace,
        'verification-failed' => BtrExportResult.verificationFailed,
        _ => BtrExportResult.failed,
      };
    } catch (_) {
      // Never display raw provider errors, paths or identifiers.
      return BtrExportResult.failed;
    }
  }
}
