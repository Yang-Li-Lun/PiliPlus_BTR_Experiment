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
    final fixture =
        File(
          '${root.path}/tool/btr_tests/.dart_tool/controller_recovery_fixture.dart',
        )..writeAsStringSync('''
import 'dart:async';
import 'package:PiliPlus/services/playback_seek_intent.dart';
import 'package:PiliPlus/services/playback_source_sequence.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
const kDebugMode = false;
void debugPrint(String message) {}
enum DataStatus {error}
enum Status {completed, paused, playing; bool get isCompleted => this == completed;}
class Value<T> { Value(this.value); T value; }
class FileSource {}
class Scope { bool closed = false; }
class Media { Media(this.start); final Duration start; Media copyWith({required Duration start}) => Media(start); }
class State { bool completed = true, playing = false; Duration position = Duration.zero, buffer = Duration.zero, duration = const Duration(seconds: 120); }
class NativeLock { Future<T> synchronized<T>(Future<T> Function() work) => work(); }
class Player {
  final lock = NativeLock();
  final state = State();
  final current = [Media(Duration.zero)];
  final calls = <String>[];
  final stream = (buffer: const Stream<Duration>.empty(),);
  bool isPlayingStateChangeAllowed = false, lateEof = true, failSeek = false;
  Completer<void>? stopping;
  Future<void> seek(Duration p) async {
    calls.add('seek:\${p.inSeconds}');
    if (failSeek) throw StateError('secret URL');
    state.position = p;
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
  Future<void> open(Media media, {required bool play}) async { calls.add('open:\${media.start.inSeconds}'); state.position = media.start; state.playing = play; }
}
class Transport {
  Transport(this.player); final Player player;
  bool currentSeekHasLocalFailure = false;
  Future<void> retirePlayerRequests() async { player.calls.add('retire'); }
}
typedef BtrPlayback = Session;
class Session {
  Session(Player p): transport = Transport(p);
  final Transport transport;
  final metrics = BtrMetrics(BtrMode.combined);
  void seek(Duration p) { metrics.seek(p.inMilliseconds); transport.currentSeekHasLocalFailure = false; }
}
class Subject {
  Subject() { _btrPlayback = Session(_videoPlayerController!); }
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
      c._btrPlayback!.transport.currentSeekHasLocalFailure = true;
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
    c._btrPlayback!.transport.currentSeekHasLocalFailure = true;
    (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
    final timer = c._retryTimer;
    await c.seek(const Duration(seconds: 50));
    check(timer != null && !timer.isActive, 'old recovery timer survived seek');
    check(!c._videoPlayerController!.calls.contains('stop'), 'new seek was interrupted');
  });
  await scenario('timeline recovery prevents a delayed reopen', () async {
    await runZoned(() async {
      final c = Subject(); await c.seek(const Duration(seconds: 40));
      c._btrPlayback!.transport.currentSeekHasLocalFailure = true;
      (c as dynamic)._scheduleBtrReadRecovery(c._btrPlayback!);
      c._seekIntent.position(const Duration(seconds: 40));
      c._seekIntent.position(const Duration(milliseconds: 40100));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      check(!c._videoPlayerController!.calls.contains('stop'), 'recovered playback was reopened');
    }, zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
      parent.createTimer(zone, duration == const Duration(seconds: 3) ? const Duration(milliseconds: 5) : duration, callback)));
  });
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
