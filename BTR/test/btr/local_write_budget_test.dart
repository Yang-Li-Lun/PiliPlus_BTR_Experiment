import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/btr/local_write_budget.dart';
import 'package:PiliPlus/services/btr/metrics.dart';
import 'package:PiliPlus/services/btr/policy.dart';
import 'package:PiliPlus/services/btr/proxy_capacity.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
import 'package:PiliPlus/services/btr/transport.dart';
import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

void main() {
  test('native cache wall time has a finite local write budget', () {
    expect(BtrLocalWriteBudget.forNativeCache(), const Duration(seconds: 15));
    expect(
      BtrLocalWriteBudget.forNativeCache(cacheSeconds: 60),
      const Duration(seconds: 75),
    );
    expect(
      BtrLocalWriteBudget.forNativeCache(cacheSeconds: 16),
      const Duration(seconds: 31),
    );
    expect(
      BtrLocalWriteBudget.forNativeCache(cacheSeconds: 15, playbackRate: .25),
      const Duration(seconds: 75),
    );
    expect(
      BtrLocalWriteBudget.forNativeCache(cacheSeconds: 120, playbackRate: 2),
      const Duration(seconds: 75),
    );
    expect(
      BtrLocalWriteBudget.forNativeCache(cacheSeconds: .125),
      const Duration(milliseconds: 15125),
    );
  });

  test(
    'invalid cache inputs fail bounded and extreme valid inputs saturate',
    () {
      for (final seconds in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          BtrLocalWriteBudget.forNativeCache(cacheSeconds: seconds),
          BtrLocalWriteBudget.base,
        );
      }
      for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          BtrLocalWriteBudget.forNativeCache(
            cacheSeconds: 60,
            playbackRate: rate,
          ),
          BtrLocalWriteBudget.base,
        );
      }
      expect(
        BtrLocalWriteBudget.forNativeCache(cacheSeconds: 3600),
        BtrLocalWriteBudget.maximum,
      );
      expect(
        BtrLocalWriteBudget.forNativeCache(
          cacheSeconds: double.maxFinite,
          playbackRate: double.minPositive,
        ),
        BtrLocalWriteBudget.maximum,
      );
    },
  );

  test(
    'transport exposes the actual bounded timeout and rejects invalid values',
    () async {
      for (final timeout in [
        Duration.zero,
        const Duration(seconds: -1),
      const Duration(seconds: 76),
        const Duration(seconds: 301),
      ]) {
        expect(
          () => BtrTransport(
            mode: BtrMode.combined,
            metrics: BtrMetrics(BtrMode.combined),
            localWriteIdleTimeout: timeout,
          ),
          throwsArgumentError,
        );
      }
      final transport = BtrTransport(
        mode: BtrMode.combined,
        metrics: BtrMetrics(BtrMode.combined),
        localWriteIdleTimeout: BtrLocalWriteBudget.forNativeCache(
          cacheSeconds: 60,
        ),
      );
      expect(transport.snapshot()['localWriteIdleTimeoutMs'], 75000);
      expect(transport.snapshot()['proxyResponseLimit'], 8);
      expect(transport.snapshot()['proxyHandlerLimit'], 4);
      expect(transport.snapshot()['resourceConcurrencyLimit'], 16);
      await transport.close();
    },
  );

  test('a valid writer survives a real 20-second cache pause with ownership intact', () async {
    final capacity = BtrProxyCapacity();
    final legacy = capacity.admit()!, current = capacity.admit()!;
    final oldToken = BtrCancel(), token = BtrCancel();
    await legacy.acquire(oldToken);
    await current.acquire(token);
    final draining = Completer<void>();
    Object? legacyError;
    final old = legacy
        .flush(draining.future, oldToken, onBlocked: () {})
        .then<void>(
          (_) {},
          onError: (Object error) {
            legacyError = error;
            legacy.close();
          },
        );
    var completed = false;
    final pending = current
        .flush(
          draining.future,
          token,
          idleTimeout: BtrLocalWriteBudget.forNativeCache(cacheSeconds: 60),
          onBlocked: () {},
        )
        .then<void>((_) {
          completed = true;
        });
    await Future<void>.delayed(const Duration(seconds: 20));
    expect(legacyError, isA<TimeoutException>());
    expect(completed, false);
    expect(token.cancelled, false);
    expect(capacity.responses, 1);
    expect(capacity.active, 0);
    expect(capacity.parked, 1);
    final others = List.generate(7, (_) => capacity.admit()!);
    expect(capacity.admit(), isNull);
    draining.complete();
    await Future.wait([old, pending]);
    await current.acquire(token);
    current.close();
    for (final slot in others) {
      slot.close();
    }
    expect(capacity.responses, 0);
    expect(capacity.active, 0);
    expect(capacity.parked, 0);
  });

  test(
    'a truly stalled local write still reaches its finite deadline',
    () async {
      final capacity = BtrProxyCapacity();
      final slot = capacity.admit()!, token = BtrCancel();
      await slot.acquire(token);
      final draining = Completer<void>();
      await expectLater(
        slot.flush(
          draining.future,
          token,
          idleTimeout: const Duration(milliseconds: 300),
          onBlocked: () {},
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(capacity.parked, 0);
      slot.close();
      draining.complete();
      expect(capacity.responses, 0);
      expect(capacity.active, 0);
    },
  );

  test('retired writers cancel deadline timers and do not retain the process', () async {
    final root = Directory.current.path.endsWith('btr_tests')
        ? Directory.current.parent.parent
        : Directory.current;
    final fixture =
        File(
          '${root.path}/tool/btr_tests/.dart_tool/local_write_cancel_fixture.dart',
        )..writeAsStringSync('''
import 'dart:async';
import 'package:PiliPlus/services/btr/proxy_capacity.dart';
import 'package:PiliPlus/services/btr/scheduler.dart';
Future<void> main() async {
  final capacity = BtrProxyCapacity();
  final slot = capacity.admit()!, token = BtrCancel();
  await slot.acquire(token);
  final never = Completer<void>();
  var cancelled = false;
  final pending = slot.flush(never.future, token,
      idleTimeout: const Duration(seconds: 75), onBlocked: () {}).then<void>(
      (_) {}, onError: (Object error) {
        if (error is! BtrCancelled) throw error;
        cancelled = true;
      });
  Timer(const Duration(milliseconds: 150), token.cancel);
  await pending;
  slot.close();
  if (!cancelled || capacity.responses != 0 || capacity.active != 0 || capacity.parked != 0) {
    throw StateError('retirement did not release capacity');
  }
  print('cancelled=true responses=0 active=0 parked=0');
  // The native flush stays unresolved: only a leaked deadline keeps Dart alive.
}
''');
    final child = await Process.start(Platform.resolvedExecutable, [
      '--packages=${root.path}/tool/btr_tests/.dart_tool/core_package_config.json',
      fixture.path,
    ], workingDirectory: root.path);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      final code = await child.exitCode.timeout(const Duration(seconds: 8));
      expect(code, 0, reason: await errors);
      expect(
        await output,
        contains('cancelled=true responses=0 active=0 parked=0'),
      );
    } finally {
      child.kill();
    }
  });
}
