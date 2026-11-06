import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr/network.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';

typedef FixtureHandler = Future<bool> Function(HttpRequest, BtrRange, int);

class FakeCdn {
  FakeCdn(this.bytes);
  final Uint8List bytes;
  Uint8List? audioBytes;
  late HttpServer server;
  final requests = <(String, BtrRange, String?)>[];
  FixtureHandler? handler;
  String? etag = '"fixture-v1"';
  int active = 0;
  int peak = 0;
  final tasks = <Future<void>>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final task = _serve(request);
      tasks.add(task);
      unawaited(task.then((_) => tasks.remove(task)));
    });
  }

  Future<void> _serve(HttpRequest r) async {
    final payload = r.uri.path.endsWith('/audio.m4s')
        ? audioBytes ?? bytes
        : bytes;
    active++;
    if (active > peak) peak = active;
    final range = BtrRange.request(r.headers.value('range'), payload.length)!;
    requests.add((r.uri.path, range, r.headers.value('if-range')));
    final number = requests.length;
    try {
      if (await handler?.call(r, range, number) == true) return;
      r.response.statusCode = 206;
      r.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/${payload.length}',
      );
      if (etag != null) r.response.headers.set('etag', etag!);
      r.response.contentLength = range.length;
      r.response.add(
        Uint8List.sublistView(payload, range.start, range.end + 1),
      );
      await r.response.close();
    } catch (_) {
      /* expected peer cancellation */
    } finally {
      active--;
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await Future.wait(tasks.toList());
  }
}

/// Only this fixture adapter remaps production-looking candidates to loopback.
/// No test request may reach DNS/the public network.
class FakeNetwork extends BtrNetwork {
  FakeNetwork(
    super.scheduler,
    super.metrics,
    this.cdn, {
    super.stallTimeout = const Duration(milliseconds: 150),
    super.attemptTimeout = const Duration(seconds: 2),
  });
  final FakeCdn cdn;
  @override
  Future<BtrHttpLease> open(
    Uri uri,
    BtrRange range,
    BtrCancel token, {
    required bool audio,
    required int Function() priority,
    String? etag,
    void Function()? onStarted,
  }) {
    final mapped = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: cdn.server.port,
      path: '/${uri.host}${uri.path}',
    );
    return super.open(
      mapped,
      range,
      token,
      audio: audio,
      priority: priority,
      etag: etag,
      onStarted: onStarted,
    );
  }
}

Future<Uint8List> fetchLocal(
  String url, {
  String? range,
  Map<String, String>? headers,
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    headers?.forEach(req.headers.set);
    final response = await req.close();
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw BtrFailure('local-status', response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final data in response) {
      bytes.add(data);
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}
