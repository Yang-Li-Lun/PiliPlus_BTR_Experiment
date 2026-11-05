/// Captures the selected DASH representations before the upstream CDN selector
/// rewrites a host. Does not select a quality, rewrite a URL or mix audio/video.
class BtrDashSources {
  List<String> video = const [];
  List<String> audio = const [];

  String select(
    Iterable<String> urls, {
    required bool isAudio,
    required String Function(Iterable<String>, {bool isAudio}) nativeSelect,
  }) {
    if (isAudio) {
      audio = urls.toList(growable: false);
    } else {
      video = urls.toList(growable: false);
    }
    return nativeSelect(urls, isAudio: isAudio);
  }

  void clear() {
    video = const [];
    audio = const [];
  }
}
