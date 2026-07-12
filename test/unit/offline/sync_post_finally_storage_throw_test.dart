import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

class _ThrowOnNthGetStorage extends InMemoryOfflineStorage {
  _ThrowOnNthGetStorage(this.throwOnCall);
  final int throwOnCall;
  int _calls = 0;

  @override
  Future<List<PendingMutation>> getPendingMutations() async {
    _calls++;
    if (_calls == throwOnCall) {
      throw SpacetimeDbStorageException('disk read failed');
    }
    return super.getPendingMutations();
  }
}

TransactionResult _committed(String reducerName) => TransactionResult(
  status: Committed(),
  timestamp: DateTime.now(),
  reducerName: reducerName,
);

PendingMutation _mutation(String requestId, String reducerName) =>
    PendingMutation(
      requestId: requestId,
      reducerName: reducerName,
      encodedArgs: Uint8List(0),
      createdAt: DateTime.now(),
    );

void main() {
  test('a storage throw in the post-sync getPendingMutations tail is caught, '
      'not left to escape as an unhandled zone error', () async {
    final connection = MockConnection();
    connection.setStateSilently(const Connected());
    final storage = _ThrowOnNthGetStorage(2);
    final cache = ClientCache();
    final optimisticState = OptimisticStateManager(cache);
    final syncer = MutationSyncer(
      connection: connection,
      storage: storage,
      optimisticState: optimisticState,
      cache: cache,
      send: (reducerName, args, {requestId}) async => _committed(reducerName),
    );

    await storage.enqueueMutation(_mutation('r1', 'good_a'));

    await expectLater(
      syncer.syncPendingMutations(),
      completes,
      reason:
          'the second getPendingMutations (the post-finally tail) throws; it '
          'must be caught inside syncPendingMutations, not propagate to the '
          'root zone where a fire-and-forget caller would crash the host',
    );
  });
}
