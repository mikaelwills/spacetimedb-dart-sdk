import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/offline/impl/json_file_storage.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

const _timeout = Duration(seconds: 5);

void main() {
  group('JsonFileStorage', () {
    late Directory tempDir;
    late JsonFileStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'json_file_storage_test_',
      );
      storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('atomic writes and recovery', () {
      test('recovers from temp file on initialization', () async {
        final tempFile = File('${tempDir.path}/table_orphan.json.tmp');
        await tempFile.writeAsString('[{"id": 1}]').timeout(_timeout);

        final newStorage = JsonFileStorage(basePath: tempDir.path);
        await newStorage.initialize().timeout(_timeout);

        final recovered = File('${tempDir.path}/table_orphan.json');
        expect(await recovered.exists().timeout(_timeout), isTrue);
        expect(await tempFile.exists().timeout(_timeout), isFalse);

        await newStorage.dispose().timeout(_timeout);
      });

      test('recovers from backup when main file is corrupted', () async {
        await storage
            .saveTableSnapshot('notes', [
              {'id': 1, 'title': 'Test'},
            ])
            .timeout(_timeout);

        final mainFile = File('${tempDir.path}/table_notes.json');
        final backupFile = File('${tempDir.path}/table_notes.json.bak');
        await backupFile
            .writeAsString(await mainFile.readAsString())
            .timeout(_timeout);
        await mainFile
            .writeAsString('corrupted{invalid json')
            .timeout(_timeout);

        final loaded = await storage
            .loadTableSnapshot('notes')
            .timeout(_timeout);
        expect(loaded, isNotNull);
        expect(loaded!.first['title'], equals('Test'));
      });

      test(
        'recovers mutations from backup when main file is corrupted',
        () async {
          await storage
              .enqueueMutation(_createMutation('req-1'))
              .timeout(_timeout);

          final mainFile = File('${tempDir.path}/pending_mutations.json');
          final backupFile = File('${tempDir.path}/pending_mutations.json.bak');
          await backupFile
              .writeAsString(await mainFile.readAsString())
              .timeout(_timeout);
          await mainFile.writeAsString('corrupted{invalid').timeout(_timeout);

          final loaded = await storage.getPendingMutations().timeout(_timeout);
          expect(loaded.length, equals(1));
          expect(loaded.first.requestId, equals('req-1'));
        },
      );

      test('returns null when both main and backup are corrupted', () async {
        await storage
            .saveTableSnapshot('notes', [
              {'id': 1, 'title': 'Test'},
            ])
            .timeout(_timeout);

        final mainFile = File('${tempDir.path}/table_notes.json');
        final backupFile = File('${tempDir.path}/table_notes.json.bak');
        await mainFile
            .writeAsString('corrupted{invalid json')
            .timeout(_timeout);
        await backupFile.writeAsString('also corrupted{').timeout(_timeout);

        final loaded = await storage
            .loadTableSnapshot('notes')
            .timeout(_timeout);
        expect(loaded, isNull);
      });
    });

    group('concurrent access', () {
      test('handles simultaneous writes to same table', () async {
        final futures = <Future>[];
        for (var i = 0; i < 10; i++) {
          futures.add(
            storage.saveTableSnapshot('concurrent', [
              {'id': i, 'value': i},
            ]),
          );
        }

        await Future.wait(futures).timeout(_timeout);

        final loaded = await storage
            .loadTableSnapshot('concurrent')
            .timeout(_timeout);
        expect(loaded, isNotNull);
        expect(loaded!.length, equals(1));
      });

      test('handles simultaneous mutation enqueues', () async {
        final futures = <Future>[];
        for (var i = 0; i < 10; i++) {
          futures.add(storage.enqueueMutation(_createMutation('req-$i')));
        }

        await Future.wait(futures).timeout(_timeout);

        final pending = await storage.getPendingMutations().timeout(_timeout);
        expect(pending.length, equals(10));
      });
    });

    group('data persistence', () {
      test('data persists across storage instances', () async {
        await storage
            .saveTableSnapshot('notes', [
              {'id': 1, 'title': 'Test'},
            ])
            .timeout(_timeout);
        await storage
            .enqueueMutation(_createMutation('req-1'))
            .timeout(_timeout);
        await storage
            .setLastSyncTime('notes', DateTime.utc(2024, 1, 15))
            .timeout(_timeout);

        await storage.dispose().timeout(_timeout);

        final newStorage = JsonFileStorage(basePath: tempDir.path);
        await newStorage.initialize().timeout(_timeout);

        final notes = await newStorage
            .loadTableSnapshot('notes')
            .timeout(_timeout);
        final mutations = await newStorage.getPendingMutations().timeout(
          _timeout,
        );
        final syncTime = await newStorage
            .getLastSyncTime('notes')
            .timeout(_timeout);

        expect(notes!.first['title'], equals('Test'));
        expect(mutations.first.requestId, equals('req-1'));
        expect(syncTime, equals(DateTime.utc(2024, 1, 15)));

        await newStorage.dispose().timeout(_timeout);
      });

      test('preserves optimistic changes through serialization', () async {
        final mutation = PendingMutation(
          requestId: 'req-1',
          reducerName: 'create_note',
          encodedArgs: Uint8List.fromList([1, 2, 3]),
          createdAt: DateTime.now(),
          optimisticChanges: [
            OptimisticChange.insert('notes', {'id': 1, 'title': 'Test'}),
          ],
        );

        await storage.enqueueMutation(mutation).timeout(_timeout);

        await storage.dispose().timeout(_timeout);
        final newStorage = JsonFileStorage(basePath: tempDir.path);
        await newStorage.initialize().timeout(_timeout);

        final pending = await newStorage.getPendingMutations().timeout(
          _timeout,
        );
        expect(pending.first.optimisticChanges, isNotNull);
        expect(
          pending.first.optimisticChanges!.first.type,
          equals(OptimisticChangeType.insert),
        );

        await newStorage.dispose().timeout(_timeout);
      });
    });

    group('clearAll', () {
      test('removes all data and base directory still exists', () async {
        await storage
            .saveTableSnapshot('notes', [
              {'id': 1},
            ])
            .timeout(_timeout);
        await storage
            .enqueueMutation(_createMutation('req-1'))
            .timeout(_timeout);
        await storage
            .setLastSyncTime('notes', DateTime.now())
            .timeout(_timeout);

        await storage.clearAll().timeout(_timeout);

        expect(
          await storage.loadTableSnapshot('notes').timeout(_timeout),
          isNull,
        );
        expect(await storage.getPendingMutations().timeout(_timeout), isEmpty);
        expect(
          await storage.getLastSyncTime('notes').timeout(_timeout),
          isNull,
        );
        expect(
          await Directory(tempDir.path).exists().timeout(_timeout),
          isTrue,
        );
      });
    });

    group('dispose', () {
      test('dispose waits for pending operations to complete', () async {
        var writeCompleted = false;
        final writeStarted = Completer<void>();

        final writeFuture = storage
            .saveTableSnapshot('slow', [
              {'id': 1},
            ])
            .then((_) {
              writeCompleted = true;
            });

        scheduleMicrotask(() => writeStarted.complete());
        await writeStarted.future;

        final disposeFuture = storage.dispose();
        await disposeFuture.timeout(_timeout);

        await writeFuture.timeout(_timeout);
        expect(writeCompleted, isTrue);

        final file = File('${tempDir.path}/table_slow.json');
        expect(await file.exists(), isTrue);
      });

      test('operations after dispose throw StateError', () async {
        await storage.dispose().timeout(_timeout);

        expect(
          () => storage.saveTableSnapshot('test', [
            {'id': 1},
          ]),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}

PendingMutation _createMutation(String requestId) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'test_reducer',
    encodedArgs: Uint8List.fromList([1, 2, 3]),
    createdAt: DateTime.now(),
  );
}
