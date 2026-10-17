import 'dart:io';

import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

// Compile exact controller methods against a deterministic native contract.
// This covers the controller wiring without pretending to run Android/mpv.
String method(String source, String marker) {
  final start = source.indexOf(marker);
  if (start < 0) throw StateError('missing method: $marker');
  // These methods have named parameter braces before the body.
  final body = source.indexOf(RegExp(r'\)\s*(?:async\s*)?\{'), start);
  final open = source.indexOf('{', body);
  var depth = 1;
  var end = open + 1;
  while (depth != 0) {
    final char = source[end++];
    if (char == '{') depth++;
    if (char == '}') depth--;
  }
  return source.substring(start, end);
}

String block(String source, int start) {
  final open = source.indexOf('{', start);
  var depth = 1, end = open + 1;
  while (depth > 0) {
    final c = source[end++];
    if (c == '{') depth++;
    if (c == '}') depth--;
  }
  return source.substring(start, end);
}

void main() {
  test('actual controller: late EOF, queued seek, reopen and failure contracts', () async {
    // package:test may supply a data URI as Platform.script; use the test path.
    final root = Directory.current.path.endsWith('btr_tests')
        ? Directory.current.parent.parent
        : Directory.current;
    final source = File(
      Platform.environment['BTR_CONTROLLER_SOURCE'] ??
          '${root.path}/lib/plugin/pl_player/controller.dart',
    ).readAsStringSync();
    final seek = method(source, 'Future<void> seek(');
    final refresh = method(source, 'Future<void>? refreshPlayer(');
    final resume = source.contains('Future<void> _resumeAfterSeek(')
        ? method(source, 'Future<void> _resumeAfterSeek(')
        : '';
    final recovery = source.contains('void _scheduleBtrReadRecovery(')
        ? method(source, 'void _scheduleBtrReadRecovery(')
        : '';
    final errorCallback = block(
      source,
      source.indexOf('(String event)', source.indexOf('stream.error.listen')),
    );
    final completedCallback = block(
      source,
      source.indexOf(
        '(bool completed)',
        source.indexOf('stream.completed.listen'),
      ),
    );
    final handlers = [
      'bool _handleBtrNativeError(',
      'bool _acceptBtrCompleted(',
      'Future<void> _recoverBtrSeekEof(',
      'void _checkBtrReadStall(',
      'Future<void> _stopTerminalBtr(',
    ].where(source.contains).map((marker) => method(source, marker)).join('\n');
    final native = File(
      '${root.path}/.toolchain/pub-cache/git/media-kit-73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart',
    ).readAsStringSync();
    final nativeDispatch = block(
      native,
      native.indexOf(
        'if (!logController.isClosed)',
        native.indexOf('case generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE:'),
      ),
    );
    final fixture =
        File(
          '${root.path}/tool/btr_tests/.dart_tool/controller_recovery_fixture.dart',
        )..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import '${File('${root.path}/test/btr/fake_cdn.dart').uri}';
import '${File('${root.path}/test/btr/demand_lifecycle_test.dart').uri}' show waitUntil;
import 'package:PiliPlus/services/playback_seek_intent.dart';
import 'package:PiliPlus/services/playback_source_sequence.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/read_recovery.dart';
const kDebugMode = false;
void debugPrint(String message) {}
class PlayerLog { PlayerLog({required String prefix, required String level, required String text}); }
class SmartDialog { static void showToast(String text, {Duration? displayTime}) {} }
class Utils { static void reportError(String text) {} }
class EasyThrottle { static void throttle(String key, Duration d, void Function() f) => f(); }
enum Beat { completed }
enum DataStatus {error}
enum Status {completed, paused, playing; bool get isCompleted => this == completed;}
class Value<T> { Value(this.value); T value; }
class FileSource {}
class Scope { bool closed = false; }
class Media { Media(this.start); final Duration start; Media copyWith({required Duration start}) => Media(start); }
class State { bool completed = true, playing = false, buffering = false; final playlist = <Object>[]; Duration position = Duration.zero, buffer = Duration.zero, duration = const Duration(seconds: 120); }
class NativeLock { Future<T> synchronized<T>(Future<T> Function() work) => work(); }
class Player {
  final lock = NativeLock();
  final state = State();
  final current = [Media(Duration.zero)];
  final calls = <String>[];
  final errorController = StreamController<String>.broadcast(sync: true);
  final logController = StreamController<PlayerLog>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  late final stream = (buffer: const Stream<Duration>.empty(), error: errorController.stream, completed: completedController.stream);
  void nativeLog(String prefix, String level, String text) {
    $nativeDispatch
  }
  bool isPlayingStateChangeAllowed = false, lateEof = true, failSeek = false, lateOpenEof = false;
  Completer<void>? stopping;
  bool eofDuringSeek = false;
  Future<void> Function()? onSeek;
  Future<void> Function()? onOpen;
  Future<void> seek(Duration p) async {
    calls.add('seek:\${p.inSeconds}');
    if (failSeek) throw StateError('secret URL');
    await onSeek?.call();
    state.position = p;
    if (eofDuringSeek) {
      state.playing = false;
      state.completed = true;
      completedController.add(true);
    }
    state.completed = false;
    if (lateEof) state.completed = true;
  }
  Future<void> play({bool synchronized = true}) async {
    // Locked media-kit real.dart:321: completed play seeks 0 and playlist-pos 0.
    if (state.completed) { calls.add('replay:0'); state.position = Duration.zero; }
    state.playing = true;
  }
  Future<void> command(List<String> args) async {
    calls.add(args.join(':')); state.playing = args.last == 'no';
  }
  Future<void> stop() async { calls.add('stop'); await stopping?.future; state.position = Duration.zero; state.completed = false; }
  Future<void> pause() async { calls.add('pause'); state.playing = false; }
  Future<void> open(Media media, {required bool play}) async { calls.add('open:\${media.start.inSeconds}'); await onOpen?.call(); state.position = media.start; state.playing = play; if (lateOpenEof) state.completed = true; }
}
class Transport implements BtrTransport {
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  Transport(this.player); final Player player;
  bool currentSeekHasLocalFailure = false;
  int? currentReadFailureAt;
  final tracks = <String, BtrTrack>{};
  void seek() { currentSeekHasLocalFailure = false; }
  Future<void> retirePlayerRequests() async { player.calls.add('retire'); }
  Future<void> close() async { player.calls.add('transport-close'); }
}
typedef BtrPlayback = Session;
class Session {
  Session(Player p): transport = Transport(p);
  BtrTransport transport;
  int now = 0;
  late final metrics = BtrMetrics(BtrMode.combined, clock: () => now);
  final readRecovery = BtrReadRecovery();
  void seek(Duration p) { readRecovery.reset(); metrics.seek(p.inMilliseconds); transport.seek(); }
  Future<void> close() => transport.close();
}
class Subject {
  Subject() { _btrPlayback = Session(_videoPlayerController!); }
  final onlyPlayAudio = Value(false);
  final _statusListeners = <void Function(Status)>[];
  int completionCount = 0;
  void _startWakeLockTimer() {}
  void makeHeartBeat(int value, {Beat? type}) { if (value == -1) completionCount++; }
  void wire() {
    final player = _videoPlayerController!;
    player.stream.error.listen($errorCallback);
    player.stream.completed.listen($completedCallback);
  }
  $handlers
  Player? _videoPlayerController = Player();
  Session? _btrPlayback;
  final _seekIntent = PlaybackSeekIntent()..reset(playing: true);
  final _sourceSequence = PlaybackSourceSequence();
  final _taskScope = Scope();
  int _btrOpenGeneration = 1, _btrFailedGeneration = -1, _btrAutomaticReopens = 0;
  bool _processing = false, _reopening = false, isLive = false;
  bool Function()? _btrSourceIsCurrent;
  final dataSource = Object();
  final dataStatus = Value(DataStatus.error);
  final showControls = Value(false);
  final isBuffering = Value(false);
  final buffered = Value(0);
  final dynamic danmakuController = null, audioSessionHandler = null;
  Status playerStatus = Status.completed;
  Timer? _retryTimer;
  void _cancelSubForSeek() {}
  void _updatePlaybackState({Duration? position}) {}
  void _updateIOSPip(Duration position) {}
  Future<void> play({bool hideControls = true}) => _videoPlayerController!.play();
  $seek
  $refresh
  $resume
  $recovery
}
void check(bool ok, String message) { if (!ok) throw StateError(message); }
Future<void> main() async {
  final failures = <String>[];
  Future<void> scenario(String name, Future<void> Function() run) async {
    try { await run(); print('PASS: \$name'); } catch (e) { failures.add(name); print('FAIL: \$name: \$e'); }
  }
  await scenario('EOF resume never replays zero on a late EOF event', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 40));
    check(c._videoPlayerController!.state.position.inSeconds == 40, 'target lost');
    check(!c._videoPlayerController!.calls.contains('replay:0'), 'replayed zero');
    check(c._videoPlayerController!.state.playing, 'did not resume');
  });
  await scenario('EOF arriving during a playing seek restores native play intent', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.state..playing = true..completed = false;
    p.eofDuringSeek = true;
    await c.seek(const Duration(seconds: 40));
    await Future<void>.delayed(Duration.zero);
    check(p.state.playing, 'EOF during command left native playback paused');
    check(p.state.position.inSeconds == 40, 'requested target lost');
    check(p.calls.where((s) => s.startsWith('seek:')).length == 1, 'in-flight EOF caused a redundant re-seek');
    check(!p.calls.any((s) => s == 'stop' || s.startsWith('open:') || s == 'replay:0'), 'seek forced a reload/replay');
  });
  await scenario('late EOF after command re-seeks target once without reopening', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.lateEof = false; p.state..playing = true..completed = false;
    await c.seek(const Duration(seconds: 40));
    p.state..position = p.state.duration..playing = false..completed = true;
    p.completedController.add(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    check(p.state.position.inSeconds == 40 && p.state.playing, 'late EOF never restored target/playback');
    check(p.calls.where((s) => s == 'seek:40').length == 2, 'expected one bounded native re-seek');
    check(!p.calls.any((s) => s == 'stop' || s.startsWith('open:') || s == 'replay:0'), 'late EOF used reload/replay');
    p.state..playing = false..completed = true;
    p.completedController.add(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    check(p.calls.where((s) => s.startsWith('seek:')).length == 2, 'unbounded EOF re-seek');
  });
  await scenario('queued EOF correction yields to new seek pause source and task close', () async {
    for (final action in ['seek', 'pause', 'source', 'close']) {
      final c = Subject()..wire(); final p = c._videoPlayerController!;
      p.lateEof = false;
      await c.seek(const Duration(seconds: 40));
      final held = Completer<void>();
      final owner = c._sourceSequence.runCurrent((_) => held.future);
      p.state..playing = false..completed = true;
      p.completedController.add(true);
      Future<void>? newer;
      if (action == 'seek') newer = c.seek(const Duration(seconds: 60));
      if (action == 'pause') c._seekIntent.requestPlaying(false);
      if (action == 'source') newer = c._sourceSequence.run((_) async {});
      if (action == 'close') c._taskScope.closed = true;
      held.complete(); await owner; await newer;
      await Future<void>.delayed(Duration.zero);
      check(p.calls.where((s) => s == 'seek:40').length == 1, 'stale EOF correction ran after \$action');
      if (action == 'pause') check(!p.state.playing, 'EOF overrode pause');
    }
  });
  await scenario('pause or new seek during native EOF correction owns final playback', () async {
    for (final pause in [true, false]) {
      final c = Subject()..wire(); final p = c._videoPlayerController!;
      p.lateEof = false; await c.seek(const Duration(seconds: 40));
      final entered = Completer<void>(), gate = Completer<void>();
      p.onSeek = () async { if (!entered.isCompleted) entered.complete(); await gate.future; };
      p.state..completed = true..playing = false;
      p.completedController.add(true); await entered.future;
      Future<void>? newer;
      if (pause) { c._seekIntent.requestPlaying(false); } else { newer = c.seek(const Duration(seconds: 60)); }
      gate.complete(); await newer; await Future<void>.delayed(Duration.zero);
      if (pause) check(!p.state.playing, 'correction overrode in-flight pause');
      else check(p.state.position.inSeconds == 60, 'correction overwrote newest target');
    }
  });
  await scenario('classified read failure does not also spend native EOF correction', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.lateEof = false; await c.seek(const Duration(seconds: 40));
    c._btrPlayback!.readRecovery.record('ffurl_read returned -1', const Duration(seconds: 40));
    p.state.completed = true; p.completedController.add(true);
    await Future<void>.delayed(Duration.zero); c._retryTimer?.cancel();
    check(p.calls.where((s) => s.startsWith('seek:')).length == 1, 'read failure triggered both correction paths');
  });
  await scenario('original mode receives no new mid-seek EOF recovery', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    c._btrPlayback = null;
    p.state..playing = true..completed = false;
    p.eofDuringSeek = true; await c.seek(const Duration(seconds: 40));
    await Future<void>.delayed(Duration.zero);
    check(!p.state.playing, 'BTR resume change leaked into original mode');
    check(p.calls.where((s) => s.startsWith('seek:')).length == 1, 'BTR correction leaked into original mode');
  });
  await scenario('queued burst coalesces before native dispatch', () async {
    final c = Subject(); final held = Completer<void>();
    final owning = c._sourceSequence.runCurrent((_) => held.future);
    final seeks = [for (var i = 1; i <= 20; i++) c.seek(Duration(seconds: i))];
    await Future<void>.delayed(Duration.zero);
    check(c._videoPlayerController!.calls.isEmpty, 'seek escaped source/reopen sequence');
    held.complete(); await owning; await Future.wait(seeks);
    check(c._videoPlayerController!.calls.where((s) => s.startsWith('seek:')).join() == 'seek:20', 'stale native seeks dispatched');
  });
  await scenario('reopen stops then retires GETs and preserves target', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 40));
    c._videoPlayerController!.calls.clear();
    await c.refreshPlayer();
    check(c._videoPlayerController!.calls.take(3).join(',') == 'stop,retire,open:40', 'old requests survive reopen');
  });
  await scenario('late EOF after reopen cannot replay from zero', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 40));
    c._videoPlayerController!.lateOpenEof = true;
    await c.refreshPlayer();
    check(c._videoPlayerController!.state.position.inSeconds == 40, 'reopen late EOF replayed zero');
  });
  await scenario('failed seek is diagnosed without a reopen', () async {
    final c = Subject(); c._videoPlayerController!.failSeek = true;
    await c.seek(const Duration(seconds: 40));
    check(c._btrPlayback!.metrics.snapshot()['seekCommandFailures'] == 1, 'seek failure not diagnosed');
    check(!c._videoPlayerController!.calls.any((s) => s.startsWith('open:')), 'failure reopens source');
  });
  await scenario('paused EOF back-drag never unpauses', () async {
    final c = Subject(); c._seekIntent.requestPlaying(false);
    await c.seek(const Duration(seconds: 30));
    check(!c._videoPlayerController!.state.playing, 'paused seek resumed');
    check(c._videoPlayerController!.state.position.inSeconds == 30, 'paused target lost');
  });
  await scenario('new seek during reopen runs after load and keeps latest target', () async {
    final c = Subject(); final stopping = Completer<void>();
    c._videoPlayerController!.stopping = stopping;
    final reopening = c.refreshPlayer();
    await Future<void>.delayed(Duration.zero);
    final seeking = c.seek(const Duration(seconds: 50));
    check(!c._videoPlayerController!.calls.contains('seek:50'), 'seek overtook reopen');
    stopping.complete(); await reopening; await seeking;
    check(c._videoPlayerController!.state.position.inSeconds == 50, 'reopen discarded new seek');
  });
  await scenario('pause during reopen wins over captured play intent', () async {
    final c = Subject(); final stopping = Completer<void>();
    c._videoPlayerController!.stopping = stopping;
    final reopening = c.refreshPlayer();
    await Future<void>.delayed(Duration.zero);
    c._seekIntent.requestPlaying(false);
    stopping.complete(); await reopening;
    check(!c._videoPlayerController!.state.playing, 'reopen overrode pause');
  });
  await scenario('new source while stop is pending prevents old media reopening', () async {
    final c = Subject(); final stopping = Completer<void>();
    c._videoPlayerController!.stopping = stopping;
    final reopening = c.refreshPlayer();
    await Future<void>.delayed(Duration.zero);
    c._seekIntent.reset();
    final next = c._sourceSequence.run((_) async {});
    stopping.complete(); await reopening; await next;
    check(!c._videoPlayerController!.calls.any((s) => s.startsWith('open:')), 'stale media reopened');
  });
  await scenario('automatic reopen is bounded per source and manual recovery remains available', () async {
    final c = Subject();
    await (c as dynamic).refreshPlayer(automatic: true);
    await (c as dynamic).refreshPlayer(automatic: true);
    check(c._videoPlayerController!.calls.where((s) => s.startsWith('open:')).length == 1, 'unbounded automatic reopen');
    await c.refreshPlayer();
    check(c._videoPlayerController!.calls.where((s) => s.startsWith('open:')).length == 2, 'manual recovery blocked');
  });
  await scenario('automatic reopen does not unload a new queued seek', () async {
    final c = Subject(); final held = Completer<void>();
    final owner = c._sourceSequence.runCurrent((_) => held.future);
    final reopening = (c as dynamic).refreshPlayer(automatic: true);
    final seeking = c.seek(const Duration(seconds: 50));
    held.complete(); await owner; await reopening; await seeking;
    check(!c._videoPlayerController!.calls.contains('stop'), 'retry unloaded newer seek');
    check(c._videoPlayerController!.state.position.inSeconds == 50, 'new seek lost');
  });
  await scenario('automatic reopen is suppressed while target is unconfirmed', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 50));
    await (c as dynamic).refreshPlayer(automatic: true);
    check(!c._videoPlayerController!.calls.contains('stop'), 'retry interrupted pending seek');
  });
  await scenario('correlated local read failure reopens pending seek once at its target', () async {
    await runZoned(() async {
      final c = Subject(); await c.seek(const Duration(seconds: 40));
      (c._btrPlayback!.transport as Transport).currentSeekHasLocalFailure = true;
      (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      check(c._videoPlayerController!.calls.contains('open:40'), 'local failure did not recover target');
      check(!c._videoPlayerController!.calls.contains('replay:0'), 'local recovery replayed zero');
      (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      check(c._videoPlayerController!.calls.where((s) => s.startsWith('open:')).length == 1, 'unbounded seek recovery');
    }, zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
      parent.createTimer(zone, duration == const Duration(seconds: 3) ? const Duration(milliseconds: 5) : duration, callback)));
  });
  await scenario('seek alone never triggers read recovery', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 40));
    (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
    check(c._retryTimer == null, 'unconfirmed local failure scheduled a retry');
    check(!c._videoPlayerController!.calls.contains('stop'), 'seek cancelled active streams');
  });
  await scenario('new seek cancels recovery of old target', () async {
    final c = Subject(); await c.seek(const Duration(seconds: 40));
    (c._btrPlayback!.transport as Transport).currentSeekHasLocalFailure = true;
    (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
    final timer = c._retryTimer;
    await c.seek(const Duration(seconds: 50));
    check(timer != null && !timer.isActive, 'old recovery timer survived seek');
    check(!c._videoPlayerController!.calls.contains('stop'), 'new seek was interrupted');
  });
  await scenario('timeline recovery prevents a delayed reopen', () async {
    await runZoned(() async {
      final c = Subject(); await c.seek(const Duration(seconds: 40));
      (c._btrPlayback!.transport as Transport).currentSeekHasLocalFailure = true;
      (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
      c._seekIntent.position(const Duration(seconds: 40));
      c._seekIntent.position(const Duration(milliseconds: 40100));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      check(!c._videoPlayerController!.calls.contains('stop'), 'recovered playback was reopened');
    }, zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
      parent.createTimer(zone, duration == const Duration(seconds: 3) ? const Duration(milliseconds: 5) : duration, callback)));
  });

  Future<void> fast(Future<void> Function() work) => runZoned(work,
    zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
      parent.createTimer(zone, duration == const Duration(seconds: 3) ? const Duration(milliseconds: 15) : duration, callback)));
  await scenario('native ffmpeg HTTP error enters actual stream listener before any local failure', () => fast(() async {
    final c = Subject()..wire(); await c.seek(const Duration(seconds: 40));
    c._videoPlayerController!.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    check(c._retryTimer != null, 'native HTTP error bypassed recovery listener');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(c._videoPlayerController!.calls.contains('open:40'), 'first native error needed a later proxy failure');
    check(c._videoPlayerController!.calls.where((s) => s == 'stop').length == 1, 'not exactly one stop');
  }));
  await scenario('read failure during opening is reconsidered after opening finishes', () => fast(() async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    final s = c._btrPlayback!;
    c._processing = true;
    p.state.position = const Duration(seconds: 37);
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    p.completedController.add(true);
    check(c._retryTimer == null, 'recovery ran inside open');
    check(s.readRecovery.failed && s.readRecovery.abnormalCompleted, 'read evidence lost');
    check(s.transport.currentReadFailureAt == null, 'test invented a proxy failure');
    c._processing = false;
    (c as dynamic)._checkBtrReadStall(s);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.contains('open:37'), 'opening-time native failure was never reconsidered');
    check(c.completionCount == 0, 'read error became natural EOF');
  }));
  await scenario('queued non-seek read recovery yields to resumed playback', () => fast(() async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    final s = c._btrPlayback!, held = Completer<void>();
    final owner = c._sourceSequence.runCurrent((_) => held.future);
    p.state.position = const Duration(seconds: 37);
    p.state.buffering = true; c.isBuffering.value = true;
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(c._reopening, 'retry did not reach the source queue');
    p.state.buffering = false; c.isBuffering.value = false;
    s.readRecovery.position(const Duration(seconds: 37), advancing: true);
    s.readRecovery.position(const Duration(seconds: 38), advancing: true);
    held.complete(); await owner;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(!p.calls.contains('stop'), 'queued recovery unloaded recovered playback');
    check(c._btrAutomaticReopens == 0, 'stale recovery consumed automatic budget');
  }));
  await scenario('deferred opening-time failure respects pause, reset, source and task close', () => fast(() async {
    for (final mode in ['pause', 'reset', 'source', 'closed', 'progress']) {
      final c = Subject()..wire(); final p = c._videoPlayerController!;
      final s = c._btrPlayback!;
      c._processing = true;
      p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
      p.completedController.add(true);
      c._processing = false;
      if (mode == 'pause') c._seekIntent.requestPlaying(false);
      if (mode == 'reset') s.seek(const Duration(seconds: 50));
      if (mode == 'source') c._btrSourceIsCurrent = () => false;
      if (mode == 'closed') c._taskScope.closed = true;
      if (mode == 'progress') {
        s.readRecovery.position(const Duration(seconds: 37), advancing: true);
        s.readRecovery.position(const Duration(seconds: 38), advancing: true);
      }
      (c as dynamic)._checkBtrReadStall(s);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      check(!p.calls.contains('stop'), 'deferred failure ignored guard: \$mode');
      check(c._retryTimer == null, 'deferred invalid evidence armed timer: \$mode');
    }
  }));
  await scenario('exhausted native-only read recovery ends sustained waiting', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    final s = c._btrPlayback!;
    c._btrAutomaticReopens = 1;
    p.state.position = const Duration(seconds: 37);
    p.state.buffering = true; c.isBuffering.value = true;
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    check(s.transport.currentReadFailureAt == null, 'test invented a proxy failure');
    (c as dynamic)._checkBtrReadStall(s);
    s.now = 14999; (c as dynamic)._checkBtrReadStall(s);
    check(c._btrFailedGeneration == -1, 'short native wait stopped playback');
    s.now = 15000; (c as dynamic)._checkBtrReadStall(s);
    await Future<void>.delayed(Duration.zero);
    check(c._btrFailedGeneration == c._btrOpenGeneration, 'native-only exhausted recovery waits forever');
    check(p.calls.contains('pause') && p.calls.contains('transport-close'), 'exhausted recovery did not clean up');
    check(!p.calls.contains('stop'), 'retry budget was bypassed');
  });
  await scenario('repeated native errors cannot postpone the first recovery deadline', () => fast(() async {
    final c = Subject()..wire(); await c.seek(const Duration(seconds: 40));
    final p = c._videoPlayerController!;
    p.nativeLog('ffmpeg', 'error', '[tcp @ 0x123] ffurl_read returned 0xffffff99');
    final first = c._retryTimer;
    check(first != null, 'prefixed read error lost');
    for (var i = 0; i < 20; i++) p.nativeLog('ffmpeg', 'error', 'tcp: ffurl_read returned -5');
    check(identical(first, c._retryTimer), 'error burst reset recovery deadline');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.where((s) => s.startsWith('open:')).length == 1, 'native errors bypassed retry budget');
  }));
  await scenario('read-error completed at mid-file cannot auto-next and resumes saved position', () => fast(() async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.state.position = const Duration(seconds: 37); p.state.buffer = const Duration(seconds: 42);
    c.buffered.value = 42;
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    p.state.completed = true; p.state.playing = false; p.state.buffering = false;
    p.completedController.add(true);
    check(c.completionCount == 0, 'read failure published natural completion');
    p.state.position = Duration.zero;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.contains('open:37'), 'abnormal EOF lost saved position');
    check(!p.calls.contains('replay:0'), 'abnormal EOF replayed zero');
  }));
  await scenario('premature EOF without read evidence is suppressed but never retries by guess', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.state.position = const Duration(seconds: 37); p.completedController.add(true);
    check(c.completionCount == 0, 'premature EOF accepted');
    check(c._retryTimer == null, 'EOF alone invented a read failure');
  });
  await scenario('zero native errors plus sustained current transport stall reopens once', () => fast(() async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    final s = c._btrPlayback!; p.state.position = const Duration(seconds: 37);
    p.state.buffering = true; c.isBuffering.value = true;
    (s.transport as Transport).currentReadFailureAt = 0;
    (c as dynamic)._checkBtrReadStall(s);
    s.now = 14999; (c as dynamic)._checkBtrReadStall(s);
    check(c._retryTimer == null, 'short stall reopened');
    s.now = 15000; (c as dynamic)._checkBtrReadStall(s);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.contains('open:37'), 'no-error stall never entered recovery');
    check(s.metrics.playerErrors == 0, 'fabricated native error');
    (s.transport as Transport).currentReadFailureAt = 15000;
    (c as dynamic)._checkBtrReadStall(s);
    s.now = 30000; (c as dynamic)._checkBtrReadStall(s);
    check(c._btrFailedGeneration == c._btrOpenGeneration && p.calls.contains('pause'), 'exhausted recovery buffers forever');
    check(p.calls.where((v) => v.startsWith('open:')).length == 1, 'unbounded reopen');
  }));
  await scenario('abnormal EOF followed by proxy failure enters stall recovery without classifying unknown errors', () => fast(() async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    final s = c._btrPlayback!; p.state.position = const Duration(seconds: 2);
    p.completedController.add(true);
    (c as dynamic)._checkBtrReadStall(s);
    s.now = 2500; (s.transport as Transport).currentReadFailureAt = s.now;
    s.now = 15000; (c as dynamic)._checkBtrReadStall(s);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.contains('open:2') && c.completionCount == 0, 'completed/local failure chain lost');
  }));
  await scenario('pause, stale source and unsupported stall evidence do not reopen', () async {
    for (final mode in ['pause', 'source', 'no-evidence']) {
      final c = Subject(); final p = c._videoPlayerController!; final s = c._btrPlayback!;
      p.state.buffering = true;
      if (mode != 'no-evidence') (s.transport as Transport).currentReadFailureAt = 0;
      if (mode == 'pause') c._seekIntent.requestPlaying(false);
      if (mode == 'source') c._btrSourceIsCurrent = () => false;
      (c as dynamic)._checkBtrReadStall(s); s.now = 20000;
      (c as dynamic)._checkBtrReadStall(s);
      check(c._retryTimer == null, 'invalid stall recovered: \$mode');
    }
  });
  await scenario('natural EOF and deliberate end seek still publish completed', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.state.position = p.state.duration; p.completedController.add(true);
    check(c.completionCount == 1, 'natural EOF swallowed');
    await c.seek(p.state.duration); p.completedController.add(true);
    check(c.completionCount == 2, 'explicit end seek swallowed');
  });
  await scenario('native recovery respects pause and cancels on newer seek or source', () => fast(() async {
    final c = Subject()..wire(); await c.seek(const Duration(seconds: 40));
    final p = c._videoPlayerController!;
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    await c.seek(const Duration(seconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(!p.calls.contains('stop'), 'old error unloaded newer seek');
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    c._seekIntent.requestPlaying(false);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(p.calls.contains('open:50') && !p.state.playing, 'pause/latest target lost');
    final d = Subject()..wire(); await d.seek(const Duration(seconds: 40));
    d._videoPlayerController!.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    d._btrOpenGeneration++; d._btrPlayback = Session(d._videoPlayerController!);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check(!d._videoPlayerController!.calls.contains('stop'), 'old source recovery survived');
  }));
  await scenario('decoder/audio errors and warnings do not trigger transport reopen', () async {
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    p.nativeLog('ad', 'error', 'Could not open codec secret');
    p.nativeLog('ffmpeg', 'warn', 'HTTP error 503 Service Unavailable');
    p.nativeLog('ao', 'error', 'audio output failed');
    check(c._retryTimer == null, 'non-read error retried source');
  });
  await scenario('original path retains existing completed behavior and HTTP error handling', () async {
    final c = Subject()..wire(); c._btrPlayback = null;
    final p = c._videoPlayerController!;
    p.state.position = const Duration(seconds: 37); p.completedController.add(true);
    p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
    check(c.completionCount == 1 && c._retryTimer == null, 'original path changed');
  });

  await scenario('native error listener retires four actual blocked sockets before exact dual-track reload', () => fast(() async {
    final bytes = Uint8List.fromList(List.generate(16 * 1024 * 1024, (i) => i % 251));
    final cdn = FakeCdn(bytes)..audioBytes = Uint8List.fromList(bytes.map((b) => b ^ 0x55).toList());
    await cdn.start();
    final metrics = BtrMetrics(BtrMode.combined), scheduler = BtrScheduler();
    final transport = BtrTransport(mode: BtrMode.combined, metrics: metrics,
      scheduler: scheduler, network: FakeNetwork(scheduler, metrics, cdn));
    final sockets = <Socket>[];
    final c = Subject()..wire(); final p = c._videoPlayerController!;
    c._btrPlayback!.transport = transport;
    try {
      final urls = await transport.start([for (final kind in ['video', 'audio'])
        BtrTrackSpec(kind: kind, urls: ['https://origin.bilivideo.com/\$kind.m4s'])]);
      for (final kind in ['video', 'audio', 'video', 'audio']) {
        final uri = Uri.parse(urls[kind]!);
        final socket = await Socket.connect(uri.host, uri.port); sockets.add(socket);
        socket.write('GET \${uri.path} HTTP/1.1\\r\\nHost: \${uri.host}:\${uri.port}\\r\\nRange: bytes=0-\\r\\n\\r\\n');
        await socket.flush();
      }
      await waitUntil(() => transport.snapshot()['activeProxyHandlers'] == 4 &&
        (transport.snapshot()['tracks'] as List).every((t) => (t['demands'] as List).any((d) => d['stage'] == 'proxy-write' && d['progressAgeMs'] >= 50)));
      await c.seek(const Duration(seconds: 40));
      check(metrics.cancellations == 0, 'seek cancelled valid GETs');
      try { await fetchLocal(urls['video']!, range: 'bytes=-100'); throw StateError('expected capacity 503'); }
      on BtrFailure catch (e) {
        check(e.status == 503, 'unexpected local status');
        p.nativeLog('ffmpeg', 'error', 'HTTP error 503 Service Unavailable');
      }
      final opened = Completer<void>();
      p.onOpen = () async {
        check(transport.snapshot()['activeProxyHandlers'] == 0 && scheduler.active == 0 && scheduler.queued == 0, 'reload overtook cleanup');
        for (final t in transport.snapshot()['tracks'] as List) check(t['orderedReservationBytes'] == 0, 'reservation leak');
        final v = await fetchLocal(urls['video']!, range: 'bytes=-100');
        final a = await fetchLocal(urls['audio']!, range: 'bytes=-100');
        check(v.length == 100 && a.length == 100, 'reload byte count');
        for (var i = 0; i < 100; i++) {
          check(v[i] == bytes[bytes.length-100+i] && a[i] == (v[i] ^ 0x55), 'reload mixed or corrupted tracks');
        }
        opened.complete();
      };
      await opened.future.timeout(const Duration(seconds: 4));
      check(transport.snapshot()['peakProxyHandlers'] == 4, 'handler cap changed');
      check(metrics.terminalFailures == 0, 'retirement became terminal failure');
    } finally {
      c._retryTimer?.cancel(); for (final s in sockets) s.destroy();
      await transport.close(); await cdn.close();
    }
  }));
  if (failures.isNotEmpty) throw StateError(failures.join(', '));
}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${root.path}/tool/btr_tests/.dart_tool/core_package_config.json',
      fixture.path,
    ]);
    stdout.write(result.stdout);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS: reopen stops'));
  });
}
