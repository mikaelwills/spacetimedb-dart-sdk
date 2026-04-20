@TestOn('browser')
library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import '../generated/note.dart';
import '../generated/folder.dart';
import '../generated/reducer_args.dart';
import '../generated/reducers.dart' as gen;
import 'package:spacetimedb_sdk/codegen.dart';

/// Chrome variant of the VM stress test. Requires a SpacetimeDB instance
/// already running at localhost:3000 with the `notesdb` test module
/// published. Run the VM stress test first — its `setUpAll` detaches a
/// fresh in-memory STDB that stays up between tests.
///
/// This version exercises the async-decompression code path (native
/// DecompressionStream on web) under a burst, where message decoding is
/// genuinely async and ordering bugs can surface.
void main() {
  test(
    'large initial subscribe + concurrent reducer burst → counts match (web)',
    () async {
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      final subManager = SubscriptionManager(connection);
      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager.cache.registerDecoder<Folder>('folder', FolderDecoder());
      subManager.reducerRegistry.register(createNoteDef);
      subManager.reducerRegistry.register(deleteAllNotesDef);
      subManager.reducerRegistry.register(createNotesBulkDef);
      final reducers = gen.Reducers(
        subManager.reducers,
        subManager.reducerEmitter,
      );

      print('📡 Connecting...');
      await connection.connect();
      await subManager.onInitialConnection.first;

      final noteTable = subManager.cache.getTableByTypedName<Note>('note');

      await subManager.subscribe(['SELECT * FROM note']);
      if (noteTable.count() > 0) {
        print('🧹 Cleaning ${noteTable.count()} existing notes...');
        await reducers.deleteAllNotes();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      const seedCount = 500;
      print('🌱 Seeding $seedCount notes via createNotesBulk...');
      await reducers.createNotesBulk(
        count: seedCount,
        titlePrefix: 'stress-seed',
      );
      while (noteTable.count() < seedCount) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      print('   ✅ Seeded. Table count: ${noteTable.count()}');

      // Disconnect + reconnect so the next SubscribeApplied carries all 500
      // rows in one compressed payload (the real worst-case for the
      // decompress-then-apply race).
      await connection.disconnect();

      final connection2 = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      final subManager2 = SubscriptionManager(connection2);
      subManager2.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager2.cache.registerDecoder<Folder>('folder', FolderDecoder());
      subManager2.reducerRegistry.register(createNoteDef);
      subManager2.reducerRegistry.register(deleteAllNotesDef);
      final reducers2 = gen.Reducers(
        subManager2.reducers,
        subManager2.reducerEmitter,
      );
      await connection2.connect();
      await subManager2.onInitialConnection.first;

      final noteTable2 = subManager2.cache.getTableByTypedName<Note>('note');

      final insertedIds = <int>{};
      final duplicateIds = <int>[];
      noteTable2.onInsert.listen((event) {
        final id = event.row.id;
        if (!insertedIds.add(id)) duplicateIds.add(id);
      });

      const burstCount = 40;
      print(
        '🔥 Subscribing + firing $burstCount concurrent createNote calls '
        '(no awaits between them)...',
      );

      final subStart = DateTime.now();
      final subscribeFuture = subManager2.subscribe(['SELECT * FROM note']);

      final burstFutures = <Future<void>>[];
      for (var i = 0; i < burstCount; i++) {
        burstFutures.add(
          reducers2
              .createNote(title: 'burst-$i', content: 'burst body $i')
              .then((_) {}),
        );
      }

      await subscribeFuture;
      print(
        '   ✅ SubscribeApplied after '
        '${DateTime.now().difference(subStart).inMilliseconds}ms. '
        'Table has ${noteTable2.count()} rows',
      );

      await Future.wait(burstFutures);
      print('   ✅ All $burstCount reducers acknowledged.');

      await Future.delayed(const Duration(milliseconds: 1000));

      const expectedTotal = seedCount + burstCount;
      final finalCount = noteTable2.count();
      print('📊 Final count: $finalCount (expected $expectedTotal)');
      print('📊 Distinct inserted ids seen: ${insertedIds.length}');
      print('📊 Duplicate insert events: ${duplicateIds.length}');

      expect(
        duplicateIds,
        isEmpty,
        reason: 'no row id should fire onInsert twice',
      );
      expect(
        finalCount,
        expectedTotal,
        reason: 'table count must match seed + burst',
      );

      final rowsByTitle = <String, List<Note>>{};
      for (final row in noteTable2.iter()) {
        rowsByTitle.putIfAbsent(row.title, () => []).add(row);
      }
      final missingBurstRows = <int>[];
      for (var i = 0; i < burstCount; i++) {
        final title = 'burst-$i';
        final rows = rowsByTitle[title] ?? const [];
        if (rows.length != 1) missingBurstRows.add(i);
      }
      expect(
        missingBurstRows,
        isEmpty,
        reason: 'every burst-N row must land exactly once',
      );

      await reducers2.deleteAllNotes();
      await connection2.disconnect();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
