import 'dart:async';
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

PendingMutation _insertMutation(String requestId, String id) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'push_message',
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
    optimisticChanges: [
      OptimisticChange.insert('message', {'id': id, 'text': 'hi'}),
    ],
  );
}

PendingMutation _updateMutation(String requestId, String id) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'update_message',
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
    optimisticChanges: [
      OptimisticChange.update(
        'message',
        {'id': id, 'text': 'old'},
        {'id': id, 'text': 'new'},
      ),
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

class _Harness {
  _Harness({OfflineStorage? storage, bool timeoutInsteadOfAbort = false})
    : storage = storage ?? InMemoryOfflineStorage() {
    connection = MockConnection();
    connection.setStateSilently(const Connected());
    cache = ClientCache();
    cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
    table = cache.getTableByName('message')!;
    table.markSubscribed();
    syncer = MutationSyncer(
      connection: connection,
      storage: this.storage,
      optimisticState: OptimisticStateManager(cache),
      cache: cache,
      send: (reducerName, args, {requestId}) async {
        sends++;
        if (timeoutInsteadOfAbort) {
          throw SpacetimeDbTimeoutException(
            'timed out',
            elapsed: Duration.zero,
          );
        }
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
  }

  late final MockConnection connection;
  final OfflineStorage storage;
  late final ClientCache cache;
  late final TableCache<dynamic> table;
  late final MutationSyncer syncer;
  int sends = 0;

  void grantOwnership(String id) {
    table.insertServerOwnedRow({'id': id, 'text': 'hi'});
  }
}

void main() {
  test(
    'an abort-recheck pause stashes the awaited PK and '
    'notifyOwnershipGained for it runs one immediate confirm cycle',
    () async {
      final h = _Harness();
      await h.storage.enqueueMutation(_insertMutation('r1', 'p1'));
      await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
      expect(h.sends, equals(1));
      expect(h.syncer.syncState.status, equals(SyncStatus.waitingToRetry));

      h.grantOwnership('p1');
      h.syncer.notifyOwnershipGained('message', 'p1');
      await pumpEventQueue();

      expect(
        h.sends,
        equals(2),
        reason: 'the notify must run one immediate replay, not wait 5s',
      );
      expect(await h.storage.getPendingMutations(), isEmpty);
      expect(h.syncer.syncState.status, equals(SyncStatus.idle));
      expect(h.syncer.syncState.nextRetryAt, isNull);
      h.syncer.cancelRetry();
    },
  );

  test('a gain for a non-awaited PK or table never triggers a cycle', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation('r1', 'p1'));
    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
    expect(h.sends, equals(1));

    h.syncer.notifyOwnershipGained('message', 'other-pk');
    h.syncer.notifyOwnershipGained('folder', 'p1');
    await pumpEventQueue();

    expect(h.sends, equals(1));
    expect(await h.storage.getPendingMutations(), hasLength(1));
    h.syncer.cancelRetry();
  });

  test('a gain with no pause active never triggers a cycle', () async {
    final h = _Harness();
    h.syncer.notifyOwnershipGained('message', 'p1');
    await pumpEventQueue();
    expect(h.sends, equals(0));
    h.syncer.cancelRetry();
  });

  test('an update-only pause stashes nothing; its PK gaining an owner does '
      'not trigger (timer backstop owns that case)', () async {
    final h = _Harness(timeoutInsteadOfAbort: true);
    await h.storage.enqueueMutation(_updateMutation('r1', 'p1'));
    h.table.insertRow({'id': 'p1', 'text': 'stale'});
    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
    expect(h.sends, equals(1));
    expect(h.syncer.syncState.status, isNot(SyncStatus.idle));

    h.grantOwnership('p1');
    h.syncer.notifyOwnershipGained('message', 'p1');
    await pumpEventQueue();

    expect(h.sends, equals(1));
    expect(await h.storage.getPendingMutations(), hasLength(1));
    h.syncer.cancelRetry();
  });

  test('a notify landing in the finalize window latches and coalesces into '
      'one follow-up cycle', () async {
    final storage = _ReadHookStorage();
    final h = _Harness(storage: storage);
    storage.onRead = (read) {
      if (read == 2) {
        h.grantOwnership('p1');
        h.syncer.notifyOwnershipGained('message', 'p1');
      }
    };
    await storage.enqueueMutation(_insertMutation('r1', 'p1'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(
      h.sends,
      equals(2),
      reason:
          'the finalize-window notify must latch via _resyncRequested '
          'and run exactly one coalesced follow-up cycle',
    );
    expect(await storage.getPendingMutations(), isEmpty);
    h.syncer.cancelRetry();
  });

  test('a spurious notify (awaited PK reported without real ownership) '
      're-pauses on the backoff ladder with a fresh ETA', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation('r1', 'p1'));
    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
    final firstEta = h.syncer.syncState.nextRetryAt;
    expect(firstEta, isNotNull);

    h.syncer.notifyOwnershipGained('message', 'p1');
    await pumpEventQueue();

    expect(h.sends, equals(2));
    expect(await h.storage.getPendingMutations(), hasLength(1));
    expect(h.syncer.syncState.status, equals(SyncStatus.waitingToRetry));
    expect(h.syncer.syncState.nextRetryAt, isNotNull);
    expect(h.syncer.syncState.nextRetryAt!.isAfter(firstEta!), isTrue);
    h.syncer.cancelRetry();
  });

  test('notify after dispose is a no-op', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation('r1', 'p1'));
    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));
    await h.syncer.dispose();
    h.syncer.notifyOwnershipGained('message', 'p1');
    await pumpEventQueue();
    expect(h.sends, equals(1));
  });
}
