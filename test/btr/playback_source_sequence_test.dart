import 'dart:async';

import 'package:PiliPlus/services/playback_seek_intent.dart';
import 'package:PiliPlus/services/playback_source_sequence.dart';
import 'package:PiliPlus/services/playback_task_scope.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  tearDown(PlaybackTaskScope.closeAll);

  test(
    'a superseded native creation settles before the next source starts',
    () async {
      final sequence = PlaybackSourceSequence();
      final scope = PlaybackTaskScope();
      final creation = Completer<Object>();
      final started = Completer<void>();
      final released = Completer<void>();
      var firstReleased = false;
      var secondStarted = false;
      final openedTracks = <String>[];

      final first = sequence.run((isCurrent) async {
        final player = await scope.acquire(
          () {
            started.complete();
            return creation.future;
          },
          (_) async {
            await released.future;
            firstReleased = true;
          },
        );
        if (!isCurrent()) {
          await scope.release(player!);
          return;
        }
        openedTracks.addAll(['old-video', 'old-audio']);
      });
      await started.future;
      final second = sequence.run((isCurrent) async {
        secondStarted = true;
        expect(firstReleased, isTrue);
        expect(isCurrent(), isTrue);
        openedTracks.addAll(['new-video', 'new-audio']);
      });
      creation.complete(Object());
      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, isFalse);
      expect(openedTracks, isEmpty);
      released.complete();
      await Future.wait([first, second]);
      expect(openedTracks, ['new-video', 'new-audio']);
    },
  );

  test('only the latest queued audio/video selection opens', () async {
    final sequence = PlaybackSourceSequence();
    final pending = Completer<void>();
    final started = Completer<void>();
    final opened = <String>[];
    final first = sequence.run((isCurrent) async {
      started.complete();
      await pending.future;
      if (isCurrent()) opened.add('first');
    });
    await started.future;
    final middle = sequence.run((_) async => opened.add('middle'));
    final last = sequence.run((_) async => opened.add('latest'));
    pending.complete();
    await Future.wait([first, middle, last]);
    expect(opened, ['latest']);
  });

  test(
    'old terminal cleanup cannot overwrite queued source play intent',
    () async {
      final sequence = PlaybackSourceSequence();
      final intent = PlaybackSeekIntent()..reset(playing: true);
      final terminal = Completer<void>();
      final started = Completer<void>();
      var cleaned = false;
      var newestPlayed = false;
      final first = sequence.run((isCurrent) async {
        started.complete();
        await terminal.future;
        if (isCurrent()) intent.requestPlaying(false);
        cleaned = true;
      });
      await started.future;
      intent.reset(playing: true);
      final next = sequence.run((_) async {
        expect(cleaned, isTrue);
        newestPlayed = intent.playRequested;
      });
      terminal.complete();
      await Future.wait([first, next]);
      expect(newestPlayed, isTrue);
    },
  );

  test('source replacement waits for an in-flight native open', () async {
    final sequence = PlaybackSourceSequence();
    final nativeOpen = Completer<void>();
    final started = Completer<void>();
    var oldAudioClosed = false;
    final first = sequence.run((isCurrent) async {
      started.complete();
      await nativeOpen.future;
      expect(oldAudioClosed, isFalse);
      expect(isCurrent(), isFalse);
    });
    await started.future;
    final second = sequence.run((_) async => oldAudioClosed = true);
    await Future<void>.delayed(Duration.zero);
    expect(oldAudioClosed, isFalse);
    nativeOpen.complete();
    await Future.wait([first, second]);
    expect(oldAudioClosed, isTrue);
  });

  test(
    'a failed source open does not poison the next explicit selection',
    () async {
      final sequence = PlaybackSourceSequence();
      final started = Completer<void>();
      final failed = Completer<void>();
      final first = sequence.run((_) async {
        started.complete();
        await failed.future;
      });
      final expectation = expectLater(first, throwsStateError);
      await started.future;
      var opened = false;
      final second = sequence.run((_) async => opened = true);
      failed.completeError(StateError('fixture open failed'));
      await expectation;
      await second;
      expect(opened, isTrue);
    },
  );

  test(
    'task removal during a queued source never acquires another player',
    () async {
      final sequence = PlaybackSourceSequence();
      final scope = PlaybackTaskScope();
      final created = Completer<Object>();
      final started = Completer<void>();
      var acquired = 0;
      var disposed = 0;
      final first = sequence.run((isCurrent) async {
        await scope.acquire(() {
          acquired++;
          started.complete();
          return created.future;
        }, (_) async => disposed++);
      });
      await started.future;
      final second = sequence.run((_) async {
        if (scope.closed) return;
        await scope.acquire(() async {
          acquired++;
          return Object();
        }, (_) async => disposed++);
      });
      final closing = scope.close();
      created.complete(Object());
      await Future.wait([first, second, closing]);
      expect(acquired, 1);
      expect(disposed, 1);
    },
  );
}
