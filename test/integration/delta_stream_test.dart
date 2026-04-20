library;

// ignore_for_file: avoid_print
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'delta streams fire on create/update/delete; each in the same transaction as lastBatch',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onSubscribeApplied.first;

      final noteTable = env.noteTable;
      final title = 'delta-${DateTime.now().millisecondsSinceEpoch}';

      final inserts = <TableInsertEvent<Note>>[];
      final updates = <TableUpdateEvent<Note>>[];
      final deletes = <TableDeleteEvent<Note>>[];
      final subI = noteTable.onInsert.listen(inserts.add);
      final subU = noteTable.onUpdate.listen(updates.add);
      final subD = noteTable.onDelete.listen(deletes.add);

      final batchesSeen = <int>[];
      bool insertStreamFiredBeforeLastBatch = false;
      int currentStreamCount = 0;
      void lastBatchListener() {
        final batch = noteTable.lastBatch.value;
        if (batch == null) return;
        batchesSeen.add(batch.events.length);
        if (batch.events.whereType<TableInsertEvent<Note>>().any(
              (e) => e.row.title == title,
            ) &&
            inserts.length > currentStreamCount) {
          insertStreamFiredBeforeLastBatch = true;
        }
        currentStreamCount = inserts.length;
      }

      noteTable.lastBatch.addListener(lastBatchListener);

      await env.reducers.createNote(title: title, content: 'v1');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final createdId = noteTable.iter().firstWhere((n) => n.title == title).id;

      expect(
        inserts.map((e) => e.row.title),
        contains(title),
        reason: 'onInsert should fire for created note',
      );
      expect(
        insertStreamFiredBeforeLastBatch,
        isTrue,
        reason: 'onInsert must fire before lastBatch (sync: true contract)',
      );

      await env.reducers.updateNote(
        noteId: createdId,
        title: 'UPDATED $title',
        content: 'v2',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        updates.map((e) => e.newRow.title),
        anyElement(contains('UPDATED')),
        reason: 'onUpdate should fire for updated note',
      );

      await env.reducers.deleteNote(noteId: createdId);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        deletes.map((e) => e.row.id),
        contains(createdId),
        reason: 'onDelete should fire for deleted note',
      );

      await subI.cancel();
      await subU.cancel();
      await subD.cancel();
      noteTable.lastBatch.removeListener(lastBatchListener);

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
