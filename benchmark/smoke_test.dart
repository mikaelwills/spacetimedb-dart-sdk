// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

import '../test/helpers/integration_test_helper.dart';
import '../test/generated/client.dart';

void main() {
  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.none;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  test('entity table smoke: bulk insert 100 rows', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM entity']);

    expect(client.entity.count(), equals(0));

    final batchLanded = _waitForNonNull(client.entity.lastBatch);
    await client.reducers.bulkInsertEntities(count: 100);
    await batchLanded.timeout(const Duration(seconds: 10));

    expect(client.entity.count(), equals(100));
    print('Smoke test passed: ${client.entity.count()} entities');

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
