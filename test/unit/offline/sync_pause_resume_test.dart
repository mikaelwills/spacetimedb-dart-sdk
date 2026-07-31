import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

class _MapDecoder extends RowDecoder<Map<String, dynamic>> {
  @override
  Map<String, dynamic> decode(BsatnDecoder decoder) => {};

  @override
  dynamic getPrimaryKey(Map<String, dynamic> row) => row['id'];

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(Map<String, dynamic> row) => row;

  @override
  Map<String, dynamic>? fromJson(Map<String, dynamic> json) => json;
}

TransactionResult _committed(String reducerName) {
  return TransactionResult(
    status: Committed(),
    timestamp: DateTime.now(),
    reducerName: reducerName,
  );
}

PendingMutation _insertMutation(String requestId, String table, String id) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'push_message',
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
    optimisticChanges: [
      OptimisticChange.insert(table, {'id': id, 'text': 'hi'}),
    ],
  );
}

class _ReadHookStorage extends InMemoryOfflineStorage {
  int reads = 0;
  void Function(int read)? onRead;

  @override
  Future<List<PendingMutation>> getPendingMutations() {
    reads++;
    onRead?.call(reads);
    return super.getPendingMutations();
  }
}

PendingMutation _plainMutation(String requestId) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'update_note',
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
  );
}

void main() {
  group('sync state during the backoff window', () {
    test('a cycle that pauses with a backlog while connected reports '
        'waitingToRetry with the armed retry ETA, not idle', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      final cache = ClientCache();
      cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
      final messageTable = cache.getTableByName('message')!;
      messageTable.markSubscribed();
      messageTable.insertRow({'id': 'p1', 'text': 'hi'});

      final syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(cache),
        cache: cache,
        send: (reducerName, args, {requestId}) async {
          throw SpacetimeDbReducerException(
            reducerName: reducerName,
            message: 'aborted',
            result: TransactionResult(
              status: InternalError('aborted'),
              timestamp: DateTime.now(),
              reducerName: reducerName,
            ),
          );
        },
      );

      final states = <SyncState>[];
      final sub = syncer.onSyncStateChanged.listen(states.add);
      await storage.enqueueMutation(_insertMutation('p1', 'message', 'p1'));

      final before = DateTime.now();
      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      final after = DateTime.now();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
        await storage.getPendingMutations(),
        hasLength(1),
        reason: 'the abort-recheck pause keeps the mutation queued',
      );
      final state = syncer.syncState;
      expect(state.pendingCount, equals(1));
      expect(
        state.status,
        isNot(SyncStatus.idle),
        reason:
            'a queue with a backlog and an armed retry timer is waiting '
            'to retry, not idle; consumers cannot distinguish this from '
            'idle-with-backlog',
      );
      expect(
        states.map((s) => s.status),
        contains(SyncStatus.syncing),
        reason: 'the cycle start must still be observable on the stream',
      );
      expect(
        state.nextRetryAt,
        isNotNull,
        reason: 'the armed retry fire-time must be exposed to consumers',
      );
      expect(
        state.nextRetryAt!.isAfter(
          before.add(const Duration(milliseconds: 4900)),
        ),
        isTrue,
        reason: 'first retry is retryDelayForAttempt(0) = 5s out',
      );
      expect(
        state.nextRetryAt!.isBefore(
          after.add(const Duration(milliseconds: 5100)),
        ),
        isTrue,
        reason: 'first retry is retryDelayForAttempt(0) = 5s out',
      );
      syncer.cancelRetry();
    });

    test('a full drain returns the state to idle with no pending and no '
        'retry ETA', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      var failFirst = true;
      final syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          if (failFirst) {
            failFirst = false;
            throw Exception('transient network failure');
          }
          return _committed(reducerName);
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      expect(syncer.syncState.status, equals(SyncStatus.waitingToRetry));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

      final state = syncer.syncState;
      expect(state.status, equals(SyncStatus.idle));
      expect(state.isIdle, isTrue);
      expect(state.isWaitingToRetry, isFalse);
      expect(state.pendingCount, equals(0));
      expect(
        state.nextRetryAt,
        isNull,
        reason: 'a drained queue has no armed retry',
      );
      syncer.cancelRetry();
    });

    test('a cycle that pauses with a backlog while DISCONNECTED reports idle '
        'with pending, not waitingToRetry (no timer is armed; reconnect '
        'drives the resume)', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      final syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          connection.setStateSilently(const Disconnected());
          throw Exception('socket closed');
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

      final state = syncer.syncState;
      expect(state.status, equals(SyncStatus.idle));
      expect(state.pendingCount, equals(1));
      expect(
        state.nextRetryAt,
        isNull,
        reason: 'no timer is armed while disconnected',
      );
      syncer.cancelRetry();
    });

    test('a new cycle clears nextRetryAt on the syncing emit', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      var failures = 0;
      final syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          failures++;
          throw Exception('transient network failure $failures');
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      final states = <SyncState>[];
      final sub = syncer.onSyncStateChanged.listen(states.add);

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      final firstEta = syncer.syncState.nextRetryAt;
      expect(firstEta, isNotNull);

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final syncingEmits = states.where((s) => s.status == SyncStatus.syncing);
      expect(syncingEmits, hasLength(2));
      expect(
        syncingEmits.last.nextRetryAt,
        isNull,
        reason: 'a running cycle has no armed retry ETA',
      );
      final secondEta = syncer.syncState.nextRetryAt;
      expect(secondEta, isNotNull);
      expect(
        secondEta!.isAfter(firstEta!),
        isTrue,
        reason: 're-pause arms a fresh, later ETA on the backoff ladder',
      );
      syncer.cancelRetry();
    });
  });

  group('event-driven resume through the _isSyncing guard', () {
    test(
      'a resume trigger landing mid-cycle is not dropped: the queue drains '
      'via an immediate follow-up cycle instead of waiting out the backoff',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        late MutationSyncer syncer;
        var sends = 0;
        syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(ClientCache()),
          cache: ClientCache(),
          send: (reducerName, args, {requestId}) async {
            sends++;
            if (sends == 1) {
              unawaited(syncer.syncPendingMutations());
              throw Exception('transient socket write failure');
            }
            return _committed(reducerName);
          },
        );
        await storage.enqueueMutation(_plainMutation('r1'));

        await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);

        expect(
          sends,
          equals(2),
          reason:
              'the trigger that arrived while _isSyncing was true requested '
              'a resume; it must produce one follow-up cycle, not be '
              'silently dropped until the retry timer',
        );
        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason: 'the follow-up cycle drains the queue immediately',
        );
        syncer.cancelRetry();
      },
    );

    test('a burst of triggers during one cycle coalesces into exactly one '
        'follow-up cycle', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      late MutationSyncer syncer;
      var sends = 0;
      syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          sends++;
          if (sends == 1) {
            unawaited(syncer.syncPendingMutations());
            unawaited(syncer.syncPendingMutations());
            unawaited(syncer.syncPendingMutations());
          }
          throw Exception('persistent network failure');
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(
        sends,
        equals(2),
        reason:
            'three swallowed triggers coalesce into ONE follow-up cycle; '
            'the follow-up itself pauses and falls back to the timer',
      );
      expect(await storage.getPendingMutations(), hasLength(1));
      syncer.cancelRetry();
    });

    test('a trigger landing mid-cycle does not fire a follow-up when the '
        'cycle drains the queue anyway', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      late MutationSyncer syncer;
      var sends = 0;
      syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          sends++;
          if (sends == 1) {
            unawaited(syncer.syncPendingMutations());
          }
          return _committed(reducerName);
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(
        sends,
        equals(1),
        reason: 'nothing left to sync — the latched trigger must be a no-op',
      );
      expect(syncer.syncState.status, equals(SyncStatus.idle));
      syncer.cancelRetry();
    });

    test('a trigger landing mid-cycle does not fire a follow-up when the '
        'connection dropped by the end of the cycle', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();
      late MutationSyncer syncer;
      var sends = 0;
      syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          sends++;
          unawaited(syncer.syncPendingMutations());
          connection.setStateSilently(const Disconnected());
          throw Exception('socket closed');
        },
      );
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(
        sends,
        equals(1),
        reason:
            'no follow-up while disconnected; _onReconnected drives the '
            'resume',
      );
      expect(await storage.getPendingMutations(), hasLength(1));
      syncer.cancelRetry();
    });

    test('a trigger landing during the finalize re-read (after _isSyncing '
        'clears) coalesces with a latched trigger instead of running a '
        'second cycle concurrently with the follow-up', () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = _ReadHookStorage();
      late MutationSyncer syncer;
      var sends = 0;
      syncer = MutationSyncer(
        connection: connection,
        storage: storage,
        optimisticState: OptimisticStateManager(ClientCache()),
        cache: ClientCache(),
        send: (reducerName, args, {requestId}) async {
          sends++;
          if (sends == 1) {
            unawaited(syncer.syncPendingMutations());
          }
          throw Exception('persistent network failure');
        },
      );
      storage.onRead = (read) {
        if (read == 2) {
          unawaited(syncer.syncPendingMutations());
        }
      };
      await storage.enqueueMutation(_plainMutation('r1'));

      await syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(
        sends,
        equals(2),
        reason:
            'the finalize-window trigger must latch like a mid-cycle '
            'trigger; entering _runSyncCycle directly overlaps the '
            'follow-up cycle and re-sends the same mutation concurrently',
      );
      expect(await storage.getPendingMutations(), hasLength(1));
      syncer.cancelRetry();
    });

    test('with no event after a pause the retry timer backstop still fires at '
        'retryDelayForAttempt(0) and drains the queue', () {
      fakeAsync((async) {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(ClientCache()),
          cache: ClientCache(),
          send: (reducerName, args, {requestId}) async {
            sends++;
            if (sends == 1) {
              throw Exception('transient network failure');
            }
            return _committed(reducerName);
          },
        );
        unawaited(storage.enqueueMutation(_plainMutation('r1')));
        async.flushMicrotasks();

        unawaited(syncer.syncPendingMutations());
        async.flushMicrotasks();
        expect(sends, equals(1));
        expect(syncer.syncState.pendingCount, equals(1));

        async.elapse(const Duration(seconds: 4));
        expect(
          sends,
          equals(1),
          reason: 'the backstop must not fire before the backoff elapses',
        );

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(
          sends,
          equals(2),
          reason: 'the timer backstop fired at 5s and re-sent',
        );
        expect(syncer.syncState.pendingCount, equals(0));
        expect(syncer.syncState.status, equals(SyncStatus.idle));
        syncer.cancelRetry();
      });
    });
  });
}
