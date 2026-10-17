import 'dart:async';

import 'package:PiliPlus/services/playback_seek_intent.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test(
    'BTR confirms two advancing target samples, not a load reset or EOF clock',
    () async {
      final intent = PlaybackSeekIntent()..reset(playing: true);
      await intent.seek(
        completed: false,
        target: const Duration(seconds: 40),
        perform: (_) async {},
        resume: () async {},
      );
      intent
        ..position(Duration.zero, requireProgress: true)
        ..position(const Duration(seconds: 40), requireProgress: true);
      expect(intent.pendingTarget, const Duration(seconds: 40));
      intent.position(
        const Duration(milliseconds: 40100),
        requireProgress: true,
        advancing: false,
      );
      expect(intent.pendingTarget, isNotNull);
      intent.position(
        const Duration(seconds: 120),
        requireProgress: true,
        advancing: false,
      );
      expect(intent.acceptCompleted(const Duration(seconds: 120)), false);
      intent
        ..position(const Duration(seconds: 40), requireProgress: true)
        ..position(const Duration(milliseconds: 40100), requireProgress: true);
      expect(intent.pendingTarget, isNull);
    },
  );
  test(
    'end target accepts completion while a backward target rejects stale EOF',
    () async {
      final intent = PlaybackSeekIntent();
      await intent.seek(
        completed: false,
        target: const Duration(seconds: 60),
        perform: (_) async {},
        resume: () async {},
      );
      expect(intent.acceptCompleted(const Duration(seconds: 60)), true);
      expect(intent.pendingTarget, isNull);
      await intent.seek(
        completed: true,
        target: const Duration(seconds: 20),
        perform: (_) async {},
        resume: () async {},
      );
      expect(intent.acceptCompleted(const Duration(seconds: 60)), false);
      expect(intent.pendingTarget, const Duration(seconds: 20));
    },
  );
  test('target survives command completion and reopen position reset until timeline advances', () async {
    final intent = PlaybackSeekIntent();
    await intent.seek(
      completed: false,
      target: const Duration(seconds: 40),
      perform: (_) async {},
      resume: () async {},
    );
    expect(intent.pendingTarget, const Duration(seconds: 40));
    intent.position(Duration.zero);
    expect(intent.pendingTarget, const Duration(seconds: 40));
    intent.position(const Duration(seconds: 40));
    expect(intent.pendingTarget, isNull);
    await intent.seek(
      completed: false,
      target: const Duration(seconds: 1),
      perform: (_) async {},
      resume: () async {},
    );
    intent.position(Duration.zero);
    expect(intent.pendingTarget, const Duration(seconds: 1));
    intent.reset();
    expect(intent.pendingTarget, isNull);
  });
  test(
    'pause during an autoplay source load keeps latest intent paused',
    () async {
      final intent = PlaybackSeekIntent()..reset(playing: true);
      final loaded = Completer<void>();
      var plays = 0;
      final loadingIntent = intent.revision;
      final initialize = loaded.future.then((_) {
        if (intent.playRequested) plays++;
      });
      intent.requestPlaying(false);
      loaded.complete();
      await initialize;
      expect(plays, 0);
      expect(intent.isCurrent(loadingIntent), isFalse);
    },
  );

  test(
    'play during a paused source load is honored after media opens',
    () async {
      final intent = PlaybackSeekIntent()..reset();
      final loaded = Completer<void>();
      var plays = 0;
      final initialize = loaded.future.then((_) {
        if (intent.playRequested) plays++;
      });
      intent.requestPlaying(true);
      loaded.complete();
      await initialize;
      expect(plays, 1);
      intent.reset();
      expect(intent.playRequested, isFalse);
    },
  );

  test('natural EOF seek awaits native completion before resuming', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    final nativeSeek = Completer<void>();
    final events = <String>[];
    var finished = false;
    final seek = intent
        .seek(
          completed: true,
          perform: (_) async {
            events.add('seek');
            await nativeSeek.future;
          },
          resume: () async => events.add('play'),
        )
        .then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(events, ['seek']);
    nativeSeek.complete();
    await seek;
    expect(events, ['seek', 'play']);
  });

  test('paused EOF seek preserves explicit pause', () async {
    final intent = PlaybackSeekIntent()
      ..requestPlaying(true)
      ..requestPlaying(false);
    var plays = 0;
    await intent.seek(
      completed: true,
      perform: (_) async {},
      resume: () async => plays++,
    );
    expect(plays, 0);
  });

  test('midstream playing seek does not issue redundant play', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    var plays = 0;
    await intent.seek(
      completed: false,
      perform: (_) async {},
      resume: () async => plays++,
    );
    expect(plays, 0);
  });

  test('explicit pause during native seek suppresses old EOF resume', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    final nativeSeek = Completer<void>();
    var plays = 0;
    final seek = intent.seek(
      completed: true,
      perform: (_) => nativeSeek.future,
      resume: () async => plays++,
    );
    intent.requestPlaying(false);
    nativeSeek.complete();
    await seek;
    expect(plays, 0);
  });

  test('new explicit play owns resumption instead of old seek', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    final nativeSeek = Completer<void>();
    var plays = 0;
    final seek = intent.seek(
      completed: true,
      perform: (_) => nativeSeek.future,
      resume: () async => plays++,
    );
    final currentPlay = intent.requestPlaying(true);
    nativeSeek.complete();
    await seek;
    expect(plays, 0);
    expect(intent.isCurrent(currentPlay), isTrue);
    intent.requestPlaying(false);
    expect(intent.isCurrent(currentPlay), isFalse);
  });

  test(
    'newest seek inherits pending EOF resume after completed clears',
    () async {
      final intent = PlaybackSeekIntent()..requestPlaying(true);
      final firstNative = Completer<void>();
      final nextNative = Completer<void>();
      final resumes = <String>[];
      final first = intent.seek(
        completed: true,
        perform: (_) => firstNative.future,
        resume: () async => resumes.add('old'),
      );
      final next = intent.seek(
        completed: false,
        perform: (_) => nextNative.future,
        resume: () async => resumes.add('new'),
      );
      firstNative.complete();
      expect(await first, isFalse);
      expect(resumes, isEmpty);
      nextNative.complete();
      expect(await next, isTrue);
      expect(resumes, ['new']);
    },
  );

  test('source reset cancels pending EOF seek and its resume', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    final nativeSeek = Completer<void>();
    var plays = 0;
    final seek = intent.seek(
      completed: true,
      perform: (_) => nativeSeek.future,
      resume: () async => plays++,
    );
    intent.reset();
    nativeSeek.complete();
    expect(await seek, isFalse);
    expect(plays, 0);
    await intent.seek(
      completed: true,
      perform: (_) async {},
      resume: () async => plays++,
    );
    expect(plays, 0);
  });

  test('superseded pre-seek wait cannot issue an old native seek', () async {
    final intent = PlaybackSeekIntent();
    final buffer = Completer<void>();
    final positions = <int>[];
    final old = intent.seek(
      completed: false,
      perform: (isCurrent) async {
        await buffer.future;
        if (isCurrent()) positions.add(10);
      },
      resume: () async {},
    );
    await intent.seek(
      completed: false,
      perform: (_) async => positions.add(20),
      resume: () async {},
    );
    buffer.complete();
    expect(await old, isFalse);
    expect(positions, [20]);
  });

  test(
    'source change while native seek completes cannot resume new media',
    () async {
      final intent = PlaybackSeekIntent()..requestPlaying(true);
      final nativeSeek = Completer<void>();
      var sourceIsCurrent = true;
      var plays = 0;
      final seek = intent.seek(
        completed: true,
        isCurrentSource: () => sourceIsCurrent,
        perform: (_) => nativeSeek.future,
        resume: () async => plays++,
      );
      sourceIsCurrent = false;
      nativeSeek.complete();
      expect(await seek, isFalse);
      expect(plays, 0);
    },
  );

  test('native seek failure is reported without automatic play', () async {
    final intent = PlaybackSeekIntent()..requestPlaying(true);
    var plays = 0;
    await expectLater(
      intent.seek(
        completed: true,
        perform: (_) async => throw StateError('seek rejected'),
        resume: () async => plays++,
      ),
      throwsStateError,
    );
    expect(plays, 0);
    await intent.seek(
      completed: false,
      perform: (_) async {},
      resume: () async => plays++,
    );
    expect(plays, 1);
  });
}
