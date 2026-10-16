import 'dart:async';

import 'package:PiliPlus/services/playback_task_scope.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  tearDown(PlaybackTaskScope.closeAll);

  test(
    'owner disposal only closes that owner; task removal closes all',
    () async {
      var videoStops = 0;
      var audioStops = 0;
      final video = PlaybackTaskScope(onClose: () => videoStops++);
      final audio = PlaybackTaskScope(onClose: () => audioStops++);
      expect(videoStops, 0);
      expect(audioStops, 0);
      await video.close();
      expect(audio.closed, isFalse);
      await PlaybackTaskScope.closeAll();
      expect(videoStops, 1);
      expect(audioStops, 1);
    },
  );

  test(
    'duplicate shutdown shares completion and releases each resource once',
    () async {
      final scope = PlaybackTaskScope();
      final release = Completer<void>();
      var released = 0;
      final resource = await scope.acquire(() async => Object(), (_) {
        released++;
        return release.future;
      });
      final first = scope.close();
      expect(identical(first, scope.close()), isTrue);
      expect(scope.closed, isTrue);
      var finished = false;
      final all = PlaybackTaskScope.closeAll().then((_) => finished = true);
      await scope.release(resource!);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(released, 1);
      release.complete();
      await Future.wait([first, all]);
      expect(released, 1);
    },
  );

  test(
    'task removal waits for late initialization and native disposal',
    () async {
      final scope = PlaybackTaskScope();
      final created = Completer<Object>();
      final released = Completer<void>();
      var releaseCalls = 0;
      final player = scope.acquire(() => created.future, (_) {
        releaseCalls++;
        return released.future;
      });
      var finished = false;
      final closing = PlaybackTaskScope.closeAll().then((_) => finished = true);
      created.complete(Object());
      await Future<void>.delayed(Duration.zero);
      expect(releaseCalls, 1);
      expect(finished, isFalse);
      released.complete();
      expect(await player, isNull);
      await closing;
      expect(finished, isTrue);
      var restarted = false;
      expect(
        await scope.acquire(() async {
          restarted = true;
          return Object();
        }, (_) async {}),
        isNull,
      );
      expect(restarted, isFalse);
    },
  );

  test('one failing owner does not prevent other player cleanup', () async {
    PlaybackTaskScope(onClose: () => throw StateError('fixture'));
    var stopped = false;
    final other = PlaybackTaskScope(onClose: () => stopped = true);
    var released = false;
    await other.acquire(() async => Object(), (_) async => released = true);
    await expectLater(PlaybackTaskScope.closeAll(), throwsStateError);
    expect(stopped, isTrue);
    expect(released, isTrue);
  });

  test(
    'failed initialization during removal settles without a leaked owner',
    () async {
      final scope = PlaybackTaskScope();
      final created = Completer<Object>();
      final player = scope.acquire(() => created.future, (_) async {});
      final expectation = expectLater(player, throwsStateError);
      final closing = scope.close();
      created.completeError(StateError('creation failed'));
      await expectation;
      await closing;
    },
  );

  test(
    'failure disposing a late player is reported after other cleanup',
    () async {
      final scope = PlaybackTaskScope();
      final created = Completer<Object>();
      final player = scope.acquire(
        () => created.future,
        (_) => Future.error(StateError('disposal failed')),
      );
      final expectation = expectLater(scope.close(), throwsStateError);
      created.complete(Object());
      expect(await player, isNull);
      await expectation;
    },
  );

  test(
    'fresh playback in the same process can start after task removal',
    () async {
      final previous = PlaybackTaskScope();
      await PlaybackTaskScope.closeAll();
      final fresh = PlaybackTaskScope();
      expect(
        await fresh.acquire(() async => Object(), (_) async {}),
        isNotNull,
      );
      expect(previous.closed, isTrue);
      expect(fresh.closed, isFalse);
    },
  );
}
