// ignore_for_file: avoid_print

import 'dart:async';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 30);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  Future<void> waitForState<T extends ConnectionState>(
    SpacetimeDbConnection connection, {
    Duration timeout = _timeout,
  }) async {
    if (connection.state is T) return;
    await connection.onStateChanged
        .firstWhere((state) => state is T)
        .timeout(
          timeout,
          onTimeout:
              () => throw TimeoutException('Timed out waiting for state $T'),
        );
  }

  Future<void> waitForCount(
    TestEnv env,
    int expected, {
    Duration timeout = _timeout,
  }) async {
    final sw = Stopwatch()..start();
    while (env.entityTable.count() < expected) {
      if (sw.elapsed > timeout) {
        throw TimeoutException(
          'entity count reached ${env.entityTable.count()}, expected $expected',
        );
      }
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<(TestEnv, int, int)> seedEntities(int count) async {
    final writer = await createTestEnv(registerEntity: true);
    await writer.connection.connect();
    await writer.subManager.onInitialConnection.first.timeout(_timeout);
    await writer.subManager
        .subscribe(['SELECT * FROM entity'])
        .timeout(_timeout);
    final priorMax = writer.entityTable
        .iter()
        .map((e) => e.id.toInt())
        .fold<int>(0, (a, b) => a > b ? a : b);
    var remaining = count;
    const batch = 5000;
    while (remaining > 0) {
      final n = remaining < batch ? remaining : batch;
      await writer.reducers.bulkInsertEntities(count: n).timeout(_timeout);
      remaining -= n;
    }
    return (writer, priorMax + 1, priorMax + count);
  }

  Future<void> runScale(int tableSize) async {
    final (writer, baseId, maxId) = await seedEntities(tableSize);

    final env = await createTestEnv(registerEntity: true);
    addTearDown(() async {
      writer.subManager.dispose();
      env.subManager.dispose();
      await writer.disconnect();
      await env.disconnect();
    });

    await env.connection.connect();
    await env.subManager.onInitialConnection.first.timeout(_timeout);

    final mid = baseId + (maxId - baseId) ~/ 2;
    final overlapLo = mid - (tableSize ~/ 10);
    final overlapHi = mid + (tableSize ~/ 10);

    final subSw = Stopwatch()..start();
    await env.subManager.subscribe([
      'SELECT * FROM entity WHERE id >= $baseId AND id <= $overlapHi',
    ]);
    await env.subManager.subscribe([
      'SELECT * FROM entity WHERE id >= $overlapLo AND id <= $maxId',
    ]);
    subSw.stop();

    final initialCount = env.entityTable.count();
    expect(
      initialCount,
      tableSize,
      reason: 'union of the two overlapping ranges must cover every seeded row',
    );

    await env.connection.disconnect();
    await waitForState<Disconnected>(env.connection);

    final reconnectSw = Stopwatch()..start();
    await env.connection.reconnect();
    await waitForState<Connected>(env.connection);
    await waitForCount(env, tableSize);
    reconnectSw.stop();

    expect(
      env.entityTable.count(),
      tableSize,
      reason:
          'every row must rehydrate after reconnect with no cross-set clobber '
          '(table=$tableSize)',
    );

    final perRowUs = reconnectSw.elapsedMicroseconds / tableSize;
    print(
      'SCALE table=$tableSize | 2x subscribe=${subSw.elapsedMilliseconds}ms | '
      'reconnect+rehydrate=${reconnectSw.elapsedMilliseconds}ms '
      '(${perRowUs.toStringAsFixed(1)}us/row)',
    );

    expect(
      reconnectSw.elapsed.inSeconds,
      lessThan(_timeout.inSeconds),
      reason: 'reconnect resync must complete well within the timeout at scale',
    );
  }

  group('Shared-table overlap at scale', () {
    test('1k rows', () => runScale(1000), timeout: const Timeout(_timeout));
    test('10k rows', () => runScale(10000), timeout: const Timeout(_timeout));
    test('50k rows', () => runScale(50000), timeout: const Timeout(_timeout));
  });
}
