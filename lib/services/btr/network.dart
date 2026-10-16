import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';

class BtrHttpLease {
  BtrHttpLease(this.response, this.client, this.release, this.unlink);
  final HttpClientResponse response;
  final HttpClient client;
  final void Function(bool) release;
  final void Function() unlink;
  bool _closed = false;
  Future<void> close({bool reusable = false}) async {
    if (_closed) return;
    _closed = true;
    unlink();
    release(reusable);
  }
}

/// Clients are reused after fully read successes. Cancellation destroys just the
/// losing connection, and cleanup finishes before its scheduler permit returns.
class BtrNetwork {
  BtrNetwork(
    this.scheduler,
    this.metrics, {
    this.headers = const {},
    this.headerTimeout = const Duration(milliseconds: 5500),
    this.stallTimeout = const Duration(seconds: 4),
    this.attemptTimeout = const Duration(seconds: 15),
  });
  final BtrScheduler scheduler;
  final BtrMetrics metrics;
  final Map<String, String> headers;
  final Duration headerTimeout, stallTimeout, attemptTimeout;
  final _idle = <HttpClient>[];
  final _all = <HttpClient>{};
  bool _closed = false;

  Future<BtrHttpLease> open(
    Uri uri,
    BtrRange range,
    BtrCancel token, {
    required bool audio,
    required int Function() priority,
    String? etag,
    void Function()? onStarted,
  }) async {
    final permit = await scheduler.acquire(
      token,
      audio: audio,
      priority: priority,
    );
    if (_closed || token.cancelled) {
      permit();
      throw const BtrCancelled();
    }
    onStarted?.call();
    final client = _idle.isEmpty ? HttpClient() : _idle.removeLast();
    _all.add(client);
    client
      ..autoUncompress = false
      ..connectionTimeout = headerTimeout
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 1;
    HttpClientRequest? request;
    final unlink = token.listen(() {
      request?.abort(const BtrCancelled());
      client.close(force: true);
    });
    var released = false;
    void release(bool reusable) {
      if (released) return;
      released = true;
      if (reusable && !token.cancelled && !_closed && _idle.length < 16) {
        _idle.add(client);
      } else {
        client.close(force: true);
        _all.remove(client);
      }
      permit();
    }

    try {
      final pending = client.getUrl(uri).then((value) {
        request = value;
        if (token.cancelled || released) value.abort(const BtrCancelled());
        return value;
      });
      request = await token.bind(pending.timeout(headerTimeout));
      request!.followRedirects = false;
      // Never forward player cookies, Authorization or arbitrary request headers.
      for (final key in ['User-Agent', 'Referer']) {
        if (headers[key] case final value?) request!.headers.set(key, value);
      }
      request!.headers.set(HttpHeaders.rangeHeader, range.header);
      request!.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (etag != null) request!.headers.set(HttpHeaders.ifRangeHeader, etag);
      final response = await token.bind(
        request!.close().timeout(headerTimeout),
      );
      return BtrHttpLease(response, client, release, unlink);
    } catch (_) {
      unlink();
      release(false);
      rethrow;
    }
  }

  /// Validate headers BEFORE retaining or delivering any byte.
  static int validate(
    HttpClientResponse r,
    BtrRange requested, {
    BtrIdentity? identity,
    Uri? actual,
    bool probe = false,
  }) {
    if (r.statusCode != 206) throw BtrFailure('range-status', r.statusCode);
    final encoding = r.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw const BtrFailure('encoded-range');
    }
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
      r.headers.value(HttpHeaders.contentRangeHeader) ?? '',
    );
    if (m == null) throw const BtrFailure('content-range');
    final start = int.tryParse(m[1]!);
    final end = int.tryParse(m[2]!);
    final total = int.tryParse(m[3]!);
    if (total == null ||
        total <= 0 ||
        total > 9007199254740991 ||
        start != requested.start ||
        end == null ||
        end >= total ||
        end != (probe ? math.min(requested.end, total - 1) : requested.end) ||
        (r.contentLength >= 0 && r.contentLength != end - start! + 1)) {
      throw const BtrFailure('content-range');
    }
    if (identity != null &&
        (identity.total != total ||
            actual != identity.uri ||
            (identity.etag != null &&
                r.headers.value(HttpHeaders.etagHeader) != identity.etag))) {
      throw const BtrFailure('identity-changed');
    }
    return total;
  }

  Future<BtrSample> sample(
    Uri uri,
    BtrCancel token, {
    required bool audio,
  }) async {
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    final timer = Timer(attemptTimeout, scope.cancel);
    BtrHttpLease? lease;
    StreamIterator<List<int>>? reader;
    var complete = false;
    final watch = Stopwatch()..start();
    try {
      lease = await open(
        uri,
        const BtrRange(0, 65535),
        scope,
        audio: audio,
        priority: () => 300,
      );
      final total = validate(
        lease.response,
        const BtrRange(0, 65535),
        probe: true,
      );
      final size = math.min(total, 65536);
      final data = Uint8List(size);
      reader = StreamIterator(lease.response);
      var offset = 0;
      while (await scope.bind(reader.moveNext().timeout(stallTimeout))) {
        final bytes = reader.current;
        metrics.networkBytes += bytes.length;
        if (offset + bytes.length > size) {
          throw const BtrFailure('body-overrun');
        }
        data.setRange(offset, offset + bytes.length, bytes);
        offset += bytes.length;
      }
      if (offset != size) throw const BtrFailure('body-short');
      scope.check();
      complete = true;
      return BtrSample(
        BtrIdentity(
          uri,
          total,
          BtrIdentity.strongTag(
            lease.response.headers.value(HttpHeaders.etagHeader),
          ),
        ),
        data,
        math.max(1, watch.elapsedMilliseconds),
      );
    } on BtrCancelled {
      token.check();
      throw const BtrFailure('discovery-deadline');
    } finally {
      timer.cancel();
      unlink();
      await reader?.cancel();
      await lease?.close(reusable: complete);
    }
  }

  void close() {
    _closed = true;
    for (final client in _all) {
      client.close(force: true);
    }
    _all.clear();
    _idle.clear();
  }
}

class BtrSample {
  const BtrSample(this.identity, this.bytes, this.elapsedMs);
  final BtrIdentity identity;
  final Uint8List bytes;
  final int elapsedMs;
  double get bps => bytes.length * 1000 / elapsedMs;
}
