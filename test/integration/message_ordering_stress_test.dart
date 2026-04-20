library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Worst-case stress: large initial SubscribeApplied still decompressing when
/// a burst of TransactionUpdate frames lands. Proves the SDK doesn't reorder
/// or drop messages when decompression is async.
///
/// If message decoding is not serialized, the large SubscribeApplied and the
/// many smaller TransactionUpdates race to complete on the microtask queue.
/// A small TransactionUpdate that arrived AFTER SubscribeApplied could finish
/// decoding FIRST and hit the cache before initial rows are applied, leaving
/// the table in an inconsistent state.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'large initial subscribe + concurrent reducer burst → counts match',
    () async {
      final env = await createTestEnv();

      print('📡 Connecting...');
      await env.connection.connect();
      await env.subManager.onInitialConnection.first;

      final noteTable = env.noteTable;

      // Clean slate so we know exactly what we're counting.
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onSubscribeApplied.first;
      if (noteTable.count() > 0) {
        print('🧹 Cleaning ${noteTable.count()} existing notes...');
        await env.reducers.deleteAllNotes();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Pre-seed with a pile of rows so the NEXT SubscribeApplied is large
      // enough to take meaningful time to decompress. ~500 notes is plenty to
      // push the initial payload over the Brotli threshold on the server.
      const seedCount = 500;
      print('🌱 Seeding $seedCount notes via createNotesBulk...');
      final seedStart = DateTime.now();
      await env.reducers.createNotesBulk(
        count: seedCount,
        titlePrefix: 'stress-seed',
      );
      print(
        '   createNotesBulk returned after '
        '${DateTime.now().difference(seedStart).inMilliseconds}ms',
      );
      // Wait for server echo of all inserts.
      while (noteTable.count() < seedCount) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      print('   ✅ Seeded. Table count: ${noteTable.count()}');

      // Disconnect and reconnect with a fresh subscription manager so the
      // initial SubscribeApplied carries all 2000 rows in one payload.
      await env.disconnect();
      final env2 = await createTestEnv();
      await env2.connection.connect();
      await env2.subManager.onInitialConnection.first;

      // Track every onInsert event after reconnect.
      final insertedIds = <int>{};
      final duplicateIds = <int>[];
      final noteTable2 = env2.noteTable;
      noteTable2.onInsert.listen((event) {
        final id = event.row.id;
        if (!insertedIds.add(id)) duplicateIds.add(id);
      });

      // KICK THE BURST: fire subscribe + N reducer calls without awaiting.
      // If decode is not serialized, the small TransactionUpdates could
      // resolve their decompression futures before the large SubscribeApplied
      // does, landing in the cache out of order.
      const burstCount = 40;
      print(
        '🔥 Subscribing + firing $burstCount concurrent createNote calls '
        '(no awaits between them)...',
      );

      final subStart = DateTime.now();
      // subscribe() already awaits SubscribeApplied internally.
      final subscribeFuture = env2.subManager.subscribe(['SELECT * FROM note']);

      final burstFutures = <Future<void>>[];
      for (var i = 0; i < burstCount; i++) {
        burstFutures.add(
          env2.reducers
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

      // Let any straggler row-stream events settle.
      await Future.delayed(const Duration(milliseconds: 1000));

      // Assertions: every seed row + every burst row is present exactly once.
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

      // Verify each burst title is represented in the cache exactly once.
      final missingBurstRows = <int>[];
      final rowsByTitle = <String, List<Note>>{};
      for (final row in noteTable2.iter()) {
        rowsByTitle.putIfAbsent(row.title, () => []).add(row);
      }
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

      // Clean up.
      await env2.reducers.deleteAllNotes();
      await env2.disconnect();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
