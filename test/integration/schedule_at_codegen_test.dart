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

  test('ScheduleAt.Interval column and reducer arg round-trip', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM cadence_item']);

    final batchLanded = _waitForNonNull(client.cadenceItem.lastBatch);
    await client.reducers.createCadenceItem(
      id: 1,
      cadence: ScheduleAtInterval(Int64(200000)),
      label: 'interval-item',
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.cadenceItem.find(1);
    expect(stored, isNotNull);
    expect(stored!.cadence, isA<ScheduleAtInterval>());
    expect(
      (stored.cadence as ScheduleAtInterval).micros,
      equals(Int64(200000)),
    );

    await client.connection.disconnect();
  });

  test('ScheduleAt.Time column and reducer arg round-trip', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM cadence_item']);

    final batchLanded = _waitForNonNull(client.cadenceItem.lastBatch);
    await client.reducers.createCadenceItem(
      id: 2,
      cadence: ScheduleAtTime(Int64(1900000000000000)),
      label: 'time-item',
    );
    await batchLanded.timeout(const Duration(seconds: 10));

    final stored = client.cadenceItem.find(2);
    expect(stored, isNotNull);
    expect(stored!.cadence, isA<ScheduleAtTime>());
    expect(
      (stored.cadence as ScheduleAtTime).microsSinceUnixEpoch,
      equals(Int64(1900000000000000)),
    );

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
