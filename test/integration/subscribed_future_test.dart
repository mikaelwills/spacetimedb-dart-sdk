// ignore_for_file: avoid_print
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
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

  test('subscribed resolves on non-empty table after initial data', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM note']);

    await client.note.subscribed.timeout(const Duration(seconds: 10));

    await client.connection.disconnect();
  });

  test('subscribed resolves on empty table (no row-count gate)', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM tagged_item']);

    await client.taggedItem.subscribed.timeout(const Duration(seconds: 10));
    expect(client.taggedItem.rows.value, isEmpty);

    await client.connection.disconnect();
  });

  test(
    'subscribed is idempotent — awaiting twice returns immediately',
    () async {
      final client = await SpacetimeDbClient.create(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      await client.connect(initialSubscriptions: ['SELECT * FROM folder']);

      await client.folder.subscribed.timeout(const Duration(seconds: 10));

      final stopwatch = Stopwatch()..start();
      await client.folder.subscribed;
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(50));

      await client.connection.disconnect();
    },
  );

  test('markSubscribeFailed surfaces on subscribed future', () async {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: ['SELECT * FROM note']);
    await client.note.subscribed.timeout(const Duration(seconds: 10));

    final folderTable = client.folder;
    final pending = folderTable.subscribed;
    folderTable.markSubscribeFailed(
      SpacetimeDbSubscriptionException(
        '`folder` is not a valid table',
        tableName: 'folder',
      ),
    );

    await expectLater(
      pending,
      throwsA(isA<SpacetimeDbSubscriptionException>()),
    );

    await client.connection.disconnect();
  });
}
