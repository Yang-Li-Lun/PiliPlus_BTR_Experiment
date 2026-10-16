import 'dart:async';

import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/settings.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test(
    'two modes retain original bypass and migrate both retired modes',
    () {
      expect(BtrMode.values.map((m) => (m.usesThreads, m.usesSwitcher)), [
        (false, false),
        (true, true),
      ]);
      for (final mode in BtrMode.values) {
        expect(BtrMode.parse(mode.name), mode);
      }
      expect(BtrMode.parse(null), BtrMode.combined);
      expect(BtrMode.parse('threaded'), BtrMode.combined);
      expect(BtrMode.parse('switcher'), BtrMode.combined);
      expect(BtrMode.parse('original'), BtrMode.original);
    },
  );
  test(
    'one source policy preserves signed path/query and controlled fallbacks',
    () {
      const original =
          'https://origin.bilivideo.com/a/video.m4s?token=x%2Fy&flag=1';
      final spec = BtrTrackSpec(
        kind: 'audio',
        urls: [
          original,
          'https://a.mcdn.bilivideo.cn/a/video.m4s',
          'https://evil.invalid/a/video.m4s',
        ],
      );
      for (final mode in [BtrMode.combined]) {
        final sources = BtrSourcePolicy.candidates(spec, mode);
        expect(
          sources.map((s) => s.host).take(3),
          BtrSourcePolicy.switcherHosts,
        );
        expect(sources.last.toString(), original);
        expect(
          sources.every(
            (s) => s.path == '/a/video.m4s' && s.query == 'token=x%2Fy&flag=1',
          ),
          isTrue,
        );
      }
      expect(BtrSourcePolicy.candidates(spec, BtrMode.original).length, 1);
    },
  );
  for (final count in BtrSettings.threadChoices) {
    test(
      'manual $count controls real permits and keeps the resource cap',
      () async {
        final transport = BtrTransport(
          mode: BtrMode.combined,
          metrics: BtrMetrics(BtrMode.combined),
          settings: BtrSettings(autoConcurrency: false, manualThreads: count),
        );
        final scheduler = transport.scheduler;
        final effective = count.clamp(2, BtrScheduler.resourceLimit);
        expect(scheduler.limit, effective);
        final token = BtrCancel();
        final grants = <void Function()>[];
        for (var i = 0; i < effective - 1; i++) {
          grants.add(
            await scheduler.acquire(token, audio: false, priority: () => 1),
          );
        }
        final pending = scheduler.acquire(
          token,
          audio: false,
          priority: () => 1,
        );
        final observed = expectLater(pending, throwsA(isA<BtrCancelled>()));
        final audio = await scheduler.acquire(
          token,
          audio: true,
          priority: () => 1,
        );
        expect(scheduler.active, effective);
        expect(transport.snapshot()['configuredConcurrencyLimit'], count);
        transport.adaptive
          ..delivered(100000)
          ..demand(playing: true, buffering: true, ahead: 0);
        expect(scheduler.limit, effective); // Manual never auto-escalates.
        transport.adaptive.pushback();
        expect(scheduler.limit, effective ~/ 2);
        transport.adaptive.pushback();
        expect(scheduler.limit, effective ~/ 2); // Refusal batch cooldown.
        token.cancel();
        for (final release in grants) {
          release();
        }
        audio();
        await observed;
        await transport.close();
        expect(scheduler.active, 0);
        expect(scheduler.queued, 0);
      },
    );
  }
  test(
    'reject peer sources, HTTP, redirects targets, credentials and non-media',
    () {
      for (final url in [
        'http://upos.bilivideo.com/v.m4s',
        'https://127.0.0.1/v.m4s',
        'https://x.bilivideo.com.evil.invalid/v.m4s',
        'https://u:p@x.bilivideo.com/v.m4s',
        'https://x.bilivideo.com:444/v.m4s',
        'https://x.bilivideo.com/v.m4s#x',
        'https://x.bilivideo.com/v.m4s?os=mcdn',
        'https://cn-pcdn.bilivideo.cn/v.m4s',
        'https://x.bilivideo.com/api',
        'https://cn302.bilivideo.com/v.m4s',
      ]) {
        expect(BtrSourcePolicy.eligible(Uri.parse(url)), isFalse, reason: url);
      }
    },
  );
  test(
    'strong validators are origin scoped even with matching bytes and length',
    () {
      final a = Uri.parse('https://a.bilivideo.com/v.m4s');
      final identity = BtrIdentity(a, 1000, '"same"');
      expect(identity.matches(a, 1000, '"same"'), isTrue);
      expect(
        identity.matches(a.replace(host: 'b.bilivideo.com'), 1000, '"same"'),
        isFalse,
      );
      expect(identity.matches(a, 1001, '"same"'), isFalse);
      expect(BtrIdentity.strongTag('W/"same"'), isNull);
      expect(BtrIdentity.strongTag('unquoted'), isNull);
    },
  );
  test('range semantics cover closed, open, suffix and reject malformed multi-range', () {
    expect(BtrRange.request('bytes=5-15', 10)!.header, 'bytes=5-9');
    expect(BtrRange.request('bytes=5-', 10)!.header, 'bytes=5-9');
    expect(BtrRange.request('bytes=-3', 10)!.header, 'bytes=7-9');
    expect(BtrRange.request('bytes=-20', 10)!.length, 10);
    for (final value in [
      'bytes=-0',
      'bytes=-',
      'bytes=10-',
      'bytes=5-4',
      'bytes=0-1,3-4',
      'bytes=x-3',
    ]) {
      expect(BtrRange.request(value, 10), isNull);
    }
  });
  test('scheduler reserves audio, re-evaluates head priority and cancels queued work', () async {
    final gate = BtrScheduler(limit: 4);
    final token = BtrCancel();
    final slots = <void Function()>[];
    for (var i = 0; i < 3; i++) {
      slots.add(await gate.acquire(token, audio: false, priority: () => 0));
    }
    var urgency = 0;
    final order = <int>[];
    final low = gate.acquire(token, audio: false, priority: () => urgency).then(
      (v) {
        order.add(1);
        return v;
      },
    );
    final high = gate.acquire(token, audio: false, priority: () => 50).then((
      v,
    ) {
      order.add(2);
      return v;
    });
    final cancelled = BtrCancel();
    final pending = gate.acquire(cancelled, audio: false, priority: () => 1000);
    final observed = expectLater(pending, throwsA(isA<BtrCancelled>()));
    cancelled.cancel();
    final audio = await gate.acquire(token, audio: true, priority: () => 0);
    expect(gate.active, 4);
    urgency = 100;
    slots.removeLast()();
    final releaseLow = await low;
    expect(order, [1]);
    releaseLow();
    (await high)();
    audio();
    for (final release in slots) {
      release();
      release();
    }
    await observed;
    expect(gate.active, 0);
    expect(gate.queued, 0);
  });
  test(
    'adaptive trials use useful delivery, rollback and refusal cooldown',
    () {
      var now = 100000;
      final gate = BtrScheduler();
      final adaptive = BtrAdaptive(gate, clock: () => now);
      final token = BtrCancel();
      final slots = <Future<void Function()>>[];
      for (var i = 0; i < 30; i++) {
        slots.add(gate.acquire(token, audio: false, priority: () => 1));
      }
      adaptive
        ..delivered(100000)
        ..demand(playing: true, buffering: true, ahead: 0);
      expect(gate.limit, 12);
      now += 11000;
      adaptive.delivered(1);
      expect(gate.limit, 8);
      now += 3000;
      adaptive.demand(playing: true, buffering: true, ahead: 0);
      expect(gate.limit, 8);
      now += 100000;
      gate.limit = 16;
      adaptive
        ..pushback()
        ..pushback();
      expect(gate.limit, 12);
      adaptive.sample(64 * 1024, 500);
      expect(adaptive.pieceSize, 65536);
      adaptive.sample(64 * 1024 * 100, 1);
      expect(adaptive.pieceSize, 1024 * 1024);
      // Observe all pending futures before cancellation, then release granted slots.
      final drains = slots
          .map((f) => f.then((release) => release(), onError: (Object _) {}))
          .toList();
      token.cancel();
      return Future.wait(drains);
    },
  );
  test(
    'timeline metrics exclude initial/seek buffering and remain bounded',
    () {
      var now = 0;
      final metrics = BtrMetrics(BtrMode.combined, clock: () => now)
        ..buffering(true)
        ..position(0, true)
        ..buffering(false);
      now = 500;
      metrics.position(100, true);
      expect(metrics.startupMs, 500);
      metrics
        ..buffering(true)
        ..buffering(true)
        ..buffering(false);
      expect(metrics.bufferingEvents, 1);
      metrics
        ..seek(10000)
        ..buffering(true)
        ..buffering(false)
        ..position(10000, true);
      now = 900;
      metrics.position(10100, true);
      expect(metrics.seekMs.single, 400);
      expect(metrics.bufferingEvents, 1);
      for (var i = 0; i < 200; i++) {
        metrics
          ..event('fixture')
          ..delivered('video', 100);
      }
      expect(metrics.events.length, 128);
      expect(metrics.snapshot()['loopbackDeliveredBytes'], 20000);
      now = 7000;
      expect(metrics.snapshot()['loopbackDeliveredBps5s'], 0);
      expect(
        BtrMetrics(BtrMode.original).snapshot()['loopbackDeliveredBytes'],
        isNull,
      );
    },
  );
}
