/// Fixed hints reported by native code, not verified HTTP or decoder causes.
/// Never retain URLs, file names, addresses or arbitrary message suffixes.
abstract final class BtrNativeFailureHint {
  static Map<String, Object> read(String message) {
    final text = (message.length > 256 ? message.substring(0, 256) : message)
        .trimLeft();
    final http = RegExp(
      r'^(?:HTTP error|Server returned) ([1-5][0-9]{2})(?:\s|$)',
      caseSensitive: false,
    ).firstMatch(text);
    if (http != null) {
      return {
        'failureHint': 'reported-http-status',
        'reportedHttpStatus': int.parse(http.group(1)!),
      };
    }
    final lower = text.toLowerCase();
    const prefixes = {
      'failed to open': 'open-failed',
      'cannot open ': 'open-failed',
      'error opening input': 'open-failed',
      'failed to read': 'read-failed',
      'error reading': 'read-failed',
      'connection timed out': 'connection-timeout',
      'connection refused': 'connection-refused',
      'connection reset by peer': 'connection-reset',
      'network is unreachable': 'network-unreachable',
      'tls handshake failed': 'tls-handshake',
      'invalid data found when processing input': 'invalid-data',
      'could not find codec parameters': 'codec-parameters',
      'could not open codec': 'codec-open',
      'failed to initialize a video decoder': 'decoder-init',
      'native_window_api_connect returned an error': 'surface-connect',
      'failed to create surface': 'surface-create',
      'failed to initialize video output': 'video-output-init',
      'hardware decoding failed': 'hardware-decode-failed',
      'generic error in an external library': 'external-library',
      'end of file': 'end-of-file',
    };
    for (final entry in prefixes.entries) {
      if (lower.startsWith(entry.key)) return {'failureHint': entry.value};
    }
    return const {'failureHint': 'unclassified'};
  }
}
