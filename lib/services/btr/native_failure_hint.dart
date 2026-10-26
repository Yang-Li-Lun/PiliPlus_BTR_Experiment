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
      'error opening/initializing the vo window.': 'video-output-window',
      'failed to create anativewindow': 'native-window-create',
      'could not choose eglconfig for ': 'egl-config',
      'could not create egl context for ': 'egl-context',
      'could not create egl surface!': 'egl-surface',
      'egl failed to initialize.': 'egl-init',
      'failed loading egl functions - double check egldisplay?':
          'egl-functions',
      'initializing texture for hardware decoding failed.':
          'hwdec-texture-init',
      'mapping hardware decoded surface failed.': 'hwdec-surface-map',
      'failed mapping hwdec frame? open a bug!': 'hwdec-frame-map',
      'could not copy back hardware decoded frame.': 'hwdec-copy-back',
      'could not copy hardware frame to cpu memory.': 'hwdec-copy-cpu',
      'ran out of free frames!': 'frame-pool-exhausted',
      'failed to flush codec': 'codec-flush',
      'failed to dequeue input buffer (status=': 'codec-dequeue-input',
      'failed to dequeue output buffer (status=': 'codec-dequeue-output',
      'failed to queue input buffer (status = ': 'codec-queue-input',
      'failed to release output buffer': 'codec-release-output',
      'release output buffer failed, ': 'codec-release-output',
      'releaseoutputbufferattime failed, ': 'codec-release-timed-output',
      'failed to retrieve first frame': 'first-frame-retrieve',
      'failed presenting frame!': 'frame-present',
      'failed rendering frame!': 'frame-render',
      'failed uploading frame!': 'frame-upload',
      'failed uninitializing buffer, leaking resources!': 'buffer-uninit',
      'failed uninitializing texture, leaking resources!': 'texture-uninit',
      'generic error in an external library': 'external-library',
      'end of file': 'end-of-file',
    };
    for (final entry in prefixes.entries) {
      if (lower.startsWith(entry.key)) return {'failureHint': entry.value};
    }
    return const {'failureHint': 'unclassified'};
  }
}
