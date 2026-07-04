import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

TransactionResult _committed(String reducerName) {
  return TransactionResult(
    status: Committed(),
    timestamp: DateTime.now(),
    reducerName: reducerName,
  );
}

TransactionResult _rejected(String reducerName, String error) {
  return TransactionResult(
    status: InternalError(error),
    timestamp: DateTime.now(),
    reducerName: reducerName,
  );
}

PendingMutation _mutation(String requestId, String reducerName) {
  return PendingMutation(
    requestId: requestId,
    reducerName: reducerName,
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
  );
}

class _Harness {
  final MockConnection connection;
  final InMemoryOfflineStorage storage;
  final MutationSyncer syncer;
  final List<String> sentReducers = [];

  _Harness._(this.connection, this.storage, this.syncer);

  factory _Harness({
    required TransactionResult Function(String reducerName) respond,
    OfflineQueuePolicy policy = const OfflineQueuePolicy(),
  }) {
    final connection = MockConnection();
    connection.setStateSilently(const Connected());
    final storage = InMemoryOfflineStorage();
    final cache = ClientCache();
    final optimisticState = OptimisticStateManager(cache);
    late _Harness harness;
    final syncer = MutationSyncer(
      connection: connection,
      storage: storage,
      optimisticState: optimisticState,
      cache: cache,
      policy: policy,
      send: (reducerName, args, {requestId}) async {
        harness.sentReducers.add(reducerName);
        final result = respond(reducerName);
        if (!result.isSuccess && result.status is InternalError) {
          throw SpacetimeDbReducerException(
            reducerName: reducerName,
            message: result.errorMessage ?? 'Unknown error',
            result: result,
          );
        }
        return result;
      },
    );
    harness = _Harness._(connection, storage, syncer);
    return harness;
  }
}

void main() {
  group('sync error surfacing', () {
    test('rejected mutation sets error state on SyncState', () async {
      final harness = _Harness(
        respond:
            (name) =>
                name == 'bad_reducer'
                    ? _rejected(name, 'nope')
                    : _committed(name),
      );
      await harness.storage.enqueueMutation(_mutation('r1', 'good_a'));
      await harness.storage.enqueueMutation(_mutation('r2', 'bad_reducer'));
      await harness.storage.enqueueMutation(_mutation('r3', 'good_b'));

      await harness.syncer.syncPendingMutations();

      final state = harness.syncer.syncState;
      expect(state.pendingCount, equals(0));
      expect(state.failedCount, equals(1));
      expect(state.hasError, isTrue);
      expect(state.recentFailures, hasLength(1));
      expect(state.recentFailures.single.reducerName, equals('bad_reducer'));
      expect(state.recentFailures.single.error, equals('nope'));
      expect(
        harness.sentReducers,
        equals(['good_a', 'bad_reducer', 'good_b']),
        reason: 'one rejection must not poison the rest of the queue',
      );
    });

    test(
      'error state persists across flushes, clean flush resets it',
      () async {
        var rejectAll = true;
        final harness = _Harness(
          respond:
              (name) =>
                  rejectAll ? _rejected(name, 'locked') : _committed(name),
        );
        await harness.storage.enqueueMutation(_mutation('r1', 'update_note'));

        await harness.syncer.syncPendingMutations();
        expect(harness.syncer.syncState.hasError, isTrue);
        expect(harness.syncer.syncState.failedCount, equals(1));

        rejectAll = false;
        await harness.storage.enqueueMutation(_mutation('r2', 'update_note'));
        await harness.syncer.updatePendingCount();
        expect(
          harness.syncer.syncState.hasError,
          isTrue,
          reason: 'badge survives until a clean flush resolves it',
        );

        await harness.syncer.syncPendingMutations();
        expect(harness.syncer.syncState.hasError, isFalse);
        expect(harness.syncer.syncState.failedCount, equals(0));
        expect(harness.syncer.syncState.recentFailures, isEmpty);
      },
    );

    test('clearSyncErrors dismisses without a flush', () async {
      final harness = _Harness(respond: (name) => _rejected(name, 'denied'));
      await harness.storage.enqueueMutation(_mutation('r1', 'update_note'));
      await harness.syncer.syncPendingMutations();
      expect(harness.syncer.syncState.hasError, isTrue);

      harness.syncer.clearSyncErrors();
      expect(harness.syncer.syncState.hasError, isFalse);
      expect(harness.syncer.syncState.recentFailures, isEmpty);
    });

    test('late listener sees the failure via syncState', () async {
      final harness = _Harness(respond: (name) => _rejected(name, 'denied'));
      await harness.storage.enqueueMutation(_mutation('r1', 'update_note'));

      await harness.syncer.syncPendingMutations();

      final stateReadAfterFlush = harness.syncer.syncState;
      expect(stateReadAfterFlush.failedCount, equals(1));
      expect(stateReadAfterFlush.recentFailures.single.error, equals('denied'));
    });

    test('failure record carries the optimistic changes', () async {
      final harness = _Harness(respond: (name) => _rejected(name, 'denied'));
      final changes = [
        OptimisticChange.update(
          'note',
          {'id': 1, 'content': 'old'},
          {'id': 1, 'content': 'new'},
        ),
      ];
      await harness.storage.enqueueMutation(
        PendingMutation(
          requestId: 'r1',
          reducerName: 'update_note',
          encodedArgs: Uint8List(0),
          createdAt: DateTime.now(),
          optimisticChanges: changes,
        ),
      );

      await harness.syncer.syncPendingMutations();

      final failure = harness.syncer.syncState.recentFailures.single;
      expect(failure.optimisticChanges, isNotNull);
      expect(
        failure.optimisticChanges!.single.newRowJson!['content'],
        equals('new'),
        reason: 'apps need the lost edit content for recovery flows',
      );
    });

    test('timeout is not an error and mutation stays queued', () async {
      final harness = _Harness(respond: (name) => _committed(name));
      final timeoutSyncer = MutationSyncer(
        connection: harness.connection,
        storage: harness.storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          throw SpacetimeDbTimeoutException(
            'Reducer "$reducerName" timed out',
            elapsed: const Duration(seconds: 10),
          );
        },
      );
      await harness.storage.enqueueMutation(_mutation('r1', 'update_note'));

      await timeoutSyncer.syncPendingMutations();

      expect(timeoutSyncer.syncState.failedCount, equals(0));
      expect(timeoutSyncer.syncState.hasError, isFalse);
      expect(
        await harness.storage.getPendingMutations(),
        hasLength(1),
        reason: 'timeouts are transient and must stay queued for retry',
      );
      timeoutSyncer.cancelRetry();
    });

    test('retained failures default to the most recent 20', () async {
      final harness = _Harness(respond: (name) => _rejected(name, 'denied'));
      for (var i = 0; i < 25; i++) {
        await harness.storage.enqueueMutation(_mutation('r$i', 'update_note'));
      }

      await harness.syncer.syncPendingMutations();

      final state = harness.syncer.syncState;
      expect(state.failedCount, equals(25));
      expect(state.recentFailures, hasLength(20));
      expect(state.recentFailures.last.requestId, equals('r24'));
      expect(state.recentFailures.first.requestId, equals('r5'));
    });

    test('retention bound is configurable via policy', () async {
      final harness = _Harness(
        respond: (name) => _rejected(name, 'denied'),
        policy: const OfflineQueuePolicy(maxRetainedFailures: 5),
      );
      for (var i = 0; i < 12; i++) {
        await harness.storage.enqueueMutation(_mutation('r$i', 'update_note'));
      }

      await harness.syncer.syncPendingMutations();

      final state = harness.syncer.syncState;
      expect(
        state.failedCount,
        equals(12),
        reason: 'failedCount always reflects the true total',
      );
      expect(state.recentFailures, hasLength(5));
      expect(state.recentFailures.first.requestId, equals('r7'));
      expect(state.recentFailures.last.requestId, equals('r11'));
    });

    test('null retention bound keeps every failure', () async {
      final harness = _Harness(
        respond: (name) => _rejected(name, 'denied'),
        policy: const OfflineQueuePolicy(maxRetainedFailures: null),
      );
      for (var i = 0; i < 50; i++) {
        await harness.storage.enqueueMutation(_mutation('r$i', 'update_note'));
      }

      await harness.syncer.syncPendingMutations();

      final state = harness.syncer.syncState;
      expect(state.failedCount, equals(50));
      expect(state.recentFailures, hasLength(50));
    });

    test(
      'a dequeue failure after a successful send does not silently drop the '
      'mutation or mislabel the storage error',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = _ThrowingDequeueStorage();
        final sent = <String>[];
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(ClientCache()),
          cache: ClientCache(),
          send: (reducerName, args, {requestId}) async {
            sent.add(reducerName);
            return _committed(reducerName);
          },
        );
        await storage.enqueueMutation(_mutation('r1', 'update_note'));

        await syncer.syncPendingMutations();

        expect(sent, equals(['update_note']));
        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the send succeeded but the dequeue failed; the mutation stays '
              'queued rather than being silently dropped, and the storage '
              'error is not misreported as a network error',
        );
        syncer.cancelRetry();
      },
    );
  });
}

class _ThrowingDequeueStorage extends InMemoryOfflineStorage {
  @override
  Future<void> dequeueMutation(String requestId) async {
    throw StateError('disk full on dequeue');
  }
}
