import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _abortedRequestId = 'r-aborted';

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

PendingMutation _mutation(
  String requestId,
  String reducerName, [
  List<OptimisticChange>? changes,
]) {
  return PendingMutation(
    requestId: requestId,
    reducerName: reducerName,
    encodedArgs: Uint8List(0),
    createdAt: DateTime.now(),
    optimisticChanges: changes,
  );
}

OptimisticChange _textChange(String id, String from, String to) {
  return OptimisticChange.update(
    'message',
    {'id': id, 'text': from},
    {'id': id, 'text': to},
  );
}

PendingMutation _insertMutation(String requestId, String id) {
  return _mutation(requestId, 'create_message', [
    OptimisticChange.insert('message', {'id': id, 'text': 'hi'}),
  ]);
}

PendingMutation _updateMutation(String requestId, String id) {
  return _mutation(requestId, 'merge_message', [
    _textChange(id, 'old', 'new'),
  ]);
}

PendingMutation _twoRowUpdateMutation(
  String requestId, {
  required String firstId,
  required String secondId,
}) {
  return _mutation(requestId, 'swap_messages', [
    _textChange(firstId, 'a', 'b'),
    _textChange(secondId, 'b', 'a'),
  ]);
}

PendingMutation _keylessMutation(String requestId) {
  return _mutation(requestId, 'move_message');
}

TransactionResult _committed(String reducerName) {
  return TransactionResult(
    status: Committed(),
    timestamp: DateTime.now(),
    reducerName: reducerName,
  );
}

class _Harness {
  _Harness() {
    connection = MockConnection();
    connection.setStateSilently(const Connected());
    cache = ClientCache();
    cache.registerDecoder<Map<String, dynamic>>('message', _MapDecoder());
    cache.getTableByName('message')!.markSubscribed();
    optimisticState = OptimisticStateManager(cache);
    syncer = MutationSyncer(
      connection: connection,
      storage: storage,
      optimisticState: optimisticState,
      cache: cache,
      send: (reducerName, args, {requestId}) async {
        sentRequestIds.add(requestId!);
        if (requestId == _abortedRequestId) {
          throw SpacetimeDbReducerException(
            reducerName: reducerName,
            message: 'Not found',
            result: TransactionResult(
              status: InternalError('Not found'),
              timestamp: DateTime.now(),
              reducerName: reducerName,
            ),
          );
        }
        return _committed(reducerName);
      },
    );
  }

  late final MockConnection connection;
  final InMemoryOfflineStorage storage = InMemoryOfflineStorage();
  late final ClientCache cache;
  late final OptimisticStateManager optimisticState;
  late final MutationSyncer syncer;
  final List<String> sentRequestIds = [];
}

void main() {
  test('a rejected insert at the head does not stop an unrelated mutation '
      'behind it from sending in the same pass', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation(_abortedRequestId, 'p1'));
    await h.storage.enqueueMutation(_insertMutation('r2', 'p2'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals([_abortedRequestId, 'r2']));
    final pending = await h.storage.getPendingMutations();
    expect(pending.map((m) => m.requestId), equals([_abortedRequestId]));
    h.syncer.cancelRetry();
  });

  test('a mutation on the same row as the held insert waits for it and is '
      'not sent', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation(_abortedRequestId, 'p1'));
    await h.storage.enqueueMutation(_updateMutation('r2', 'p1'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals([_abortedRequestId]));
    final pending = await h.storage.getPendingMutations();
    expect(
      pending.map((m) => m.requestId),
      equals([_abortedRequestId, 'r2']),
    );
    h.syncer.cancelRetry();
  });

  test('a mutation sharing a row with a waiting mutation waits behind it, '
      'so the server never sees them out of order', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation(_abortedRequestId, 'p1'));
    await h.storage.enqueueMutation(
      _twoRowUpdateMutation('r2', firstId: 'p1', secondId: 'p2'),
    );
    await h.storage.enqueueMutation(_updateMutation('r3', 'p2'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals([_abortedRequestId]));
    final pending = await h.storage.getPendingMutations();
    expect(
      pending.map((m) => m.requestId),
      equals([_abortedRequestId, 'r2', 'r3']),
    );
    h.syncer.cancelRetry();
  });

  test('a mutation with no optimistic rows waits behind a held insert, '
      'since nothing shows it is unrelated', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation(_abortedRequestId, 'p1'));
    await h.storage.enqueueMutation(_keylessMutation('r2'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals([_abortedRequestId]));
    final pending = await h.storage.getPendingMutations();
    expect(
      pending.map((m) => m.requestId),
      equals([_abortedRequestId, 'r2']),
    );
    h.syncer.cancelRetry();
  });

  test('once a keyless mutation waits, every mutation behind it waits too',
      () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation(_abortedRequestId, 'p1'));
    await h.storage.enqueueMutation(_keylessMutation('r2'));
    await h.storage.enqueueMutation(_updateMutation('r3', 'p3'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals([_abortedRequestId]));
    final pending = await h.storage.getPendingMutations();
    expect(
      pending.map((m) => m.requestId),
      equals([_abortedRequestId, 'r2', 'r3']),
    );
    h.syncer.cancelRetry();
  });

  test('a keyless mutation still sends when nothing is held', () async {
    final h = _Harness();
    await h.storage.enqueueMutation(_insertMutation('r1', 'p1'));
    await h.storage.enqueueMutation(_keylessMutation('r2'));

    await h.syncer.syncPendingMutations().timeout(const Duration(seconds: 5));

    expect(h.sentRequestIds, equals(['r1', 'r2']));
    expect(await h.storage.getPendingMutations(), isEmpty);
    h.syncer.cancelRetry();
  });
}
