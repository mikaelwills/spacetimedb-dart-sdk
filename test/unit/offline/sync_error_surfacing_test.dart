import 'dart:typed_data';

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

    test(
      'a timeout with unverifiable outcome (no optimistic changes) while '
      'connected is kept queued for retry, not discarded (at-least-once — '
      'loss is the worse failure)',
      () async {
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

        expect(
          await harness.storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the outcome cannot be verified but the connection is up, so the '
              'reducer may or may not have run; keep it queued for retry '
              'rather than discarding and risking a lost write',
        );
        expect(
          timeoutSyncer.syncState.failedCount,
          equals(0),
          reason:
              'a kept-queued mutation is not a failure — no MutationSyncResult '
              'is emitted for it (avoids double-counting the still-pending row)',
        );
        timeoutSyncer.cancelRetry();
      },
    );

    test(
      'a timeout while the connection is down keeps the mutation queued '
      'instead of discarding it (the reducer never reached the server)',
      () async {
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
            throw SpacetimeDbTimeoutException(
              'Reducer "$reducerName" timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );
        await storage.enqueueMutation(_mutation('r1', 'push_message'));

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the connection dropped during the send, so the reducer almost '
              'certainly never ran; the mutation must stay queued for retry '
              'rather than being discarded and lost',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'a timed-out UPDATE whose effect is already in the cache is confirmed, '
      'not re-sent',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertRow({'id': 1, 'content': 'new'});

        final optimisticState = OptimisticStateManager(cache);
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            sends++;
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.update(
                'note',
                {'id': 1, 'content': 'old'},
                {'id': 1, 'content': 'new'},
              ),
            ],
          ),
        );

        await syncer.syncPendingMutations();

        expect(sends, equals(1));
        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason:
              'the cache already shows the update\'s post-state, so the '
              'timed-out mutation is confirmed and dequeued rather than '
              're-sent (which would re-run the reducer server-side)',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'a timed-out INSERT whose row is SERVER-OWNED under its PK is confirmed, '
      'not discarded (createdAt differs; presence-by-ownership not equality)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
        final messageTable = cache.getTableByName('message')!;
        messageTable.markSubscribed();
        messageTable.insertServerOwnedRow({
          'id': 'u1783708620109-3',
          'text': 'hello',
          'created_at': 'SERVER-2026-07-10T18:37:00',
        });

        final optimisticState = OptimisticStateManager(cache);
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            sends++;
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1783708620109-3',
            reducerName: 'push_message',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('message', {
                'id': 'u1783708620109-3',
                'text': 'hello',
                'created_at': 'CLIENT-1783708620109',
              }),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(sends, equals(1), reason: 'must not re-send (would abort on PK)');
        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason:
              'the row is server-owned under its PK, so the timed-out insert '
              'is confirmed and dequeued, not discarded',
        );
        expect(
          results.where((r) => !r.success),
          isEmpty,
          reason: 'no success:false discard result may be emitted',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('u1783708620109-3'),
          reason: 'a success:true confirmation must be emitted',
        );
        expect(
          messageTable.getRow('u1783708620109-3'),
          isNotNull,
          reason: 'the optimistic row must NOT be rolled back',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'a timed-out INSERT whose PK is present only as an UNCONFIRMED optimistic '
      'row (no server owner) must NOT be confirmed — guards the lost write',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
        final messageTable = cache.getTableByName('message')!;
        messageTable.markSubscribed();
        messageTable.insertRow({
          'id': 'u1783708620109-9',
          'text': 'hello',
          'created_at': 'CLIENT-1783708620109',
        });

        final optimisticState = OptimisticStateManager(cache);
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            sends++;
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1783708620109-9',
            reducerName: 'push_message',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('message', {
                'id': 'u1783708620109-9',
                'text': 'hello',
                'created_at': 'CLIENT-1783708620109',
              }),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(sends, equals(1), reason: 'one timed-out send this cycle');
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('u1783708620109-9')),
          reason:
              'the row is present only as the client optimistic row (no server '
              'owner), so the insert is NOT proven landed and must not be '
              'confirmed as success — that would mask a lost write',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'an INSERT reducer that ABORTS on replay but whose row is server-owned '
      'is confirmed (unique-collision on the already-committed row), not failed',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
        final messageTable = cache.getTableByName('message')!;
        messageTable.markSubscribed();
        messageTable.insertServerOwnedRow({
          'id': 'a1',
          'text': 'hi',
          'created_at': 'SERVER',
        });

        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(cache),
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbReducerException(
              reducerName: reducerName,
              message: 'The instance encountered a fatal error.',
              result: _rejected(reducerName, 'fatal'),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'a1',
            reducerName: 'push_message',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('message', {
                'id': 'a1',
                'text': 'hi',
                'created_at': 'CLIENT',
              }),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(await storage.getPendingMutations(), isEmpty);
        expect(results.where((r) => !r.success), isEmpty);
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('a1'),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'an INSERT reducer that aborts on replay while NOT yet server-owned is '
      'kept queued, then confirmed once ownership hydrates',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
        final messageTable = cache.getTableByName('message')!;
        messageTable.markSubscribed();
        messageTable.insertRow({'id': 'a2', 'text': 'hi', 'created_at': 'C'});

        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(cache),
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbReducerException(
              reducerName: reducerName,
              message: 'The instance encountered a fatal error.',
              result: _rejected(reducerName, 'fatal'),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'a2',
            reducerName: 'push_message',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('message', {
                'id': 'a2',
                'text': 'hi',
                'created_at': 'C',
              }),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        expect(
          await storage.getPendingMutations(),
          isNotEmpty,
          reason: 'not server-owned yet → kept queued, not failed',
        );
        expect(results.where((r) => !r.success), isEmpty);

        messageTable.insertServerOwnedRow({
          'id': 'a2',
          'text': 'hi',
          'created_at': 'SERVER',
        });
        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(await storage.getPendingMutations(), isEmpty);
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('a2'),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'an INSERT reducer that aborts on replay and never becomes server-owned '
      'falls back to a terminal failure after the bounded re-check budget',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
        cache.getTableByName('message')!.markSubscribed();

        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(cache),
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbReducerException(
              reducerName: reducerName,
              message: 'The instance encountered a fatal error.',
              result: _rejected(reducerName, 'fatal'),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'a3',
            reducerName: 'push_message',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('message', {'id': 'a3', 'text': 'hi'}),
            ],
          ),
        );

        for (var i = 0; i < 5; i++) {
          await syncer.syncPendingMutations();
        }
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason: 'terminal failure after the bounded budget → dequeued',
        );
        expect(
          results.where((r) => !r.success).map((r) => r.requestId),
          contains('a3'),
          reason: 'a genuinely-failing insert must eventually surface failure',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'a no-optimistic mutation that times out while connected stays queued '
      'and is retried on the next cycle (at-least-once)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final sendCount = <String, int>{};
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: OptimisticStateManager(ClientCache()),
          cache: ClientCache(),
          send: (reducerName, args, {requestId}) async {
            sendCount[requestId ?? reducerName] =
                (sendCount[requestId ?? reducerName] ?? 0) + 1;
            if (sendCount[requestId ?? reducerName] == 1) {
              throw SpacetimeDbTimeoutException(
                'Reducer "$reducerName" timed out',
                elapsed: const Duration(seconds: 10),
              );
            }
            return _committed(reducerName);
          },
        );
        await storage.enqueueMutation(_mutation('r1', 'update_note'));

        await syncer.syncPendingMutations();
        await syncer.syncPendingMutations();

        expect(
          sendCount['r1'],
          equals(2),
          reason:
              'the first send timed out while connected — outcome unverifiable, '
              'so the mutation is kept queued and re-sent next cycle. Loss is '
              'the worse failure; duplicate execution is the accepted '
              'at-least-once tradeoff (no idempotency key exists at the wire)',
        );
        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason: 'the second send committed, so the mutation dequeues',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'retry backoff never collapses to zero at high attempt counts '
      '(overflow guard) and saturates at the max delay',
      () async {
        final syncer = MutationSyncer(
          connection: MockConnection()..setStateSilently(const Connected()),
          storage: InMemoryOfflineStorage(),
          optimisticState: OptimisticStateManager(ClientCache()),
          cache: ClientCache(),
          send: (name, args, {requestId}) async => _committed(name),
        );

        for (final attempt in [0, 1, 4, 51, 63, 200]) {
          final d = syncer.retryDelayForAttempt(attempt);
          expect(
            d.inMilliseconds,
            greaterThan(0),
            reason:
                'attempt $attempt must not collapse to a zero-delay hot loop '
                '(the pre-fix 1<<attempt overflowed negative past ~50)',
          );
          expect(
            d.inMilliseconds,
            lessThanOrEqualTo(60000),
            reason: 'attempt $attempt must not exceed the 60s max delay',
          );
        }
        expect(
          syncer.retryDelayForAttempt(51).inMilliseconds,
          equals(60000),
          reason: 'high attempts saturate at the max, not overflow to 0',
        );
        syncer.cancelRetry();
      },
    );

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

    test(
      'a timed-out UPDATE reads its own optimistic overlay and is '
      'FALSE-confirmed (lost write): the reducer never ran server-side, so it '
      'must stay queued',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'old'});

        final optimisticState = OptimisticStateManager(cache);
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);

        final changes = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'old'},
            {'id': 1, 'content': 'new'},
          ),
        ];
        syncer.onOptimisticChanges('u1', changes);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: changes,
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the server never ran the reducer (send timed out); the '
              'post-state in the cache is the client\'s own optimistic '
              'overlay, not server provenance, so the update must stay queued '
              'for at-least-once retry',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('u1')),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'a timed-out DELETE reads its own optimistic overlay (row removed) and '
      'is FALSE-confirmed (lost write): must stay queued for at-least-once '
      'retry',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'old'});

        final optimisticState = OptimisticStateManager(cache);
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

        final results = <MutationSyncResult>[];
        final sub = syncer.onMutationSyncResult.listen(results.add);

        final changes = [
          OptimisticChange.delete('note', {'id': 1, 'content': 'old'}),
        ];
        syncer.onOptimisticChanges('d1', changes);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'd1',
            reducerName: 'delete_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: changes,
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the server never ran the delete reducer; the row\'s absence in '
              'the cache is the client\'s own optimistic overlay (deleteRow), '
              'not server confirmation, so the delete must stay queued for '
              'retry',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('d1')),
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
