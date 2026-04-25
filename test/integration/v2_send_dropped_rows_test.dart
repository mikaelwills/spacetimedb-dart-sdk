import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Verifies slice-5 `SendDroppedRows` flag — when an Unsubscribe carries
/// `UnsubscribeFlags::SendDroppedRows`, the server's `UnsubscribeApplied`
/// payload includes the `Option<QueryRows>` dropped-rows set, and the SDK
/// applies them as deletes against the local cache.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'unsubscribe(sendDroppedRows: true) delivers dropped rows + fires deletes',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      // Clean slate.
      final querySetId = await env.subManager.subscribe(['SELECT * FROM note']);
      final table = env.subManager.cache.getTableByTypedName<Note>('note');
      if (table.count() > 0) {
        await env.reducers.deleteAllNotes();
      }

      await env.reducers.createNote(title: 'DroppedRows-1', content: 'a');
      await env.reducers.createNote(title: 'DroppedRows-2', content: 'b');

      expect(table.count(), equals(2));

      // Register a listener for delete events before unsubscribing.
      final deletedTitles = <String>[];
      final sub = table.onDelete.listen((event) {
        deletedTitles.add(event.row.title);
      });

      env.subManager.unsubscribe(
        querySetId,
        requestId: 1,
        sendDroppedRows: true,
      );

      final applied = await env.subManager.onUnsubscribeApplied.first.timeout(
        const Duration(seconds: 5),
      );
      // Let the handler finish its cache mutations on the event loop.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(applied.querySetId, equals(querySetId));
      expect(
        applied.rows,
        isNotNull,
        reason: 'server must populate rows when SendDroppedRows=1',
      );
      expect(applied.rows!.tables.any((t) => t.tableName == 'note'), isTrue);

      expect(
        deletedTitles,
        containsAll(['DroppedRows-1', 'DroppedRows-2']),
        reason: 'SDK must fire delete events for every dropped row',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'unsubscribe(sendDroppedRows: false) omits dropped rows',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      final querySetId = await env.subManager.subscribe(['SELECT * FROM note']);
      final table = env.subManager.cache.getTableByTypedName<Note>('note');
      if (table.count() > 0) {
        await env.reducers.deleteAllNotes();
      }
      await env.reducers.createNote(title: 'NoDroppedRows', content: 'a');

      env.subManager.unsubscribe(querySetId, requestId: 2);

      final applied = await env.subManager.onUnsubscribeApplied.first.timeout(
        const Duration(seconds: 5),
      );

      expect(applied.querySetId, equals(querySetId));
      expect(
        applied.rows,
        isNull,
        reason:
            'server must NOT include rows when UnsubscribeFlags::Default (0)',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
