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

PendingMutation _insertMutation(String requestId, String id) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'create_message',
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
    reducerName: 'merge_message',
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

}
