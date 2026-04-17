// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';
import 'package:test/test.dart';

import '../generated/client.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.none;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  test('Option<String> and Option<u64> round-trip with Some values', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM optional_item']);

    final batchLanded = _waitForNonNull(client.optionalItem.lastBatch);
    await client.reducers.createOptionalItem(
      id: 1,
      nickname: 'alice',
      score: Int64(9001),
      resolvedAt: Int64(1700000000),
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.optionalItem.find(1);
    expect(stored, isNotNull);
    expect(stored!.id, equals(1));
    expect(stored.nickname, equals('alice'));
    expect(stored.score, equals(Int64(9001)));
    expect(stored.resolvedAt, equals(Int64(1700000000)));

    await client.connection.disconnect();
  });

  test('Option<String> and Option<u64> round-trip with None values', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM optional_item']);

    final batchLanded = _waitForNonNull(client.optionalItem.lastBatch);
    await client.reducers.createOptionalItem(
      id: 2,
      nickname: null,
      score: null,
      resolvedAt: null,
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.optionalItem.find(2);
    expect(stored, isNotNull);
    expect(stored!.id, equals(2));
    expect(stored.nickname, isNull);
    expect(stored.score, isNull);
    expect(stored.resolvedAt, isNull);

    await client.connection.disconnect();
  });

  test('Mixed Some/None per row on the same table', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM optional_item']);

    final batchLanded = _waitForNonNull(client.optionalItem.lastBatch);
    await client.reducers.createOptionalItem(
      id: 3,
      nickname: 'bob',
      score: null,
      resolvedAt: Int64(42),
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.optionalItem.find(3);
    expect(stored, isNotNull);
    expect(stored!.nickname, equals('bob'));
    expect(stored.score, isNull);
    expect(stored.resolvedAt, equals(Int64(42)));

    await client.connection.disconnect();
  });
}

Future<T> _waitForNonNull<T>(ValueNotifier<T?> notifier) {
  if (notifier.value != null) return Future.value(notifier.value as T);
  final completer = Completer<T>();
  void listener() {
    if (notifier.value != null && !completer.isCompleted) {
      completer.complete(notifier.value as T);
    }
  }

  notifier.addListener(listener);
  return completer.future.whenComplete(() => notifier.removeListener(listener));
}
