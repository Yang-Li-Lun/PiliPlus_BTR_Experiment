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
import 'package:PiliPlus/services/btr/proxy_capacity.dart';
import 'package:PiliPlus/services/btr/proxy_diagnostics.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/settings.dart';

class _PieceResult {
  const _PieceResult(this.bytes, this.error);
  final Uint8List? bytes;
  final Object? error;
}

class _Attempt {
  _Attempt(this.data, this.received) : prefix = received;
  final Uint8List data;
  final int prefix;
  int received;
  bool validated = false;
  int started = 0;
  int progress = 0;
}

class _Demand {
  _Demand(this.id, this.generation, this.startedAt, this.trace)
    : progressAt = startedAt;
  final BtrProxyTrace? trace;
  final int id, generation;
  final int startedAt;
  int progressAt;
  int deliveredBytes = 0;
  String stage = 'discovery';
  final token = BtrCancel();
  String? cancellation;
  bool mediaGet = false;
  bool backpressured = false;
  void Function()? rebalance;
  int reservedBytes = 0;
}

class _QueuedPiece {
  _QueuedPiece(this.range, this.token, this.result) {
    result.then((value) => completed = value);
  }
  final BtrRange range;
  final BtrCancel token;
  final Future<_PieceResult> result;
  _PieceResult? completed;
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
  int _latestGetGeneration = 0;
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
  bool _hasNewerGet(_Demand demand) => _demands.any(
    (other) =>
        other.mediaGet &&
        // Native retries and demuxer reads can overlap within ONE seek too.
        // Request order, not only explicit seek generation, ranks live demand.
        other.id > demand.id &&
        !other.token.cancelled,
  );
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
      if (demand.trace case final trace?) {
        owner._proxyDiagnostics.record('demand-cancelled', trace);
      }
    }
  }

  void _releaseBytes(int count) {
    _reservedBytes -= count;
    final changed = _capacityChanged;
    _capacityChanged = null;
    changed?.complete();
  }

  Future<void> serve(
    HttpRequest request, {
    BtrProxySlot? slot,
    int? generation,
    BtrProxyTrace? trace,
  }) async {
    if (terminal) throw const BtrFailure('track-ended');
    lifetime.check();
    final demand = _Demand(
      ++_nextDemand,
      generation ?? owner._seekGeneration,
      metrics.now(),
      trace,
    );
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
    var demandEnded = false;
    String? failure;
    trace?.demandState = () => {
      'demand': demand.id,
      'phase': stage,
      'deliveredBytes': delivered,
      'progressAgeMs': delivered == 0
          ? null
          : metrics.now() - demand.progressAt,
      'backpressured': demand.backpressured,
      'tokenCancelled': token.cancelled,
      'cancellation': demand.cancellation,
      'outcome': demandEnded ? outcome : null,
    };
    if (trace != null) owner._proxyDiagnostics.record('serving', trace);
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
        trace?.serverCloseRequested = true;
        if (trace != null) {
          owner._proxyDiagnostics.record('close-requested', trace);
        }
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
        demand.mediaGet = true;
        if (demand.generation > _latestGetGeneration) {
          _latestGetGeneration = demand.generation;
          _recoverableFailures = 0;
        }
        for (final other in _demands) {
          other.rebalance?.call();
        }
        stage = 'upstream';
        demand.stage = stage;
        final stream = owner.mode.usesThreads && identity.canSegment
            ? _ordered(range, demand)
            : _direct(range, token);
        await for (final bytes in stream) {
          token.check();
          stage = 'proxy-write';
          demand.stage = stage;
          sent = true;
          response.add(bytes);
          if (slot == null) {
            await token.bind(
              response.flush().timeout(const Duration(seconds: 15)),
            );
          } else {
            try {
              await slot.flush(
                response.flush(),
                token,
                onBlocked: () {
                  demand.backpressured = true;
                  demand.rebalance?.call();
                  metrics.event('proxy-writer-parked', {
                    'track': spec.kind,
                    'request': demand.id,
                    'generation': demand.generation,
                  });
                },
              );
            } finally {
              demand.backpressured = false;
            }
          }
          // Successfully handed to the loopback socket; not decoded-frame evidence.
          metrics.delivered(spec.kind, bytes.length);
          adaptive.delivered(bytes.length);
          delivered += bytes.length;
          stage = 'upstream';
          demand
            ..stage = stage
            ..deliveredBytes = delivered
            ..progressAt = metrics.now();
          // Account for the completed socket flush before waiting to resume
          // production. A lent slot is reacquired before another piece/read.
          await slot?.acquire(token);
        }
      }
      token.check();
      stage = 'proxy-close';
      demand.stage = stage;
      trace?.serverCloseRequested = true;
      if (trace != null) {
        owner._proxyDiagnostics.record('close-requested', trace);
      }
      await token.bind(response.close().timeout(const Duration(seconds: 5)));
      outcome = 'complete';
      if (!isHead && demand.generation == _latestGetGeneration) {
        _recoverableFailures = 0;
      }
    } catch (error) {
      if (!token.cancelled && error is! BtrCancelled) {
        failure = _failureCode(error);
        if ((stage == 'proxy-write' || stage == 'proxy-close') &&
            _recoverable(error)) {
          // Backpressure/disconnect is a local response failure, not evidence
          // that the source or either media representation is permanently bad.
          outcome = 'local-error';
          owner._localResponseFailures++;
          owner._localFailureGeneration = math.max(
            owner._localFailureGeneration ?? -1,
            demand.generation,
          );
          owner._readFailure(demand.generation, 'proxy-response');
        } else {
          metrics.failures++;
          lastFailure = failure;
          final recoverable = _recoverable(error);
          if (recoverable) {
            owner._readFailure(demand.generation, 'demand-exhausted');
          }
          final currentGeneration = demand.generation == _latestGetGeneration;
          if (recoverable && currentGeneration) _recoverableFailures++;
          // _piece already has a 3-attempt/25s bound. Allow a later native GET
          // to recover, but cap consecutive exhausted demands on this track.
          final mustEnd =
              !recoverable || (currentGeneration && _recoverableFailures >= 3);
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
          trace?.serverCloseRequested = true;
          if (trace != null) {
            owner._proxyDiagnostics.record('close-requested', trace);
          }
          await request.response.close().timeout(const Duration(seconds: 2));
        } catch (_) {
          /* client already disconnected */
        }
      } else {
        // Never replay a prefix or write a new status after media headers.
        // detachSocket is illegal once headers have been sent. A deadline
        // terminates this incomplete response and its socket immediately.
        request.response.deadline = Duration.zero;
        trace?.serverDeadlineApplied = true;
        if (trace != null) {
          owner._proxyDiagnostics.record('deadline-applied', trace);
        }
      }
    } finally {
      token.cancel();
      unlink();
      _demands.remove(demand);
      demandEnded = true;
      if (trace != null) owner._proxyDiagnostics.record('demand-ended', trace);
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

  Stream<Uint8List> _ordered(BtrRange range, _Demand demand) async* {
    final token = demand.token;
    const window = 4 * 1024 * 1024;
    const headBytes = 65536;
    // Never let speculative data for a stalled consumer occupy the head slots
    // of the other admissible handlers. Their GETs remain valid and independent.
    const speculativeLimit =
        window - (BtrProxyCapacity.responseLimit - 1) * headBytes;
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    final jobs = <Future<void>>{};
    var cursor = range.start;
    var head = cursor;
    var reserved = 0;
    final queue = Queue<_QueuedPiece>();
    Future<void>? reclaiming;
    // Only unconsumed speculation is revocable. The head being awaited or
    // written is outside this queue and remains valid, even across a seek.
    void rebalance() {
      if (!_hasNewerGet(demand) || queue.isEmpty || reclaiming != null) {
        return;
      }
      // Reclaiming is not permission to forget a validation contradiction
      // already observed in an out-of-order piece behind a blocked head.
      for (final entry in queue) {
        final error = entry.completed?.error;
        if (error != null && error is! BtrCancelled && !_recoverable(error)) {
          terminal = true;
          lastFailure = _failureCode(error);
          if (!_terminalRecorded) metrics.terminalFailures++;
          _terminalRecorded = true;
          metrics.event('transfer-ended', {
            'track': spec.kind,
            'request': demand.id,
            'stage': 'prefetch-reclaim',
            'reason': lastFailure!,
            'terminal': true,
          });
          for (final other in _demands) {
            _cancelDemand(other, 'track-terminal');
          }
          return;
        }
      }
      // Keep one already validated contiguous piece for the still-active old
      // consumer. It uses no connection and remains inside the shared window.
      // Cancel the remaining suffix to make room for the newer reader.
      final retained = queue.first.completed?.bytes != null
          ? queue.removeFirst()
          : null;
      final removed = queue.toList();
      queue.clear();
      if (retained != null) queue.add(retained);
      if (removed.isEmpty) return;
      cursor = removed.first.range.start;
      for (final entry in removed) {
        entry.token.cancel();
      }
      metrics.event('prefetch-reclaimed', {
        'track': spec.kind,
        'request': demand.id,
        'generation': demand.generation,
        'pieces': removed.length,
        'retainedBytes': retained?.range.length ?? 0,
      });
      reclaiming = () async {
        await Future.wait(removed.map((entry) => entry.result));
        final bytes = removed.fold<int>(0, (sum, e) => sum + e.range.length);
        reserved -= bytes;
        demand.reservedBytes = reserved;
        _releaseBytes(bytes);
        reclaiming = null;
      }();
    }

    demand.rebalance = rebalance;
    void fill() {
      if (reclaiming != null) return;
      final older = _hasNewerGet(demand);
      final sharing = _demands.any(
        (other) =>
            other.mediaGet &&
            !identical(other, demand) &&
            !other.token.cancelled,
      );
      // Keep distant speculative data bounded even if the head stalls.
      while (cursor <= range.end &&
          queue.length < (older ? 1 : math.max(1, owner.scheduler.limit - 2))) {
        final needsHead = reserved == 0;
        final size = needsHead ? headBytes : adaptive.pieceSize;
        final end = math.min(cursor + size - 1, range.end);
        final piece = BtrRange(cursor, end);
        // A lone reader can use the original full window. Every actual new
        // GET now reclaims old speculation (including same-generation reads)
        // before waiting for capacity, keeping its head reachable. Overlap
        // still reserves head space within the shared 4 MiB cap.
        final limit = needsHead || !sharing ? window : speculativeLimit;
        if (_reservedBytes + piece.length > limit) break;
        final offset = cursor;
        final pieceToken = BtrCancel();
        final unlinkPiece = scope.listen(pieceToken.cancel);
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
                pieceToken,
                demand: demand,
                isHead: () => offset == head,
                priority: () =>
                    (audio ? 120 : 80) +
                    (offset == head ? 1000 : 0) +
                    (_hasNewerGet(demand) ? 0 : 100),
              ),
              null,
            );
          } catch (e) {
            return _PieceResult(null, e);
          } finally {
            unlinkPiece();
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
        queue.add(_QueuedPiece(piece, pieceToken, task));
        reserved += piece.length;
        demand.reservedBytes = reserved;
        _reservedBytes += piece.length;
        peakReservedBytes = math.max(peakReservedBytes, _reservedBytes);
        cursor = end + 1;
      }
    }

    try {
      while (cursor <= range.end || queue.isNotEmpty) {
        scope.check();
        if (reclaiming case final pending?) await scope.bind(pending);
        fill();
        if (queue.isEmpty) {
          await scope.bind((_capacityChanged ??= Completer<void>()).future);
          continue;
        }
        final entry = queue.removeFirst();
        final result = await scope.bind(entry.result);
        if (result.error case final error?) throw error;
        yield result.bytes!;
        reserved -= entry.range.length;
        demand.reservedBytes = reserved;
        _releaseBytes(entry.range.length);
        head = entry.range.end + 1;
      }
    } finally {
      scope.cancel();
      await Future.wait(jobs.toList());
      await reclaiming;
      _releaseBytes(reserved);
      demand
        ..reservedBytes = 0
        ..rebalance = null;
      unlink();
    }
  }

  Future<Uint8List> _piece(
    BtrRange range,
    BtrCancel token, {
    required _Demand demand,
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
              await _attempt(range, attempt, cancel, priority, demand, isHead);
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
          final rate =
              (main.received - main.prefix) *
              1000 /
              math.max(1, now - main.started);
          final needed = adaptive.requiredBps(sample!.identity.total);
          if (now - main.progress < delay &&
              main.received > 0 &&
              (needed == null || rate >= needed)) {
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
    _Demand demand,
    bool Function() isHead,
  ) async {
    final id = sample!.identity;
    final scope = BtrCancel();
    final unlink = token.listen(scope.cancel);
    Timer? timer;
    var phase = 'scheduler';
    final queuedAt = metrics.now();
    int? startedAt;
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
          startedAt = metrics.now();
          phase = 'headers';
          timer = Timer(network.attemptTimeout, scope.cancel);
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
      phase = 'body';
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
        if (_recoverable(failure) && isHead()) {
          owner._readFailure(demand.generation, 'head-attempt');
        }
        metrics.failures++;
        metrics.requestFailures++;
        lastFailure = _failureCode(failure);
        metrics.event('request-failed', {
          'track': spec.kind,
          'request': demand.id,
          'generation': demand.generation,
          'stage': 'upstream-piece',
          'phase': phase,
          'queueMs': (startedAt ?? metrics.now()) - queuedAt,
          'attemptMs': startedAt == null ? 0 : metrics.now() - startedAt!,
          'receivedBytes': attempt.received - before,
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
      timer?.cancel();
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
  static const handlerLimit = BtrProxyCapacity.activeLimit;
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
    _proxyDiagnostics = BtrProxyDiagnostics(
      now: () => metrics.now() - metrics.openedAt,
      capacity: _proxyCapacityState,
    );
  }
  final BtrMode mode;
  final BtrMetrics metrics;
  final BtrSettings settings;
  final BtrScheduler scheduler;
  late final BtrNetwork network;
  late final BtrAdaptive adaptive;
  final tracks = <String, BtrTrack>{};
  final _handlers = <Future<void>>{};
  final _capacity = BtrProxyCapacity();
  final _admissions = <BtrCancel>{};
  late final BtrProxyDiagnostics _proxyDiagnostics;
  int _nextProxyRequest = 0;

  /// A new native seek can open one GET per track. Only an explicit native
  /// stop can retire the currently owned responses when that room is absent.
  bool get seekRequiresPlayerRetirement =>
      _capacity.responses + tracks.length > BtrProxyCapacity.responseLimit;

  Map<String, Object> _proxyCapacityState() => {
    'openResponses': _capacity.responses,
    'responseLimit': BtrProxyCapacity.responseLimit,
    'activeHandlers': _capacity.active,
    'handlerLimit': BtrProxyCapacity.activeLimit,
    'parkedWriters': _capacity.parked,
    'pendingAdmissions': _admissions.length,
    'upstreamConnections': scheduler.active,
    'upstreamResourceLimit': BtrScheduler.resourceLimit,
  };
  int _capacityRejections = 0;
  int _invalidRejections = 0;
  int _retirementRejections = 0;
  int _localResponseFailures = 0;
  int? _localFailureGeneration;
  int _headFailures = 0;
  int? _readFailureAt;
  String? _readFailureKind;
  int? get currentReadFailureAt => _readFailureAt;
  void _readFailure(int generation, String kind) {
    if (generation != _seekGeneration) return;
    if (kind == 'head-attempt' && ++_headFailures < 2) return;
    _readFailureAt = metrics.now();
    _readFailureKind = kind;
  }

  void _resetReadFailure() {
    _readFailureAt = null;
    _readFailureKind = null;
    _headFailures = 0;
    _localFailureGeneration = null;
  }

  bool get currentSeekHasLocalFailure =>
      _localFailureGeneration == _seekGeneration;
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
    final requestId = ++_nextProxyRequest;
    final enteredAt = metrics.now();
    final generation = _seekGeneration;
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
    BtrProxySlot? slot;
    if (valid && !_retiring) slot = _capacity.admit();
    if (!valid || _retiring || slot == null) {
      if (valid && _retiring) {
        _retirementRejections++;
      } else if (valid) {
        _capacityRejections++;
        _localFailureGeneration = generation;
        _readFailure(generation, 'handler-capacity');
      } else {
        _invalidRejections++;
      }
      metrics.event('proxy-rejected', {
        ..._proxyDiagnostics.rejected(
          request: requestId,
          cause: !valid
              ? 'invalid-request'
              : _retiring
              ? 'player-stopped'
              : 'response-limit',
          generation: generation,
          waitMs: 0,
          track: valid ? parts[1] : null,
        ),
        'status': valid ? 503 : 403,
        'reason': !valid
            ? 'invalid-request'
            : _retiring
            ? 'player-stopped'
            : 'handler-capacity',
        'activeHandlers': _capacity.active,
        'generation': generation,
        if (valid) 'track': parts[1],
      });
      r.response.statusCode = valid ? 503 : 403;
      r.response.contentLength = 0;
      await r.response.close().timeout(const Duration(seconds: 2));
      return;
    }
    final admission = BtrCancel();
    _admissions.add(admission);
    final trace = BtrProxyTrace(
      requestId,
      parts[1],
      r.method,
      generation,
      enteredAt - metrics.openedAt,
    )..holdsExecutionSlot = () => slot!.holdsExecutionSlot;
    _proxyDiagnostics.admitted(trace);
    unawaited(
      r.response.done.then(
        (_) => _proxyDiagnostics.responseFinished(trace, error: false),
        onError: (Object _) =>
            _proxyDiagnostics.responseFinished(trace, error: true),
      ),
    );
    try {
      try {
        await slot.acquire(admission).timeout(const Duration(seconds: 2));
      } on TimeoutException {
        admission.cancel();
        _capacityRejections++;
        if (generation == _seekGeneration) _localFailureGeneration = generation;
        _readFailure(generation, 'handler-capacity');
        metrics.event('proxy-rejected', {
          ..._proxyDiagnostics.rejected(
            request: requestId,
            cause: 'execution-timeout',
            generation: generation,
            waitMs: metrics.now() - enteredAt,
            track: parts[1],
          ),
          'status': 503,
          'reason': 'handler-capacity',
          'activeHandlers': _capacity.active,
          'generation': generation,
          'track': parts[1],
        });
        r.response.statusCode = 503;
        r.response.contentLength = 0;
        trace.serverCloseRequested = true;
        _proxyDiagnostics.record('close-requested', trace);
        await r.response.close().timeout(const Duration(seconds: 2));
        return;
      }
      if (_retiring || _closed) throw const BtrCancelled();
      _admissions.remove(admission);
      await tracks[parts[1]]!.serve(
        r,
        slot: slot,
        generation: generation,
        trace: trace,
      );
    } catch (_) {
      try {
        r.response.statusCode = 502;
        r.response.contentLength = 0;
        trace.serverCloseRequested = true;
        _proxyDiagnostics.record('close-requested', trace);
        await r.response.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* disconnected */
      }
    } finally {
      admission.cancel();
      _admissions.remove(admission);
      slot.close();
      _proxyDiagnostics.released(trace);
    }
  }

  /// Caller must first stop the native player. Unlike a seek or another GET,
  /// that explicit unload proves no response belongs to an active consumer.
  /// Wait for cancelled producers and handlers before opening the same URLs.
  Future<void> retirePlayerRequests() async {
    _retiring = true;
    try {
      for (final admission in _admissions.toList()) {
        admission.cancel();
      }
      for (final track in tracks.values) {
        for (final demand in track._demands) {
          track._cancelDemand(demand, 'player-stopped');
        }
      }
      await settled;
      _resetReadFailure();
    } finally {
      _retiring = false;
    }
  }

  void seek() {
    // mpv may satisfy a seek from its demux cache without opening another GET.
    // Notification alone must never truncate the currently consumed streams.
    _seekGeneration++;
    _resetReadFailure();
  }

  Map<String, Object?> snapshot() => {
    'proxyLifecycle': _proxyDiagnostics.snapshot(),
    'activeProxyHandlers': _capacity.active,
    'peakProxyHandlers': _capacity.peak,
    'proxyHandlerLimit': handlerLimit,
    'openProxyResponses': _capacity.responses,
    'proxyResponseLimit': BtrProxyCapacity.responseLimit,
    'parkedProxyWriters': _capacity.parked,
    'proxyCooperativeYields': _capacity.cooperativeYields,
    'waitingProxyResponses':
        _capacity.responses - _capacity.active - _capacity.parked,
    'proxyWriterSuspensions': _capacity.suspensions,
    'proxyCapacityRejections': _capacityRejections,
    'proxyInvalidRejections': _invalidRejections,
    'proxyRetirementRejections': _retirementRejections,
    'proxyLocalResponseFailures': _localResponseFailures,
    'localReadFailureGeneration': _localFailureGeneration,
    'currentReadFailureKind': _readFailureKind,
    'currentReadFailureAgeMs': _readFailureAt == null
        ? null
        : metrics.now() - _readFailureAt!,
    'currentHeadFailures': _headFailures,
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
            'totalBytes': t.sample?.identity.total,
            'estimatedAverageRequiredBps': t.sample == null
                ? null
                : adaptive.requiredBps(t.sample!.identity.total),
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
                  'backpressured': d.backpressured,
                  'ageMs': metrics.now() - d.startedAt,
                  'progressAgeMs': metrics.now() - d.progressAt,
                  'deliveredBytes': d.deliveredBytes,
                  'orderedReservationBytes': d.reservedBytes,
                  'prefetchDeprioritized': t._hasNewerGet(d),
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
    for (final admission in _admissions.toList()) {
      admission.cancel();
    }
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
