// Bounded Android transport inspired by the supplied BTR 2026.10.8.1.
// MIT attribution: third_party/BTR-LICENSE.txt. Source identity rules are stricter.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/network.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/settings.dart';

class _PieceResult {
  const _PieceResult(this.bytes, this.error);
  final Uint8List? bytes;
  final Object? error;
}

class _Attempt {
  _Attempt(this.data, this.received);
  final Uint8List data;
  int received;
  bool validated = false;
  int started = 0;
  int progress = 0;
}

class _Demand {
  _Demand(this.id, this.generation, this.startedAt) : progressAt = startedAt;
  final int id, generation;
  final int startedAt;
  int progressAt;
  int deliveredBytes = 0;
  String stage = 'discovery';
  final token = BtrCancel();
  String? cancellation;
}

// Only transport interruptions may be retried. Protocol/identity violations and
// unexpected implementation errors fail closed, including redirect responses.
bool _recoverable(Object error) => switch (error) {
  BtrFailure(:final code, :final status) =>
    code == 'body-short' ||
        code == 'attempt-deadline' ||
        code == 'piece-deadline' ||
        (code == 'range-status' &&
            (status == 408 ||
                status == 429 ||
                (status != null && status >= 500 && status <= 599))),
  TimeoutException() || SocketException() || HttpException() => true,
  _ => false,
};

String _failureCode(Object error) => switch (error) {
  BtrFailure(:final code) => code,
  TimeoutException() => 'timeout',
  SocketException() => 'socket-io',
  HttpException() => 'http-io',
  BtrCancelled() => 'cancelled',
  _ => 'internal-error',
};

class BtrTrack {
  BtrTrack(this.spec, this.candidates, this.owner);
  final BtrTrackSpec spec;
  final List<Uri> candidates;
  final BtrTransport owner;
  BtrMetrics get metrics => owner.metrics;
  BtrNetwork get network => owner.network;
  BtrAdaptive get adaptive => owner.adaptive;
  bool get audio => spec.kind == 'audio';
  final lifetime = BtrCancel();
  final _jobs = <Future<void>>{};
  final _demands = <_Demand>{};
  int _nextDemand = 0;
  int _recoverableFailures = 0;
  int _reservedBytes = 0;
  Completer<void>? _capacityChanged;
  BtrSample? sample;
  Future<void>? _initializing;
  bool terminal = false;
  bool _terminalRecorded = false;
  String selectionState = 'pending';
  String? lastFailure;
  int _hedges = 0;
  int peakReservedBytes = 0;
  final health = <String, Map<String, Object>>{};

  Future<void> initialize() => _initializing ??= _discover();

  Future<void> _discover() async {
    selectionState = 'selecting';
    // At most 9 candidates, three at a time, no periodic CDN traffic.
    for (var base = 0; base < math.min(9, candidates.length); base += 3) {
      lifetime.check();
      final batch = candidates.skip(base).take(3).toList();
      final tokens = List.generate(batch.length, (_) => BtrCancel());
      final unlink = lifetime.listen(() {
        for (final t in tokens) {
          t.cancel();
        }
      });
      final winner = Completer<BtrSample>();
      var failed = 0;
      final tasks = <Future<void>>[];
      for (var i = 0; i < batch.length; i++) {
        final index = i;
        tasks.add(() async {
          try {
            if (index > 0) {
              await tokens[index].delay(
                Duration(milliseconds: index == 1 ? 120 : 300),
              );
            }
            final s = await network.sample(
              batch[index],
              tokens[index],
              audio: audio,
            );
            health[batch[index].host] = {
              'state': 'healthy',
              'bps': s.bps.round(),
            };
            if (!winner.isCompleted) winner.complete(s);
          } catch (error) {
            if (error is! BtrCancelled) {
              metrics.failures++;
              metrics.discoveryFailures++;
              health[batch[index].host] = {
                'state': 'quarantined-for-session',
              };
              lastFailure = _failureCode(error);
              metrics.event('source-failed', {
                'track': spec.kind,
                'host': batch[index].host,
                'reason': lastFailure!,
                if (error is BtrFailure && error.status != null)
                  'status': error.status!,
              });
            }
            failed++;
            if (failed == batch.length && !winner.isCompleted) {
              winner.completeError(const BtrFailure('no-source'));
            }
          }
        }());
      }
      try {
        sample = await lifetime.bind(winner.future);
      } on BtrFailure {
        // Next bounded group. Never retry a rejected signed address forever.
      } finally {
        for (final t in tokens) {
          t.cancel();
        }
        await Future.wait(tasks);
        unlink();
      }
      if (sample != null) {
        selectionState = 'selected';
        metrics.event('source-locked', {
          'track': spec.kind,
          'host': sample!.identity.uri.host,
          'segmented': owner.mode.usesThreads && sample!.identity.canSegment,
          'crossSourceComposition': false,
        });
        adaptive.sample(sample!.bytes.length, sample!.elapsedMs);
        return;
      }
    }
    terminal = true;
    selectionState = 'failed';
    lastFailure = 'no-validated-source';
    throw const BtrFailure('no-validated-source');
  }

  void _cancelDemand(_Demand demand, String reason) {
    if (!demand.token.cancelled) {
      metrics.cancellations++;
      demand.cancellation = reason;
      demand.token.cancel();
    }
  }

  void _releaseBytes(int count) {
    _reservedBytes -= count;
    final changed = _capacityChanged;
    _capacityChanged = null;
    changed?.complete();
  }

  Future<void> serve(HttpRequest request) async {
    if (terminal) throw const BtrFailure('track-ended');
    lifetime.check();
    final demand = _Demand(++_nextDemand, owner._seekGeneration, metrics.now());
    final token = demand.token;
    _demands.add(demand);
    final isHead = request.method == 'HEAD';
    // A new GET is not proof that mpv has abandoned any previous response.
    // Keep each HTTP demand independent until its peer closes or it completes.
    final unlink = lifetime.listen(
      () => _cancelDemand(demand, 'session-closed'),
    );
    var sent = false;
    var delivered = 0;
    var stage = 'discovery';
    var outcome = 'cancelled';
    String? failure;
    request.response.done.then(
      (_) {},
      onError: (Object _) {
        _cancelDemand(demand, 'client-disconnected');
      },
    );
    try {
      await token.bind(initialize());
      token.check();
      final identity = sample!.identity;
      final rangeHeader = isHead
          ? null
          : request.headers.value(HttpHeaders.rangeHeader);
      final range = BtrRange.request(rangeHeader, identity.total);
      metrics.event('demand-started', {
        'track': spec.kind,
        'request': demand.id,
        'generation': demand.generation,
        'method': isHead ? 'HEAD' : 'GET',
        if (range != null) 'start': range.start,
        if (range != null) 'end': range.end,
      });
      if (range == null) {
        request.response.statusCode = 416;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${identity.total}',
        );
        request.response.contentLength = 0;
        stage = 'proxy-close';
        await token.bind(
          request.response.close().timeout(const Duration(seconds: 2)),
        );
        outcome = 'range-rejected';
        return;
      }
      final response = request.response
        ..statusCode = rangeHeader == null ? 200 : 206
        ..contentLength = isHead ? identity.total : range.length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          audio ? 'audio/mp4' : 'video/mp4',
        )
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (identity.etag != null) {
        response.headers.set(HttpHeaders.etagHeader, identity.etag!);
      }
      if (rangeHeader != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/${identity.total}',
        );
      }
      if (!isHead) {
        stage = 'upstream';
        demand.stage = stage;
        final stream = owner.mode.usesThreads && identity.canSegment
            ? _ordered(range, token)
            : _direct(range, token);
        await for (final bytes in stream) {
          token.check();
          stage = 'proxy-write';
          demand.stage = stage;
          sent = true;
          response.add(bytes);
          await token.bind(
            response.flush().timeout(const Duration(seconds: 15)),
          );
          // Successfully handed to the loopback socket; not decoded-frame evidence.
          metrics.delivered(spec.kind, bytes.length);
          adaptive.delivered(bytes.length);
          delivered += bytes.length;
          stage = 'upstream';
          demand
            ..stage = stage
            ..deliveredBytes = delivered
            ..progressAt = metrics.now();
        }
      }
      token.check();
      stage = 'proxy-close';
      demand.stage = stage;
      await token.bind(response.close().timeout(const Duration(seconds: 5)));
      outcome = 'complete';
      if (!isHead) _recoverableFailures = 0;
    } catch (error) {
      if (!token.cancelled && error is! BtrCancelled) {
        failure = _failureCode(error);
        if ((stage == 'proxy-write' || stage == 'proxy-close') &&
            _recoverable(error)) {
          // Backpressure/disconnect is a local response failure, not evidence
          // that the source or either media representation is permanently bad.
          outcome = 'local-error';
        } else {
          metrics.failures++;
          lastFailure = failure;
          final recoverable = _recoverable(error);
          if (recoverable) _recoverableFailures++;
          // _piece already has a 3-attempt/25s bound. Allow a later native GET
          // to recover, but cap consecutive exhausted demands on this track.
          final mustEnd = !recoverable || _recoverableFailures >= 3;
          if (mustEnd) {
            terminal = true;
            if (!_terminalRecorded) metrics.terminalFailures++;
            _terminalRecorded = true;
            if (recoverable) lastFailure = 'recovery-exhausted';
            for (final other in _demands) {
              if (!identical(other, demand)) {
                _cancelDemand(other, 'track-terminal');
              }
            }
          }
          outcome = terminal ? 'terminal' : 'recoverable';
          metrics.event('transfer-ended', {
            'track': spec.kind,
            'request': demand.id,
            'stage': stage,
            'reason': lastFailure!,
            'terminal': terminal,
          });
        }
      }
      if (!sent) {
        try {
          request.response.statusCode = 502;
          request.response.headers.clear();
          request.response.contentLength = 0;
          await request.response.close().timeout(const Duration(seconds: 2));
        } catch (_) {
          /* client already disconnected */
        }
      } else {
        // Never replay a prefix or write a new status after media headers.
        // detachSocket is illegal once headers have been sent. A deadline
        // terminates this incomplete response and its socket immediately.
        request.response.deadline = Duration.zero;
      }
    } finally {
      token.cancel();
      unlink();
      _demands.remove(demand);
      metrics.event('demand-ended', {
        'track': spec.kind,
        'request': demand.id,
        'generation': demand.generation,
        'stage': stage,
        'outcome': outcome,
        'deliveredBytes': delivered,
        if (demand.cancellation != null) 'cancellation': demand.cancellation!,
        'reason': ?failure,
      });
    }
  }

  Stream<Uint8List> _direct(BtrRange range, BtrCancel token) async* {
    // Weak/no-validator fallback uses one unsegmented response.
    final id = sample!.identity;
    BtrHttpLease? lease;
    StreamIterator<List<int>>? reader;
    var complete = false;
    var count = 0;
    try {
      lease = await network.open(
        id.uri,
        range,
        token,
        audio: audio,
        priority: () => audio ? 220 : 200,
        etag: id.etag,
      );
      BtrNetwork.validate(lease.response, range, identity: id, actual: id.uri);
      reader = StreamIterator(lease.response);
      while (await token.bind(
        reader.moveNext().timeout(network.stallTimeout),
      )) {
        final data = reader.current;
        metrics.received(spec.kind, data.length);
        count += data.length;
        if (count > range.length) throw const BtrFailure('body-overrun');
        yield Uint8List.fromList(data);
      }
      if (count != range.length) throw const BtrFailure('body-short');
      complete = true;
    } catch (error) {
      if (!token.cancelled && error is! BtrCancelled) {
        metrics.failures++;
        metrics.requestFailures++;
        lastFailure = _failureCode(error);
        metrics.event('request-failed', {
          'track': spec.kind,
          'stage': 'upstream-direct',
          'start': range.start,
          'end': range.end,
          'reason': lastFailure!,
        });
      }
      rethrow;
    } finally {
      await reader?.cancel();
      await lease?.close(reusable: complete);
    }
  }

  Stream<Uint8List> _ordered(BtrRange range, BtrCancel token) async* {
    const window = 4 * 1024 * 1024;
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    final jobs = <Future<void>>{};
    var cursor = range.start;
    var head = cursor;
    var reserved = 0;
    final queue = Queue<(BtrRange, Future<_PieceResult>)>();
    void fill() {
      // Keep distant speculative data bounded even if the head stalls.
      while (cursor <= range.end &&
          queue.length < math.max(1, owner.scheduler.limit - 2)) {
        final size = cursor == range.start ? 65536 : adaptive.pieceSize;
        final end = math.min(cursor + size - 1, range.end);
        final piece = BtrRange(cursor, end);
        // Share the original per-track memory cap across overlapping demands.
        if (_reservedBytes + piece.length > window) break;
        final offset = cursor;
        Future<_PieceResult> run() async {
          try {
            final s = sample!;
            if (offset >= 0 && end < s.bytes.length) {
              return _PieceResult(
                Uint8List.sublistView(s.bytes, offset, end + 1),
                null,
              );
            }
            return _PieceResult(
              await _piece(
                piece,
                scope,
                isHead: () => offset == head,
                priority: () => (audio ? 120 : 80) + (offset == head ? 100 : 0),
              ),
              null,
            );
          } catch (e) {
            return _PieceResult(null, e);
          }
        }

        final task = run();
        final finished = task.then<void>((_) {});
        _jobs.add(finished);
        jobs.add(finished);
        unawaited(
          finished.then((_) {
            _jobs.remove(finished);
            jobs.remove(finished);
          }),
        );
        queue.add((piece, task));
        reserved += piece.length;
        _reservedBytes += piece.length;
        peakReservedBytes = math.max(peakReservedBytes, _reservedBytes);
        cursor = end + 1;
      }
    }

    try {
      while (cursor <= range.end || queue.isNotEmpty) {
        scope.check();
        fill();
        if (queue.isEmpty) {
          await scope.bind((_capacityChanged ??= Completer<void>()).future);
          continue;
        }
        final entry = queue.removeFirst();
        final result = await scope.bind(entry.$2);
        if (result.error case final error?) throw error;
        yield result.bytes!;
        reserved -= entry.$1.length;
        _releaseBytes(entry.$1.length);
        head = entry.$1.end + 1;
      }
    } finally {
      scope.cancel();
      await Future.wait(jobs.toList());
      _releaseBytes(reserved);
      unlink();
    }
  }

  Future<Uint8List> _piece(
    BtrRange range,
    BtrCancel token, {
    required bool Function() isHead,
    required int Function() priority,
  }) async {
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    final timer = Timer(const Duration(seconds: 25), scope.cancel);
    Uint8List? prefix;
    Object lastError = const BtrFailure('piece-failed');
    try {
      for (var round = 0; round < 3; round++) {
        scope.check();
        if (round > 0) {
          await scope.delay(Duration(milliseconds: 500 * round));
          scope.check();
          metrics.retries++;
          metrics.event('retry', {'track': spec.kind, 'round': round});
        }
        final mainToken = BtrCancel();
        final hedgeToken = BtrCancel();
        final disconnect = scope.listen(() {
          mainToken.cancel();
          hedgeToken.cancel();
        });
        final data = Uint8List(range.length);
        if (prefix != null) data.setRange(0, prefix.length, prefix);
        final main = _Attempt(data, prefix?.length ?? 0);
        _Attempt? hedge;
        final winner = Completer<Uint8List>();
        final tasks = <Future<void>>[];
        var mainDone = false;
        var hedgeStarted = false;
        var hedgeDone = false;
        Timer? hedgeTimer;
        void maybeFail() {
          if (mainDone && (!hedgeStarted || hedgeDone) && !winner.isCompleted) {
            winner.completeError(lastError);
          }
        }

        void launch(_Attempt attempt, BtrCancel cancel, bool copy) {
          tasks.add(() async {
            try {
              await _attempt(range, attempt, cancel, priority);
              if (!winner.isCompleted) winner.complete(attempt.data);
            } catch (e) {
              lastError = e;
              if (e is! BtrCancelled &&
                  !_recoverable(e) &&
                  !winner.isCompleted) {
                winner.completeError(e);
              }
            } finally {
              if (copy) {
                hedgeDone = true;
                _hedges--;
              } else {
                mainDone = true;
              }
              maybeFail();
            }
          }());
        }

        launch(main, mainToken, false);
        hedgeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
          if (winner.isCompleted ||
              mainDone ||
              hedgeStarted ||
              !isHead() ||
              _hedges > 0 ||
              main.started == 0 ||
              owner.scheduler.active >= owner.scheduler.limit ||
              (!adaptive.buffering &&
                  adaptive.playing &&
                  adaptive.ahead >= 6)) {
            return;
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          final delay = adaptive.hedgeMs;
          if (now - main.started < delay) return;
          final rate = main.received * 1000 / math.max(1, now - main.started);
          if (now - main.progress < delay &&
              main.received > 0 &&
              (adaptive.connectionBps == 0 ||
                  rate >= adaptive.connectionBps * .6)) {
            return;
          }
          hedgeStarted = true;
          _hedges++;
          metrics.hedges++;
          metrics.event('hedge', {'track': spec.kind});
          final kept =
              main.validated &&
                  main.received >= 32768 &&
                  main.received < range.length
              ? main.received
              : 0;
          final bytes = Uint8List(range.length);
          if (kept > 0) bytes.setRange(0, kept, main.data);
          hedge = _Attempt(bytes, kept);
          launch(hedge!, hedgeToken, true);
        });
        try {
          final result = await scope.bind(winner.future);
          return result;
        } catch (error) {
          lastError = error;
          final best = hedge != null && hedge!.received > main.received
              ? hedge!
              : main;
          if (best.validated &&
              best.received >= 32768 &&
              best.received < range.length) {
            prefix = Uint8List.fromList(best.data.sublist(0, best.received));
          } else {
            prefix = null;
          }
          if (error is! BtrCancelled && !_recoverable(error)) {
            rethrow;
          }
        } finally {
          hedgeTimer.cancel();
          mainToken.cancel();
          hedgeToken.cancel();
          await Future.wait(tasks);
          disconnect();
        }
      }
      throw lastError;
    } on BtrCancelled {
      token.check();
      throw const BtrFailure('piece-deadline');
    } finally {
      timer.cancel();
      unlink();
      scope.cancel();
    }
  }

  Future<void> _attempt(
    BtrRange piece,
    _Attempt attempt,
    BtrCancel token,
    int Function() priority,
  ) async {
    final id = sample!.identity;
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    final timer = Timer(network.attemptTimeout, scope.cancel);
    final remaining = BtrRange(piece.start + attempt.received, piece.end);
    BtrHttpLease? lease;
    StreamIterator<List<int>>? reader;
    var complete = false;
    final before = attempt.received;
    try {
      lease = await network.open(
        id.uri,
        remaining,
        scope,
        audio: audio,
        priority: priority,
        etag: id.etag,
        onStarted: () {
          if (before > 0) {
            metrics.resumes++;
            metrics.resumedBytes += before;
            metrics.event('resume', {
              'track': spec.kind,
              'prefixBytes': before,
            });
          }
          attempt.started = attempt.progress =
              DateTime.now().millisecondsSinceEpoch;
        },
      );
      BtrNetwork.validate(
        lease.response,
        remaining,
        identity: id,
        actual: id.uri,
      );
      attempt.validated = true;
      reader = StreamIterator(lease.response);
      while (await scope.bind(
        reader.moveNext().timeout(network.stallTimeout),
      )) {
        final bytes = reader.current;
        metrics.received(spec.kind, bytes.length);
        if (attempt.received + bytes.length > piece.length) {
          throw const BtrFailure('body-overrun');
        }
        attempt.data.setRange(
          attempt.received,
          attempt.received + bytes.length,
          bytes,
        );
        attempt
          ..received += bytes.length
          ..progress = DateTime.now().millisecondsSinceEpoch;
      }
      if (attempt.received != piece.length) {
        throw const BtrFailure('body-short');
      }
      scope.check();
      complete = true;
      adaptive.sample(
        attempt.received - before,
        DateTime.now().millisecondsSinceEpoch - attempt.started,
      );
    } catch (error) {
      final failure = error is BtrCancelled && !token.cancelled
          ? const BtrFailure('attempt-deadline')
          : error;
      if (!token.cancelled) {
        metrics.failures++;
        metrics.requestFailures++;
        lastFailure = _failureCode(failure);
        metrics.event('request-failed', {
          'track': spec.kind,
          'stage': 'upstream-piece',
          'start': remaining.start,
          'end': remaining.end,
          'reason': lastFailure!,
          if (error is BtrFailure && error.status != null)
            'status': error.status!,
        });
        if (error is BtrFailure &&
            (error.status == 412 || error.status == 429)) {
          adaptive.pushback();
        }
      }
      throw failure;
    } finally {
      timer.cancel();
      unlink();
      await reader?.cancel();
      await lease?.close(reusable: complete);
    }
  }

  Future<void> close() async {
    lifetime.cancel();
    await Future.wait(_jobs.toList());
    try {
      await _initializing;
    } catch (_) {
      // Discovery failures/cancellation are already delivered to initialize().
    }
  }
}

class BtrTransport {
  BtrTransport({
    required this.mode,
    required this.metrics,
    Map<String, String> headers = const {},
    BtrNetwork? network,
    BtrScheduler? scheduler,
    this.settings = const BtrSettings(),
  }) : scheduler =
           scheduler ??
           BtrScheduler(
             limit: settings.autoConcurrency ? 8 : settings.manualThreads,
           ) {
    if (!settings.autoConcurrency) {
      this.scheduler.limit = settings.manualThreads;
    }
    this.network =
        network ?? BtrNetwork(this.scheduler, metrics, headers: headers);
    adaptive = BtrAdaptive(this.scheduler, automatic: settings.autoConcurrency);
  }
  final BtrMode mode;
  final BtrMetrics metrics;
  final BtrSettings settings;
  final BtrScheduler scheduler;
  late final BtrNetwork network;
  late final BtrAdaptive adaptive;
  final tracks = <String, BtrTrack>{};
  final _handlers = <Future<void>>{};
  int _activeHandlers = 0;
  int _peakHandlers = 0;
  int _capacityRejections = 0;
  int _invalidRejections = 0;
  bool _retiring = false;
  Future<void> get settled => Future.wait(_handlers.toList());
  HttpServer? _server;
  final _capability = List.generate(
    24,
    (_) => math.Random.secure().nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  bool _closed = false;
  int _seekGeneration = 0;
  Future<Map<String, String>>? _starting;
  Future<void>? _closing;

  Future<Map<String, String>> start(List<BtrTrackSpec> specs) {
    if (_closed) return Future.error(const BtrCancelled());
    return _starting ??= _start(specs);
  }

  Future<Map<String, String>> _start(List<BtrTrackSpec> specs) async {
    if (_closed) throw const BtrCancelled();
    if (mode == BtrMode.original) {
      throw StateError('Original bypasses the proxy');
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    if (_closed) {
      await server.close(force: true);
      throw const BtrCancelled();
    }
    _server = server;
    _server!.autoCompress = false;
    final result = <String, String>{};
    for (final spec in specs) {
      final urls = BtrSourcePolicy.candidates(
        spec,
        mode,
        preferredHost: settings.preferredCdn,
      );
      // A selected DASH representation with no admissible source fails closed.
      // Never reintroduce excluded MCDN/P2P through a silent native fallback.
      tracks[spec.kind] = BtrTrack(spec, urls, this);
      metrics.registerTrack(spec.kind);
      result[spec.kind] =
          'http://127.0.0.1:${_server!.port}/$_capability/${spec.kind}';
    }
    _server!.listen((request) {
      final task = _handle(request);
      _handlers.add(task);
      unawaited(
        task.then(
          (_) => _handlers.remove(task),
          onError: (Object _) => _handlers.remove(task),
        ),
      );
    });
    return result;
  }

  Future<void> _handle(HttpRequest r) async {
    final parts = r.uri.pathSegments;
    final valid =
        !_closed &&
        r.connectionInfo?.remoteAddress.address == '127.0.0.1' &&
        r.headers.value(HttpHeaders.hostHeader) ==
            '127.0.0.1:${_server!.port}' &&
        r.headers.value('origin') == null &&
        !r.uri.hasQuery &&
        parts.length == 2 &&
        parts[0] == _capability &&
        tracks.containsKey(parts[1]) &&
        (r.method == 'GET' || r.method == 'HEAD');
    if (!valid || _retiring || _activeHandlers >= 4) {
      if (valid) {
        _capacityRejections++;
      } else {
        _invalidRejections++;
      }
      metrics.event('proxy-rejected', {
        'status': valid ? 503 : 403,
        'reason': !valid
            ? 'invalid-request'
            : _retiring
            ? 'player-stopped'
            : 'handler-capacity',
        'activeHandlers': _activeHandlers,
        'generation': _seekGeneration,
        if (valid) 'track': parts[1],
      });
      r.response.statusCode = valid ? 503 : 403;
      r.response.contentLength = 0;
      await r.response.close().timeout(const Duration(seconds: 2));
      return;
    }
    _activeHandlers++;
    _peakHandlers = math.max(_peakHandlers, _activeHandlers);
    try {
      await tracks[parts[1]]!.serve(r);
    } catch (_) {
      try {
        r.response.statusCode = 502;
        r.response.contentLength = 0;
        await r.response.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* disconnected */
      }
    } finally {
      _activeHandlers--;
    }
  }

  /// Caller must first stop the native player. Unlike a seek or another GET,
  /// that explicit unload proves no response belongs to an active consumer.
  /// Wait for cancelled producers and handlers before opening the same URLs.
  Future<void> retirePlayerRequests() async {
    _retiring = true;
    try {
      for (final track in tracks.values) {
        for (final demand in track._demands) {
          track._cancelDemand(demand, 'player-stopped');
        }
      }
      await settled;
    } finally {
      _retiring = false;
    }
  }

  void seek() {
    // mpv may satisfy a seek from its demux cache without opening another GET.
    // Notification alone must never truncate the currently consumed streams.
    _seekGeneration++;
  }

  Map<String, Object?> snapshot() => {
    'activeProxyHandlers': _activeHandlers,
    'peakProxyHandlers': _peakHandlers,
    'proxyHandlerLimit': 4,
    'proxyCapacityRejections': _capacityRejections,
    'proxyInvalidRejections': _invalidRejections,
    'activeConnections': scheduler.active,
    'videoConnections': tracks.containsKey('video')
        ? scheduler.videoActive
        : null,
    'audioConnections': tracks.containsKey('audio')
        ? scheduler.audioActive
        : null,
    'queuedConnections': scheduler.queued,
    'peakConnections': scheduler.peak,
    'concurrencyLimit': scheduler.limit,
    'configuredConcurrencyLimit': settings.autoConcurrency
        ? 16
        : settings.manualThreads,
    'resourceConcurrencyLimit': BtrScheduler.resourceLimit,
    'autoConcurrency': settings.autoConcurrency,
    'preferredCdn': settings.preferredCdn,
    'tracks': tracks.values
        .map(
          (t) => {
            'kind': t.spec.kind,
            'host': t.sample?.identity.uri.host,
            'selection': t.selectionState,
            'lastFailure': t.lastFailure,
            'identity': t.sample == null
                ? 'pending'
                : t.sample!.identity.canSegment
                ? 'single-origin-strong-etag'
                : 'single-response',
            'peakOrderedReservationBytes': t.peakReservedBytes,
            'terminal': t.terminal,
            'activeDemands': t._demands.length,
            'demands': [
              for (final d in t._demands)
                {
                  'request': d.id,
                  'generation': d.generation,
                  'stage': d.stage,
                  'ageMs': metrics.now() - d.startedAt,
                  'progressAgeMs': metrics.now() - d.progressAt,
                  'deliveredBytes': d.deliveredBytes,
                },
            ],
            'orderedReservationBytes': t._reservedBytes,
            'recoverableDemandFailures': t._recoverableFailures,
            'health': {
              for (final e in t.health.entries)
                e.key: Map<String, Object>.of(e.value),
            },
          },
        )
        .toList(),
  };

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    return _closing = _closeResources();
  }

  Future<void> _closeResources() async {
    final cleanup = tracks.values.map((t) => t.close()).toList();
    network.close();
    await _server?.close(force: true);
    // bind() may still be pending. _start closes its late server before failing.
    try {
      await _starting;
    } catch (_) {
      // Cancellation/start failure is observed by start's caller.
    }
    await Future.wait(cleanup);
    await Future.wait(_handlers.toList());
  }
}
