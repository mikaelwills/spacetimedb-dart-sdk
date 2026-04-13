// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';
import 'package:test/test.dart';

import '../generated/client.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.none;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  test('Vec<u64> and Vec<String> round-trip via tagged_item', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM tagged_item']);

    final batchLanded = _waitForNonNull(client.taggedItem.lastBatch);
    await client.reducers.createTaggedItem(
      id: 1,
      name: 'first',
      tagIds: [Int64(10), Int64(20), Int64(30)],
      labels: ['alpha', 'beta', 'gamma'],
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.taggedItem.find(1);
    expect(stored, isNotNull);
    expect(stored!.id, equals(1));
    expect(stored.name, equals('first'));
    expect(stored.tagIds, equals([Int64(10), Int64(20), Int64(30)]));
    expect(stored.labels, equals(['alpha', 'beta', 'gamma']));

    await client.connection.disconnect();
  });

  test('empty Vec<u64> and Vec<String> round-trip', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM tagged_item']);

    final batchLanded = _waitForNonNull(client.taggedItem.lastBatch);
    await client.reducers.createTaggedItem(
      id: 2,
      name: 'empty-arrays',
      tagIds: [],
      labels: [],
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.taggedItem.find(2);
    expect(stored, isNotNull);
    expect(stored!.tagIds, isEmpty);
    expect(stored.labels, isEmpty);

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
