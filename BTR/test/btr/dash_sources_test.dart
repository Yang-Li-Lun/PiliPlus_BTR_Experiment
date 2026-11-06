import 'package:PiliPlus/services/btr/dash_sources.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('captures signed representations before native CDN rewriting', () {
    final sources = BtrDashSources();
    final video = ['https://origin.bilivideo.com/video?sign=a%2Fb'];
    final audio = ['https://origin.bilivideo.com/audio?sign=c%2Fd'];
    final calls = <bool>[];
    String native(Iterable<String> urls, {bool isAudio = false}) {
      calls.add(isAudio);
      return isAudio ? 'native-audio' : 'native-video';
    }

    expect(
      sources.select(video, isAudio: false, nativeSelect: native),
      'native-video',
    );
    expect(
      sources.select(audio, isAudio: true, nativeSelect: native),
      'native-audio',
    );
    video.clear();
    audio.clear();
    expect(
      sources.video.single,
      'https://origin.bilivideo.com/video?sign=a%2Fb',
    );
    expect(
      sources.audio.single,
      'https://origin.bilivideo.com/audio?sign=c%2Fd',
    );
    expect(calls, [false, true]);
    sources.clear();
    expect(sources.video, isEmpty);
    expect(sources.audio, isEmpty);
  });
}
