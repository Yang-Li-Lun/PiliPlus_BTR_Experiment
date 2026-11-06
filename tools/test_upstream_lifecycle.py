"""Run actual integrated audio methods with deterministic native/audio-session mocks.

This checks upstream async contacts and task-removal guards, not Android playback.
Compose first; no Flutter/native plugins or real network are used.
"""
import argparse
from pathlib import Path
import re
import subprocess


def method(source, marker):
    start = source.index(marker)
    # Named arguments contain braces before the method body.
    match = re.search(r'\)\s*(?:async\s*)?\{', source[start:])
    if match is None:
        raise ValueError('Missing method body: ' + marker)
    body = start + match.start()
    opening = source.index('{', body)
    depth, end = 1, opening + 1
    while depth:
        char = source[end]
        depth += (char == '{') - (char == '}')
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='.assembled/app')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    app = root / args.output
    audio = (app / 'lib/pages/audio/controller.dart').read_text('utf-8')
    handler = (app / 'lib/services/audio_handler.dart').read_text('utf-8')
    audio_methods = '\n'.join(method(audio, x) for x in (
        'Future<void>? onPlay()', 'Future<void>? onPause()', 'Future<void> _onOpenMedia('
    )).replace('http_model.Volume', 'Volume')
    handler_methods = '\n'.join(method(handler, x) for x in (
        'Future<void> beginPlayback()', 'Future<void> _stopRemovedTask()',
        'Future<dynamic> customAction('
    ))
    fixture = r'''
import 'dart:async';
import '__SCOPE__';
class Volume {}
class Constants { static const userAgentApp = 'fixture'; }
class Media { Media(String url, {Duration? start, Object? extras}); }
class Player {
  Future<void> Function()? pending;
  int plays = 0, pauses = 0, opens = 0;
  Future<void> play() async { plays++; await pending?.call(); }
  Future<void> pause() async { pauses++; await pending?.call(); }
  Future<void> open(Media _) async { opens++; await pending?.call(); }
  void setMediaHeader({String? userAgent, Map<String, String>? headers}) {}
}
class AudioSession {
  final states = <bool>[];
  Future<void> setActive(bool value) async { states.add(value); }
}
AudioSession? audioSessionHandler;
Handler? videoPlayerServiceHandler;
class Audio {
  final _taskScope = PlaybackTaskScope();
  Player? player = Player();
  Duration? _start;
  Future<void> _initPlayerIfNeeded() async {}
  Object? audioFilterExtras(Volume? _) => null;
  __AUDIO_METHODS__
}
class Shutdown {
  Object? onPause, isPlaying;
  void reset() {}
}
final shutdownTimerService = Shutdown();
class Queue { void add(List<Object?> value) {} }
class Base { Future<void> stop() async {} }
class Handler extends Base {
  bool _taskRemoved = false;
  Future<void>? _taskRemoval;
  bool Function()? isPlaying;
  Object? onPlay, onPause, onSeek, onSkipToNext, onSkipToPrevious;
  final queue = Queue();
  bool cleared = false;
  void clear({bool force = false}) { cleared = force; }
  Future<void> onTaskRemoved() => _taskRemoval ??= _stopRemovedTask();
  __HANDLER_METHODS__
}
class PlPlayerController {
  static int lookups = 0;
  static ({String tag})? get playOwner { lookups++; return (tag: 'fixture'); }
}
class LiveRoomController {
  int actions = 0;
  void toggleDanmaku() { actions++; }
  void queryLiveUrl() { actions++; }
}
class Get {
  static final live = LiveRoomController();
  static T find<T>({String? tag}) => live as T;
}
void check(bool value, String message) {
  if (!value) throw StateError(message);
}
Future<void> main() async {
  var count = 0;
  Future<void> scenario(String name, Future<void> Function() body) async {
    await body(); count++; print('PASS: $name');
  }
  for (final playing in [true, false]) {
    for (final change in ['none', 'close', 'replace']) {
      await scenario('audio ${playing ? 'play' : 'pause'} / $change', () async {
        audioSessionHandler = AudioSession();
        final subject = Audio();
        subject.player!.pending = () async {
          if (change == 'close') await subject._taskScope.close();
          if (change == 'replace') subject.player = Player();
        };
        await (playing ? subject.onPlay() : subject.onPause());
        final states = audioSessionHandler!.states;
        check(change == 'none' ? states.length == 1 && states.single == playing : states.isEmpty,
            'stale operation changed audio focus');
        await subject._taskScope.close();
      });
    }
  }
  for (final change in ['none', 'close', 'replace']) {
    await scenario('open then play / $change', () async {
      audioSessionHandler = AudioSession();
      videoPlayerServiceHandler = Handler();
      final subject = Audio();
      final original = subject.player!;
      original.pending = () async {
        if (change == 'close') await subject._taskScope.close();
        if (change == 'replace') subject.player = Player();
      };
      await subject._onOpenMedia('https://fixture.invalid/media');
      check(original.opens == 1, 'media not opened');
      check(change == 'none' ? original.plays == 1 : original.plays == 0 && subject.player!.plays == 0,
          'stale open restarted playback');
      await subject._taskScope.close();
    });
  }
  await scenario('task removal clears new audio predicate before cleanup completes', () async {
    final handler = Handler()..isPlaying = () => true;
    final pending = Completer<Object>();
    final scope = PlaybackTaskScope();
    var released = false;
    final acquire = scope.acquire(() => pending.future, (_) async { released = true; });
    final close = handler.onTaskRemoved();
    check(handler.isPlaying == null && handler._taskRemoved, 'new callback survives removal');
    check(!handler.cleared, 'idle before pending native ownership retired');
    pending.complete(Object());
    check(await acquire == null, 'late native owner escaped cleanup');
    await close;
    check(released && handler.cleared, 'cleanup did not complete');
  });
  for (final action in ['ACTION_DM', 'ACTION_REFRESH']) {
    await scenario('notification $action stops after removal and resumes after begin', () async {
      final handler = Handler();
      await handler.onTaskRemoved();
      final before = PlPlayerController.lookups;
      await handler.customAction(action);
      check(PlPlayerController.lookups == before, 'removed task accessed live owner');
      await handler.beginPlayback();
      final actions = Get.live.actions;
      await handler.customAction(action);
      check(Get.live.actions == actions + 1, 'fresh task lost upstream action');
    });
  }
  print('$count upstream lifecycle cases passed');
}
'''.replace('__AUDIO_METHODS__', audio_methods).replace('__HANDLER_METHODS__', handler_methods).replace(
        '__SCOPE__', (app / 'lib/services/playback_task_scope.dart').as_uri())
    scratch = root / '.scratch/upstream-lifecycle'
    scratch.mkdir(parents=True, exist_ok=True)
    path = scratch / 'fixture.dart'
    path.write_text(fixture, encoding='utf-8', newline='\n')
    dart = app / '.toolchain/flutter/bin/cache/dart-sdk/bin/dart.exe'
    subprocess.run([str(dart), str(path)], check=True)


if __name__ == '__main__':
    main()
