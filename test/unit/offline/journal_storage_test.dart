import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

PendingMutation _mutation(
  String requestId, {
  String reducerName = 'create_note',
}) {
  return PendingMutation(
    requestId: requestId,
    reducerName: reducerName,
    encodedArgs: Uint8List.fromList([1, 2, 3]),
    createdAt: DateTime.now(),
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('journal_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('journal equivalence', () {
    test(
      'random op interleavings match in-memory reference after every op',
      () async {
        final random = Random(42);
        final reference = InMemoryOfflineStorage();
        final journal = JsonFileStorage(basePath: tempDir.path);
        await journal.initialize();

        var nextId = 0;
        final liveIds = <String>[];

        for (var op = 0; op < 300; op++) {
          final roll = random.nextDouble();
          if (roll < 0.55 || liveIds.isEmpty) {
            final id = 'req-${nextId++}';
            liveIds.add(id);
            final m = _mutation(id);
            await reference.enqueueMutation(m);
            await journal.enqueueMutation(m);
          } else {
            final id = liveIds.removeAt(random.nextInt(liveIds.length));
            await reference.dequeueMutation(id);
            await journal.dequeueMutation(id);
          }

          final expected = (await reference.getPendingMutations()).map(
            (m) => m.requestId,
          );
          final actual = (await journal.getPendingMutations()).map(
            (m) => m.requestId,
          );
          expect(actual, equals(expected), reason: 'diverged after op $op');
        }

        final reloaded = JsonFileStorage(basePath: tempDir.path);
        await reloaded.initialize();
        expect(
          (await reloaded.getPendingMutations()).map((m) => m.requestId),
          equals(
            (await reference.getPendingMutations()).map((m) => m.requestId),
          ),
          reason: 'fresh instance must replay the journal to the same state',
        );
      },
    );
  });

  group('crash recovery', () {
    test('truncated trailing line recovers the consistent prefix', () async {
      final storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();
      for (var i = 0; i < 5; i++) {
        await storage.enqueueMutation(_mutation('req-$i'));
      }

      final journalFile = File('${tempDir.path}/pending_mutations.jsonl');
      final bytes = await journalFile.readAsBytes();
      await journalFile.writeAsBytes(
        bytes.sublist(0, bytes.length - 20),
        flush: true,
      );

      final recovered = JsonFileStorage(basePath: tempDir.path);
      await recovered.initialize();
      final pending = await recovered.getPendingMutations();

      expect(
        pending.map((m) => m.requestId),
        equals(['req-0', 'req-1', 'req-2', 'req-3']),
        reason:
            'recovery must yield the consistent prefix, never silently '
            'return an empty queue',
      );
    });

    test('corrupted middle line is skipped, rest survives', () async {
      final storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();
      for (var i = 0; i < 3; i++) {
        await storage.enqueueMutation(_mutation('req-$i'));
      }

      final journalFile = File('${tempDir.path}/pending_mutations.jsonl');
      final lines = await journalFile.readAsLines();
      lines[1] = '{"op": "enqueue", "mutation": GARBAGE}';
      await journalFile.writeAsString('${lines.join('\n')}\n', flush: true);

      final recovered = JsonFileStorage(basePath: tempDir.path);
      await recovered.initialize();
      final pending = await recovered.getPendingMutations();

      expect(pending.map((m) => m.requestId), equals(['req-0', 'req-2']));
    });
  });

  group('legacy migration', () {
    test('pending_mutations.json is migrated to the journal once', () async {
      final legacyFile = File('${tempDir.path}/pending_mutations.json');
      await legacyFile.create(recursive: true);
      await legacyFile.writeAsString(
        jsonEncode([
          _mutation('legacy-1').toJson(),
          _mutation('legacy-2').toJson(),
        ]),
      );

      final storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();
      final pending = await storage.getPendingMutations();

      expect(pending.map((m) => m.requestId), equals(['legacy-1', 'legacy-2']));
      expect(
        await legacyFile.exists(),
        isFalse,
        reason: 'legacy file removed after migration',
      );
      expect(
        await File('${tempDir.path}/pending_mutations.jsonl').exists(),
        isTrue,
      );

      await storage.enqueueMutation(_mutation('new-1'));
      final reloaded = JsonFileStorage(basePath: tempDir.path);
      await reloaded.initialize();
      expect(
        (await reloaded.getPendingMutations()).map((m) => m.requestId),
        equals(['legacy-1', 'legacy-2', 'new-1']),
      );
    });
  });

  group('compaction', () {
    test('journal does not grow unboundedly under churn', () async {
      final storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();

      for (var i = 0; i < 200; i++) {
        await storage.enqueueMutation(_mutation('req-$i'));
        await storage.dequeueMutation('req-$i');
      }

      final journalFile = File('${tempDir.path}/pending_mutations.jsonl');
      final lines =
          (await journalFile.readAsLines())
              .where((l) => l.trim().isNotEmpty)
              .length;
      expect(
        lines,
        lessThan(100),
        reason:
            '400 ops against an empty queue must compact, not retain '
            'every journal entry',
      );
      expect(await storage.getPendingMutations(), isEmpty);
    });
  });
}
