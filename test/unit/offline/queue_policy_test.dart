import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';
import '../../mocks/mock_connection.dart';

TransactionResult _committed(String reducerName) {
  return TransactionResult(
    status: Committed(),
    timestamp: DateTime.now(),
    reducerName: reducerName,
  );
}

Note _note(int id, String content) => Note(
  id: id,
  title: 'Note $id',
  content: content,
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

PendingMutation _mutation(
  String requestId,
  String reducerName, {
  DateTime? createdAt,
  List<OptimisticChange>? optimisticChanges,
}) {
  return PendingMutation(
    requestId: requestId,
    reducerName: reducerName,
    encodedArgs: Uint8List(0),
    createdAt: createdAt ?? DateTime.now(),
    optimisticChanges: optimisticChanges,
  );
}

class _Harness {
  final MockConnection connection;
  final InMemoryOfflineStorage storage;
  final ClientCache cache;
  final OptimisticStateManager optimisticState;
  final MutationSyncer syncer;
  final ReducerCaller caller;
  final List<String> sentReducers = [];

  _Harness._(
    this.connection,
    this.storage,
    this.cache,
    this.optimisticState,
    this.syncer,
    this.caller,
  );

  factory _Harness({OfflineQueuePolicy policy = const OfflineQueuePolicy()}) {
    final connection = MockConnection();
    connection.setStateSilently(const Disconnected());
    final storage = InMemoryOfflineStorage();
    final cache = ClientCache();
    cache.registerDecoder<Note>('note', NoteDecoder());
    final optimisticState = OptimisticStateManager(cache);
    late _Harness harness;
    final syncer = MutationSyncer(
      connection: connection,
      storage: storage,
      optimisticState: optimisticState,
      cache: cache,
      send: (reducerName, args, {requestId}) async {
        harness.sentReducers.add(reducerName);
        return _committed(reducerName);
      },
      policy: policy,
    );
    final caller = ReducerCaller(
      connection,
      offlineStorage: storage,
      mutationHandler: syncer,
      policy: policy,
    );
    harness = _Harness._(
      connection,
      storage,
      cache,
      optimisticState,
      syncer,
      caller,
    );
    return harness;
  }

  TableCache<Note> get noteTable => cache.getTableByTypedName<Note>('note');

  void goOnline() => connection.setStateSilently(const Connected());
}

void main() {
  group('defaults preserve current behavior', () {
    test('30 day old mutation still replays with no policy set', () async {
      final harness = _Harness();
      await harness.storage.enqueueMutation(
        _mutation(
          'r-old',
          'update_note',
          createdAt: DateTime.now().subtract(const Duration(days: 30)),
        ),
      );

      harness.goOnline();
      await harness.syncer.syncPendingMutations();

      expect(harness.sentReducers, equals(['update_note']));
      expect(harness.syncer.syncState.failedCount, equals(0));
      expect(await harness.storage.getPendingMutations(), isEmpty);
    });
  });

  group('TTL expiry at flush', () {
    test('expired mutation is discarded, rolled back, and surfaced', () async {
      final harness = _Harness(
        policy: const OfflineQueuePolicy(maxMutationAge: Duration(hours: 1)),
      );
      harness.noteTable.insertRow(_note(1, 'v1'));
      harness.optimisticState.applyOptimisticChanges('r-old', [
        OptimisticChange.update(
          'note',
          _note(1, 'v1').toJson(),
          _note(1, 'stale edit').toJson(),
        ),
      ]);
      await harness.storage.enqueueMutation(
        _mutation(
          'r-old',
          'update_note',
          createdAt: DateTime.now().subtract(const Duration(hours: 2)),
          optimisticChanges: [
            OptimisticChange.update(
              'note',
              _note(1, 'v1').toJson(),
              _note(1, 'stale edit').toJson(),
            ),
          ],
        ),
      );
      await harness.storage.enqueueMutation(
        _mutation('r-fresh', 'create_note'),
      );

      harness.goOnline();
      await harness.syncer.syncPendingMutations();

      expect(
        harness.sentReducers,
        equals(['create_note']),
        reason: 'expired mutation must never reach the wire',
      );
      expect(await harness.storage.getPendingMutations(), isEmpty);
      expect(
        harness.noteTable.getRow(1)?.content,
        equals('v1'),
        reason: 'expired optimistic edit must be rolled back',
      );
      final state = harness.syncer.syncState;
      expect(state.failedCount, equals(1));
      expect(state.recentFailures.single.expired, isTrue);
      expect(state.recentFailures.single.requestId, equals('r-old'));
    });
  });

  group('queue bound at enqueue', () {
    test('rejectNew throws before applying optimistic changes', () async {
      final harness = _Harness(
        policy: const OfflineQueuePolicy(maxQueueLength: 3),
      );
      harness.noteTable.insertRow(_note(1, 'v1'));
      for (var i = 0; i < 3; i++) {
        await harness.caller.call('create_note', Uint8List(0));
      }
      expect(await harness.storage.getPendingMutations(), hasLength(3));

      await expectLater(
        harness.caller.call(
          'update_note',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.update(
              'note',
              _note(1, 'v1').toJson(),
              _note(1, 'refused edit').toJson(),
            ),
          ],
        ),
        throwsA(isA<SpacetimeDbQueueFullException>()),
      );

      expect(await harness.storage.getPendingMutations(), hasLength(3));
      expect(
        harness.noteTable.getRow(1)?.content,
        equals('v1'),
        reason: 'refused call must not leave an optimistic edit behind',
      );
    });

    test(
      'dropOldest evicts and rolls back the oldest, keeps FIFO order',
      () async {
        final harness = _Harness(
          policy: const OfflineQueuePolicy(
            maxQueueLength: 3,
            overflow: OverflowStrategy.dropOldest,
          ),
        );
        harness.noteTable.insertRow(_note(1, 'v1'));

        final dropped = <MutationSyncResult>[];
        final sub = harness.syncer.onMutationSyncResult.listen(dropped.add);

        final first = await harness.caller.call(
          'update_note',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.update(
              'note',
              _note(1, 'v1').toJson(),
              _note(1, 'first edit').toJson(),
            ),
          ],
        );
        await harness.caller.call('create_note', Uint8List(0));
        await harness.caller.call('delete_note', Uint8List(0));
        await harness.caller.call('no_op', Uint8List(0));
        await Future.delayed(Duration.zero);
        await sub.cancel();

        final pending = await harness.storage.getPendingMutations();
        expect(pending, hasLength(3));
        expect(
          pending.map((m) => m.reducerName),
          equals(['create_note', 'delete_note', 'no_op']),
          reason: 'oldest dropped, remaining order preserved',
        );
        expect(
          pending.map((m) => m.requestId),
          isNot(contains(first.pendingRequestId)),
        );
        expect(
          harness.noteTable.getRow(1)?.content,
          equals('v1'),
          reason: 'dropped mutation optimistic edit must be rolled back',
        );
        expect(dropped, hasLength(1));
        expect(dropped.single.success, isFalse);
        expect(harness.syncer.syncState.failedCount, equals(1));
      },
    );
  });

  group('onBeforeReplay veto', () {
    test('vetoed mutations discard, others replay in order', () async {
      final hookCalls = <String>[];
      final harness = _Harness(
        policy: OfflineQueuePolicy(
          onBeforeReplay: (m) async {
            hookCalls.add(m.requestId);
            return m.reducerName == 'update_note'
                ? ReplayDecision.discard
                : ReplayDecision.replay;
          },
        ),
      );
      await harness.storage.enqueueMutation(_mutation('r1', 'create_note'));
      await harness.storage.enqueueMutation(_mutation('r2', 'update_note'));
      await harness.storage.enqueueMutation(_mutation('r3', 'delete_note'));

      harness.goOnline();
      await harness.syncer.syncPendingMutations();

      expect(
        hookCalls,
        equals(['r1', 'r2', 'r3']),
        reason: 'hook fires exactly once per mutation, in FIFO order',
      );
      expect(harness.sentReducers, equals(['create_note', 'delete_note']));
      expect(await harness.storage.getPendingMutations(), isEmpty);
      final state = harness.syncer.syncState;
      expect(state.failedCount, equals(1));
      expect(state.recentFailures.single.requestId, equals('r2'));
      expect(state.recentFailures.single.expired, isFalse);
    });

    test('throwing hook fails open and replays', () async {
      final harness = _Harness(
        policy: OfflineQueuePolicy(
          onBeforeReplay: (m) => throw StateError('hook bug'),
        ),
      );
      await harness.storage.enqueueMutation(_mutation('r1', 'create_note'));

      harness.goOnline();
      await harness.syncer.syncPendingMutations();

      expect(harness.sentReducers, equals(['create_note']));
      expect(harness.syncer.syncState.failedCount, equals(0));
    });
  });
}
