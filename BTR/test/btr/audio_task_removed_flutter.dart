import 'dart:async';

import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/playback_task_scope.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final backgroundPlay in [true, false]) {
    test(
      'onTaskRemoved stops all owners with backgroundPlay=$backgroundPlay',
      () async {
        final handler = VideoPlayerServiceHandler(
          enableBackgroundPlay: backgroundPlay,
        );
        var releases = 0;
        final scope = PlaybackTaskScope();
        await scope.acquire(() async => Object(), (_) async => releases++);
        handler.playbackState.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: true,
            controls: [MediaControl.pause],
          ),
        );
        handler.mediaItem.add(const MediaItem(id: 'fixture', title: 'fixture'));
        handler.queue.add([const MediaItem(id: 'fixture', title: 'fixture')]);
        await Future.wait([handler.onTaskRemoved(), handler.onTaskRemoved()]);
        expect(releases, 1);
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.idle,
        );
        expect(handler.playbackState.value.playing, isFalse);
        expect(handler.playbackState.value.controls, isEmpty);
        expect(handler.queue.value, isEmpty);
        expect(handler.mediaItem.value, isNull);
        var played = false;
        handler.onPlay = () async => played = true;
        await handler.play();
        expect(played, isFalse);
        await handler.beginPlayback();
        await handler.play();
        expect(played, isTrue);
      },
    );
  }

  test(
    'onTaskRemoved awaits pending player creation before final idle',
    () async {
      final handler = VideoPlayerServiceHandler(enableBackgroundPlay: false);
      final scope = PlaybackTaskScope();
      final created = Completer<Object>();
      var released = false;
      final player = scope.acquire(
        () => created.future,
        (_) async => released = true,
      );
      var stopped = false;
      final removal = handler.onTaskRemoved().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      created.complete(Object());
      expect(await player, isNull);
      await removal;
      expect(released, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    },
  );
}
