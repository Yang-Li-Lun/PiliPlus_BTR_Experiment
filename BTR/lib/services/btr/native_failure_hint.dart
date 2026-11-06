/// Fixed hints reported by native code, not verified HTTP or decoder causes.
/// Never retain URLs, file names, addresses or arbitrary message suffixes.
abstract final class BtrNativeFailureHint {
  static Map<String, Object> read(String message) {
    var text = (message.length > 256 ? message.substring(0, 256) : message)
        .trimLeft();
    // mpv's av_log adapter prepends an AVClass item name, separate from the
    // mpv log namespace. Strip one known component, never an arbitrary label.
    text = text.replaceFirst(
      RegExp(
        r'^(?:https?|tcp|tls|mediacodec|hevc_mediacodec|h264_mediacodec|AVIOContext|AVHWDeviceContext):[ \t]+',
        caseSensitive: false,
      ),
      '',
    );
    const imageStages = {
      'newwithusage failed: ': 'android-image-create',
      'getwindow failed: ': 'android-image-window',
      'acquirelatestimage failed: ': 'android-image-acquire',
      'gethardwarebuffer failed: ': 'android-image-buffer',
    };
    final lower = text.toLowerCase();
    for (final entry in imageStages.entries) {
      if (!lower.startsWith(entry.key)) continue;
      final status = RegExp(
        r'^(-?[0-9]{1,6})(?:\s|$)',
      ).firstMatch(lower.substring(entry.key.length));
      return {
        'failureHint': entry.value,
        if (status != null) 'reportedMediaStatus': int.parse(status.group(1)!),
      };
    }
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
    const prefixes = {
      'url read error: immediate exit requested': 'http-read-interrupted',
      'error reading http response: immediate exit requested':
          'http-response-interrupted',
      'error reading http response: ': 'http-response-read',
      'url read error: ': 'http-url-read',
      'stream ends prematurely at ': 'http-short-stream',
      'unexpected offset: expected ': 'http-offset-mismatch',
      'invalid chunk size ': 'http-invalid-chunk',
      'malformed http version string.': 'http-invalid-version',
      'overlong headers': 'http-header-size',
      'failed to reconnect at ': 'http-reconnect-failed',
      'received and expected http method do not match.': 'http-method-mismatch',
      'received and autodetected http method did not match ':
          'http-method-mismatch',
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
