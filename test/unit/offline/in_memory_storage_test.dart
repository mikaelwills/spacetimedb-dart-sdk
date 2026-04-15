import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/offline/offline_storage.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

const _timeout = Duration(seconds: 5);

void main() {
  group('InMemoryOfflineStorage', () {
    late InMemoryOfflineStorage storage;

    setUp(() async {
      storage = InMemoryOfflineStorage();
      await storage.initialize();
    });

    tearDown(() async {
      await storage.dispose();
    });

    group('table snapshots', () {
      test('save and load preserves data', () async {
        final rows = [
          {'id': 1, 'title': 'Note 1'},
          {'id': 2, 'title': 'Note 2'},
        ];

        await storage.saveTableSnapshot('notes', rows).timeout(_timeout);
        final loaded = await storage
            .loadTableSnapshot('notes')
            .timeout(_timeout);

        expect(loaded, equals(rows));
      });

      test('returns null for non-existent table', () async {
        final result = await storage
            .loadTableSnapshot('non_existent')
            .timeout(_timeout);
        expect(result, isNull);
      });

      test('clearTableSnapshot removes only specified table', () async {
        await storage
            .saveTableSnapshot('notes', [
              {'id': 1},
            ])
            .timeout(_timeout);
        await storage
            .saveTableSnapshot('users', [
              {'id': 2},
            ])
            .timeout(_timeout);

        await storage.clearTableSnapshot('notes').timeout(_timeout);

        expect(
          await storage.loadTableSnapshot('notes').timeout(_timeout),
          isNull,
        );
        expect(
          await storage.loadTableSnapshot('users').timeout(_timeout),
          isNotNull,
        );
      });
    });

    group('mutation queue', () {
      test('enqueue and dequeue maintains order', () async {
        await storage
            .enqueueMutation(_createMutation('req-1'))
            .timeout(_timeout);
        await storage
            .enqueueMutation(_createMutation('req-2'))
            .timeout(_timeout);
        await storage
            .enqueueMutation(_createMutation('req-3'))
            .timeout(_timeout);

        var pending = await storage.getPendingMutations().timeout(_timeout);
        expect(
          pending.map((m) => m.requestId).toList(),
          equals(['req-1', 'req-2', 'req-3']),
        );

        await storage.dequeueMutation('req-2').timeout(_timeout);

        pending = await storage.getPendingMutations().timeout(_timeout);
        expect(
          pending.map((m) => m.requestId).toList(),
          equals(['req-1', 'req-3']),
        );
      });

      test('clearMutationQueue removes all', () async {
        await storage
            .enqueueMutation(_createMutation('req-1'))
            .timeout(_timeout);
        await storage
            .enqueueMutation(_createMutation('req-2'))
            .timeout(_timeout);

        await storage.clearMutationQueue().timeout(_timeout);

        expect(await storage.getPendingMutations().timeout(_timeout), isEmpty);
      });
    });

    group('clearAll', () {
      test('clears snapshots, mutations, and sync times', () async {
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
