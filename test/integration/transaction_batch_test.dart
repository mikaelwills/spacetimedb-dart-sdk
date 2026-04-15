library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'Multi-row transaction fires lastBatch exactly once',
    () async {
      final env = await createTestEnv();

      await env.connection.connect();
      await env.subManager.onIdentityToken.first;
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      if (noteTable.count() > 0) {
        await env.reducers.deleteAllNotes();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      const notesToCreate = 5;
      for (var i = 0; i < notesToCreate; i++) {
        await env.reducers.createNote(
          title: 'BatchTest-${DateTime.now().microsecondsSinceEpoch}-$i',
          content: 'Content $i',
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      expect(noteTable.count(), equals(notesToCreate));

      var batchFireCount = 0;
      int? observedBatchLength;
      TransactionBatch<Note>? observedBatch;
      final completer = Completer<void>();

      void listener() {
        final batch = noteTable.lastBatch.value;
        if (batch == null) return;
        if (batch.events.every((e) => e is TableDeleteEvent<Note>)) {
          batchFireCount++;
          observedBatchLength = batch.length;
          observedBatch = batch;
          if (!completer.isCompleted) completer.complete();
        }
      }

      noteTable.lastBatch.addListener(listener);

      await env.reducers.deleteAllNotes();

      await completer.future.timeout(const Duration(seconds: 10));
      await Future.delayed(const Duration(milliseconds: 500));
      noteTable.lastBatch.removeListener(listener);

      print('📊 Batch fires observed: $batchFireCount');
      print('📊 Events in single batch: $observedBatchLength');

      expect(
        batchFireCount,
        equals(1),
        reason:
            'A single-transaction multi-row delete must fire lastBatch once',
      );
      expect(
        observedBatchLength,
        equals(notesToCreate),
        reason: 'The batch must contain all N deletes from the transaction',
      );
      expect(observedBatch!.deletes.length, equals(notesToCreate));
      expect(observedBatch!.inserts, isEmpty);
      expect(observedBatch!.updates, isEmpty);

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'Single-row transaction fires lastBatch with size-1 batch',
    () async {
      final env = await createTestEnv();

      await env.connection.connect();
      await env.subManager.onIdentityToken.first;
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      if (noteTable.count() > 0) {
        await env.reducers.deleteAllNotes();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      var insertBatchFires = 0;
      int? observedLength;
      final completer = Completer<void>();

      void listener() {
        final batch = noteTable.lastBatch.value;
        if (batch == null) return;
        if (batch.events.any((e) => e is TableInsertEvent<Note>)) {
          insertBatchFires++;
          observedLength = batch.length;
          if (!completer.isCompleted) completer.complete();
        }
      }

      noteTable.lastBatch.addListener(listener);

      await env.reducers.createNote(
        title: 'SingleRow-${DateTime.now().microsecondsSinceEpoch}',
        content: 'single',
      );

      await completer.future.timeout(const Duration(seconds: 5));
      await Future.delayed(const Duration(milliseconds: 300));
      noteTable.lastBatch.removeListener(listener);

      expect(insertBatchFires, equals(1));
      expect(observedLength, equals(1));

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
