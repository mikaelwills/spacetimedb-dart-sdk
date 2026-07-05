import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

class _LogRow {
  _LogRow(this.text);
  final String text;
}

class _LogDecoder extends RowDecoder<_LogRow> {
  @override
  bool get hasPrimaryKey => false;

  @override
  _LogRow decode(BsatnDecoder decoder) => _LogRow(decoder.readString());

  @override
  dynamic getPrimaryKey(_LogRow row) => null;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic> toJson(_LogRow row) => {'text': row.text};

  @override
  _LogRow fromJson(Map<String, dynamic> json) => _LogRow(json['text'] as String);
}

MutationSyncer _syncer(
  MockConnection connection,
  InMemoryOfflineStorage storage,
  ClientCache cache,
  OptimisticStateManager optimistic,
) {
  return MutationSyncer(
    connection: connection,
    storage: storage,
    optimisticState: optimistic,
    cache: cache,
    send: (reducerName, args, {requestId}) async => TransactionResult(
      status: Committed(),
      timestamp: DateTime.now(),
      reducerName: reducerName,
    ),
  );
}

void main() {
  test(
    'a no-PK optimistic insert does not duplicate across a persist/restart '
    'cycle: snapshot excludes the overlay, replay re-applies it once',
    () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();

      final cache1 = ClientCache();
      cache1.registerDecoder<_LogRow>('logs', _LogDecoder());
      final table1 = cache1.getTableByTypedName<_LogRow>('logs');
      final optimistic1 = OptimisticStateManager(cache1);
      final syncer1 = _syncer(connection, storage, cache1, optimistic1);
      await syncer1.ensureInitialized();

      await storage.enqueueMutation(
        PendingMutation(
          requestId: 'r1',
          reducerName: 'push_log',
          encodedArgs: Uint8List(0),
          createdAt: DateTime.now(),
          optimisticChanges: [
            OptimisticChange.insert('logs', {'text': 'my-log'}),
          ],
        ),
      );
      syncer1.onOptimisticChanges('r1', [
        OptimisticChange.insert('logs', {'text': 'my-log'}),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(table1.iter().length, 1);

      final cache2 = ClientCache();
      cache2.registerDecoder<_LogRow>('logs', _LogDecoder());
      final table2 = cache2.getTableByTypedName<_LogRow>('logs');
      final optimistic2 = OptimisticStateManager(cache2);
      final syncer2 = _syncer(connection, storage, cache2, optimistic2);

      await syncer2.loadFromOfflineCache();

      expect(
        table2.iter().length,
        1,
        reason:
            'snapshot must exclude the optimistic overlay row so that loading '
            'the snapshot + replaying the pending mutation yields exactly one '
            'copy, not two',
      );
      expect(table2.iter().single.text, 'my-log');
    },
  );
}
