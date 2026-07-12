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

class _CountingThrowOnceDequeueStorage extends InMemoryOfflineStorage {
  int dequeueAttempts = 0;

  @override
  Future<void> dequeueMutation(String requestId) async {
    dequeueAttempts++;
    if (dequeueAttempts == 1) {
      throw SpacetimeDbStorageException('disk failure on first dequeue');
    }
    await super.dequeueMutation(requestId);
  }
}

void main() {
  group('timeout confirm overlay — class variants', () {
    test(
      'V1 stacked UPDATE overlays on one key: an earlier overlay confirmed, a '
      'later one times out with a pending overlay still present → kept queued',
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

        final firstChanges = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'old'},
            {'id': 1, 'content': 'first'},
          ),
        ];
        final secondChanges = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'first'},
            {'id': 1, 'content': 'second'},
          ),
        ];
        syncer.onOptimisticChanges('u1', firstChanges);
        syncer.onOptimisticChanges('u2', secondChanges);
        optimisticState.confirmOptimisticChange('u1');

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u2',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: secondChanges,
          ),
        );

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'u2 overlay is still pending on key 1; the cache value is the '
              'client prediction, not server provenance — keep queued',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V2 UPDATE whose overlay was confirmed while still queued, row not '
      'server-owned under its pk → kept queued (confirmed-overlay axis)',
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
        optimisticState.confirmOptimisticChange('u1');

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
              'the send timed out and the row is NOT server-owned under its '
              'pk; the "new" value in the cache is a lingering optimistic '
              'write left by a confirmed-while-queued overlay, not server '
              'provenance, so the update must stay queued',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('u1')),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V3 one mutation with UPDATE on key 1 + DELETE on key 2 (adjacent keys), '
      'both overlays pending on timeout → kept queued (per-change guard)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'old'});
        noteTable.insertServerOwnedRow({'id': 2, 'content': 'doomed'});

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

        final changes = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'old'},
            {'id': 1, 'content': 'new'},
          ),
          OptimisticChange.delete('note', {'id': 2, 'content': 'doomed'}),
        ];
        syncer.onOptimisticChanges('m1', changes);

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'm1',
            reducerName: 'multi_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: changes,
          ),
        );

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'both the UPDATE (key 1) and DELETE (key 2) overlays are pending '
              '— the guard is per-change, so the whole mutation stays queued',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V4 DELETE whose overlay was confirmed while still queued, no server '
      'confirmation → kept queued (confirmed-overlay axis)',
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
        optimisticState.confirmOptimisticChange('d1');

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
              'the delete reducer never ran server-side; the row is absent '
              'only because of the (now-confirmed) optimistic removal — not a '
              'server delete — so it must stay queued',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('d1')),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V5 timeout while the socket drops mid-send with a pending UPDATE '
      'overlay → kept queued',
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
            connection.setStateSilently(const Disconnected());
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );

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

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the socket dropped during the send; the pending overlay means '
              'the cache value is the client prediction — keep queued',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V6 regression: a genuinely-landed UPDATE (server-owned, no pending '
      'overlay) whose ACK timed out is still confirmed (guard does not '
      'over-block)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'new'});

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
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason:
              'the row is genuinely server-owned with the update post-state '
              'and no overlay was ever applied — the guard must not over-block '
              'a real landing',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('u1'),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V7 record self-heals: an UPDATE overlay confirmed-while-queued is kept '
      'queued on a timed-out flush, then a retry that genuinely commits clears '
      'the confirmed-overlay record AND dequeues',
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
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            sends++;
            if (sends == 1) {
              throw SpacetimeDbTimeoutException(
                'timed out',
                elapsed: const Duration(seconds: 10),
              );
            }
            return _committed(reducerName);
          },
        );

        final changes = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'old'},
            {'id': 1, 'content': 'new'},
          ),
        ];
        syncer.onOptimisticChanges('u1', changes);
        optimisticState.confirmOptimisticChange('u1');

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
        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason: 'first flush timed out with the confirmed overlay → queued',
        );

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason: 'the retry committed — the mutation dequeues',
        );
        expect(
          optimisticState.wasOverlayConfirmedForKey('u1', 'note', 1),
          isFalse,
          reason:
              'the send-success clearConfirmedOverlay must fire so the trace '
              'is self-healing, not a permanent stuck flag',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V8 requestId-scoped, no cross-mutation leak: mutation a\'s overlay '
      'confirmed-while-queued must not suppress a SEPARATE mutation b\'s real '
      'landing on the same key',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'zero'});

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

        final aChanges = [
          OptimisticChange.update(
            'note',
            {'id': 1, 'content': 'zero'},
            {'id': 1, 'content': 'a-value'},
          ),
        ];
        syncer.onOptimisticChanges('a', aChanges);
        optimisticState.confirmOptimisticChange('a');
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'b-landed'});

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'b',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.update(
                'note',
                {'id': 1, 'content': 'a-value'},
                {'id': 1, 'content': 'b-landed'},
              ),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason:
              'b is genuinely server-owned with b\'s post-state; the guard '
              'reads _confirmedOverlayKeys[b] (empty), not a\'s record, so b '
              'confirms and dequeues',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('b'),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V9 a genuinely-landed timeout whose durable dequeue throws stays queued '
      'and recovers on the next flush once storage heals',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = _CountingThrowOnceDequeueStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'new'});

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

        await expectLater(
          syncer.syncPendingMutations(),
          throwsA(isA<SpacetimeDbStorageException>()),
        );
        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the dequeue failed so the mutation stays queued — no lost write',
        );

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason:
              'a landed resolution is decided by server-owned content, so the '
              'next flush re-resolves landed and dequeues cleanly once storage '
              'recovers',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V10 requestId reuse after a full drain: after u1 genuinely lands and '
      'dequeues, a NEW mutation reusing requestId u1 with a fresh pending, '
      'not-server-owned overlay is kept queued (no stale record poisons it)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'landed'});

        final optimisticState = OptimisticStateManager(cache);
        var sends = 0;
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            sends++;
            if (sends == 1) return _committed(reducerName);
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
                {'id': 1, 'content': 'landed'},
              ),
            ],
          ),
        );
        await syncer.syncPendingMutations();
        expect(await storage.getPendingMutations(), isEmpty);

        noteTable.insertServerOwnedRow({'id': 2, 'content': 'base'});
        final reuseChanges = [
          OptimisticChange.update(
            'note',
            {'id': 2, 'content': 'base'},
            {'id': 2, 'content': 'reuse'},
          ),
        ];
        syncer.onOptimisticChanges('u1', reuseChanges);
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: reuseChanges,
          ),
        );

        await syncer.syncPendingMutations();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the reused-id mutation has a fresh pending overlay on key 2 that '
              'is not server-owned; no stale _confirmedOverlayKeys[u1] survives '
              'the clean drain to false-confirm it',
        );
        syncer.cancelRetry();
      },
    );

    test(
      'V11 abort-confirm short-circuit: an UPDATE whose overlay was '
      'confirmed-while-queued and is genuinely server-owned in the cache is '
      're-sent, and the server aborts it as a redundant/unique-key collision '
      'on the already-committed row — it must be confirmed (success:true) and '
      'dequeued, NOT surfaced as a failure',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'new'});

        final optimisticState = OptimisticStateManager(cache);
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbReducerException(
              reducerName: reducerName,
              message: 'unique key collision',
              result: _rejected(reducerName, 'unique key collision'),
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
        optimisticState.confirmOptimisticChange('u1');

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
          isEmpty,
          reason:
              'a genuinely-committed write that aborts on re-send as redundant '
              'must be confirmed and dequeued',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('u1'),
          reason:
              'a genuinely-committed write that aborts on re-send as redundant '
              'must be confirmed success, not surfaced as a failure',
        );
        expect(
          results.where((r) => !r.success).map((r) => r.requestId),
          isNot(contains('u1')),
          reason: 'no spurious failedCount bump for an already-landed write',
        );
        syncer.cancelRetry();
      },
    );
  });
}
