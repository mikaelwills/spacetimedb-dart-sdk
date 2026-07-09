import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

/// RED-FIRST for the 2.3.0 blocker: `TableCache._jsonEquals` compares field
/// values with `!=`, which is REFERENCE equality for nested Map/List. Any no-PK
/// table with a struct/enum/Option/collection column serializes to a nested
/// map, so two structurally-equal rows from separate toJson()/fromJson()
/// round-trips compare UNEQUAL. That breaks the two no-PK identity uses:
///   1. toSerializable(excludeRows:) fails to exclude the optimistic overlay
///      → duplicate row on restart.
///   2. rollback fails to find/remove the optimistic row → phantom row.
///
/// A scalar-only control proves the nested column is the sole cause.

class _Event {
  _Event(this.name, this.meta);
  final String name;
  final Map<String, dynamic> meta;
}

class _EventDecoder extends RowDecoder<_Event> {
  @override
  bool get hasPrimaryKey => false;

  @override
  _Event decode(BsatnDecoder decoder) =>
      _Event(decoder.readString(), const {'type': 'published', 'value': 42});

  @override
  dynamic getPrimaryKey(_Event row) => null;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic> toJson(_Event row) => {
    'name': row.name,
    if (row.meta.isNotEmpty) 'meta': Map<String, dynamic>.of(row.meta),
  };

  @override
  _Event fromJson(Map<String, dynamic> json) => _Event(
    json['name'] as String,
    Map<String, dynamic>.from(json['meta'] ?? {}),
  );
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

Map<String, dynamic> _nestedRow() => {
  'name': 'a',
  'meta': {'type': 'published', 'value': 42},
};

void main() {
  test(
    'no-PK optimistic insert with a NESTED-MAP column does not duplicate across '
    'persist/restart (currently RED: shallow _jsonEquals fails to exclude it)',
    () async {
      final connection = MockConnection();
      connection.setStateSilently(const Connected());
      final storage = InMemoryOfflineStorage();

      final cache1 = ClientCache();
      cache1.registerDecoder<_Event>('events', _EventDecoder());
      final table1 = cache1.getTableByTypedName<_Event>('events');
      final optimistic1 = OptimisticStateManager(cache1);
      final syncer1 = _syncer(connection, storage, cache1, optimistic1);
      await syncer1.ensureInitialized();

      await storage.enqueueMutation(
        PendingMutation(
          requestId: 'r1',
          reducerName: 'push_event',
          encodedArgs: Uint8List(0),
          createdAt: DateTime.now(),
          optimisticChanges: [OptimisticChange.insert('events', _nestedRow())],
        ),
      );
      syncer1.onOptimisticChanges('r1', [
        OptimisticChange.insert('events', _nestedRow()),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(table1.iter().length, 1);

      final cache2 = ClientCache();
      cache2.registerDecoder<_Event>('events', _EventDecoder());
      final table2 = cache2.getTableByTypedName<_Event>('events');
      final optimistic2 = OptimisticStateManager(cache2);
      final syncer2 = _syncer(connection, storage, cache2, optimistic2);

      await syncer2.loadFromOfflineCache();

      expect(
        table2.iter().length,
        1,
        reason:
            'snapshot must exclude the optimistic overlay even though the row '
            'has a nested-map column; otherwise snapshot-load + replay = 2 rows',
      );
    },
  );

  test(
    'rolling back a no-PK optimistic insert with a NESTED-MAP column removes '
    'the row (currently RED: shallow _jsonEquals leaves a phantom)',
    () {
      final cache = ClientCache();
      cache.registerDecoder<_Event>('events', _EventDecoder());
      final table = cache.getTableByTypedName<_Event>('events');
      final optimistic = OptimisticStateManager(cache);

      optimistic.applyOptimisticChanges('r1', [
        OptimisticChange.insert('events', _nestedRow()),
      ]);
      expect(table.iter().length, 1, reason: 'overlay applied');

      optimistic.rollbackOptimisticChanges('r1');

      expect(
        table.iter().length,
        0,
        reason:
            'rollback must remove the no-PK optimistic insert even with a '
            'nested-map column; shallow _jsonEquals leaves it as a phantom',
      );
    },
  );

  test(
    'CONTROL: scalar-only no-PK row excludes + rolls back correctly today '
    '(isolates the nested Map/List as the sole cause)',
    () {
      final cache = ClientCache();
      cache.registerDecoder<_Event>('events', _EventDecoder());
      final table = cache.getTableByTypedName<_Event>('events');
      final optimistic = OptimisticStateManager(cache);

      optimistic.applyOptimisticChanges('r1', [
        OptimisticChange.insert('events', {'name': 'flat'}),
      ]);
      expect(table.iter().length, 1);
      optimistic.rollbackOptimisticChanges('r1');
      expect(
        table.iter().length,
        0,
        reason: 'scalar values compare by value → shallow compare works',
      );
    },
  );
}
