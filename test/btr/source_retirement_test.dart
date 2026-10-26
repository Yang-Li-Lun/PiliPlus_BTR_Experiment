import 'dart:io';

import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('actual source transition preserves GET ownership until native stop', () async {
    final root = Directory.current.path.endsWith('btr_tests')
        ? Directory.current.parent.parent
        : Directory.current;
    final source = File(
      Platform.environment['BTR_CONTROLLER_SOURCE'] ??
          '${root.path}/lib/plugin/pl_player/controller.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<bool> _createVideoController(');
    final end = source.indexOf('final (session, preparedSource)', start);
    expect(start >= 0 && end > start, isTrue);
    final prefix = source.substring(start, end);
    final fixture =
        File(
          '${root.path}/tool/btr_tests/.dart_tool/source_retirement_fixture.dart',
        )..writeAsStringSync('''
import 'dart:async';
class DataSource {}
class Volume {}
class Scope { bool closed = false; }
class Session {
  Session(this.calls, {this.transport = const Object()});
  final List<String> calls;
  final Object? transport;
  int closes = 0;
  Future<void> close() async { closes++; calls.add('close'); }
}
class Player {
  Player(this.calls);
  final List<String> calls;
  Future<void> Function()? onStop;
  Future<void> stop() async {
    calls.add('stop-start');
    await onStop?.call();
    calls.add('stop-end');
  }
}
class Subject {
  final calls = <String>[];
  late Player? _videoPlayerController = Player(calls);
  late Session? _btrPlayback = Session(calls);
  final _taskScope = Scope();
  int _btrOpenGeneration = 0;
  $prefix
    return true;
  }
  Future<bool> run([bool Function()? current]) =>
      _createVideoController(DataSource(), null, null, current ?? () => true);
}
void check(bool ok, String why) { if (!ok) throw StateError(why); }
Future<void> main() async {
  final failures = <String>[];
  Future<void> scenario(String name, Future<void> Function() body) async {
    try { await body(); print('PASS: \$name'); }
    catch(e) { failures.add(name); print('FAIL: \$name: \$e'); }
  }
  await scenario('stop completes before proxy closes', () async {
    final c = Subject(); final old = c._btrPlayback;
    final entered = Completer<void>(), gate = Completer<void>();
    c._videoPlayerController!.onStop = () { entered.complete(); return gate.future; };
    final work = c.run();
    await Future<void>.delayed(Duration.zero);
    check(entered.isCompleted, 'native stop not started');
    check(old!.closes == 0 && identical(c._btrPlayback, old), 'GET owner closed while stop pending');
    gate.complete();
    check(await work, 'source transition rejected');
    check(c.calls.join(',') == 'stop-start,stop-end,close', 'wrong ownership order');
  });
  await scenario('failed stop retains old response owner', () async {
    final c = Subject(); final old = c._btrPlayback;
    c._videoPlayerController!.onStop = () async { throw StateError('stop failed'); };
    var failed = false;
    try { await c.run(); } catch(_) { failed = true; }
    check(failed && old!.closes == 0 && identical(c._btrPlayback, old), 'failed stop released valid GETs');
  });
  await scenario('superseded source closes only after stop and cannot prepare', () async {
    final c = Subject(); var current = true;
    c._videoPlayerController!.onStop = () async { current = false; };
    check(!await c.run(() => current), 'stale source prepared');
    check(c.calls.join(',') == 'stop-start,stop-end,close', 'stale source released early');
  });
  await scenario('task close during stop cannot prepare new source', () async {
    final c = Subject();
    c._videoPlayerController!.onStop = () async { c._taskScope.closed = true; };
    check(!await c.run(), 'closed task prepared new source');
    check(c.calls.join(',') == 'stop-start,stop-end,close', 'close raced ownership');
  });
  await scenario('first source does not stop player', () async {
    final c = Subject().._btrPlayback = null;
    check(await c.run(), 'first source rejected');
    check(c.calls.isEmpty, 'first source stopped player');
  });
  await scenario('original mode keeps native source path', () async {
    final c = Subject(); c._btrPlayback = Session(c.calls, transport: null);
    check(await c.run(), 'original mode rejected');
    check(c.calls.join(',') == 'close', 'original mode gained BTR stop');
  });
  if(failures.isNotEmpty) throw StateError('\${failures.length} contract failures');
}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${root.path}/tool/btr_tests/.dart_tool/core_package_config.json',
      fixture.path,
    ], workingDirectory: root.path);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    expect(result.exitCode, 0, reason: 'actual source transition contract');
  });
}
