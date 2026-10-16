import 'dart:io';

enum BtrMode {
  original('原始 PiliPlus'),
  combined('BTR 整合加速');

  const BtrMode(this.label);
  final String label;
  bool get usesThreads => this == BtrMode.combined;
  bool get usesSwitcher => this == BtrMode.combined;

  static BtrMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => combined,
  );
}

/// One representation selected by the existing player. Never combine tracks.
class BtrTrackSpec {
  BtrTrackSpec({required this.kind, required Iterable<String> urls})
    : urls = List.unmodifiable(urls);
  final String kind;
  final List<String> urls;
}

/// Fresh implementation from the supplied Switcher's *behavior*, not its code.
/// No arbitrary host, IP, userinfo, redirect or peer-CDN signed URL forwarding.
class BtrSourcePolicy {
  static const preferred = 'upos-sz-mirroraliov.bilivideo.com';
  static const switcherHosts = [
    preferred,
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];
  // Attachment 2026.10.8.1 mainland resolver, bounded to eight candidates.
  static const btrHosts = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];

  static bool eligible(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port != 443 ||
        InternetAddress.tryParse(uri.host) != null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (!(host.endsWith('.bilivideo.com') ||
        host.endsWith('.bilivideo.cn') ||
        host.endsWith('.bilivideo.net') ||
        host.endsWith('.akamaized.net'))) {
      return false;
    }
    if (host.split('.').contains('mcdn') ||
        host.contains('pcdn') ||
        host.contains('p2p') ||
        host.contains('bcache') ||
        host.split('.').first.contains('302') ||
        uri.queryParameters['os'] == 'mcdn' ||
        uri.queryParameters['os'] == 'pcdn') {
      return false;
    }
    return RegExp(r'\.(m4s|mp4)$', caseSensitive: false).hasMatch(uri.path);
  }

  static List<Uri> candidates(
    BtrTrackSpec spec,
    BtrMode mode, {
    String? preferredHost,
  }) {
    final originals = spec.urls
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where(eligible)
        .toSet()
        .toList();
    if (mode == BtrMode.original || originals.isEmpty) return originals;
    final donor = originals.firstWhere(
      (u) => !u.host.endsWith('.akamaized.net'),
      orElse: () => originals.first,
    );
    // A preference only reorders the existing admissible pool. It cannot add a
    // host, bypass eligibility, or authorize cross-origin composition.
    final hosts = [
      if (switcherHosts.contains(preferredHost)) preferredHost!,
      ...switcherHosts.where((h) => h != preferredHost),
    ];
    final synthetic = hosts.map((h) => donor.replace(host: h, port: 443));
    // Selection happens once here; no subsequent VideoUtils URL rewrite.
    return <Uri>{
      ...synthetic,
      ...originals,
    }.take(12).toList();
  }
}

class BtrFailure implements Exception {
  const BtrFailure(this.code, [this.status]);
  final String code;
  final int? status;
  @override
  String toString() => 'BTR $code${status == null ? '' : ' ($status)'}';
}

class BtrRange {
  const BtrRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
  String get header => 'bytes=$start-$end';

  static BtrRange? request(String? header, int total) {
    if (header == null) return BtrRange(0, total - 1);
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (m == null || total <= 0) return null;
    final a = int.tryParse(m[1]!);
    final b = int.tryParse(m[2]!);
    if (a == null) {
      if (m[1]!.isNotEmpty || b == null || b <= 0) return null;
      return BtrRange(b >= total ? 0 : total - b, total - 1);
    }
    if (a >= total || (m[2]!.isNotEmpty && b == null) || (b != null && b < a)) {
      return null;
    }
    return BtrRange(a, b == null || b >= total ? total - 1 : b);
  }
}

class BtrIdentity {
  const BtrIdentity(this.uri, this.total, this.etag);
  final Uri uri;
  final int total;
  final String? etag;
  bool get canSegment => etag != null;

  static String? strongTag(String? value) =>
      value != null && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value)
      ? value
      : null;

  /// ETags are origin-scoped. Equal length, sample bytes and even identical
  /// strong ETag strings are NOT cross-origin identity proofs.
  bool matches(Uri actual, int length, String? tag) =>
      actual == uri && length == total && etag != null && tag == etag;
}
