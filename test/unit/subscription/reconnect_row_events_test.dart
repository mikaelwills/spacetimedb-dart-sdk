import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

typedef _Item = ({int id, String name});
typedef _Tagged = ({int id, List<int> tags});

void _writeItem(BsatnEncoder encoder, _Item row) {
  encoder.writeU32(row.id);
  encoder.writeString(row.name);
}

void _writeTagged(BsatnEncoder encoder, _Tagged row) {
  encoder.writeU32(row.id);
  encoder.writeArray<int>(row.tags, encoder.writeU32);
}

Uint8List _subscribeApplied<R>({
  required int querySetId,
  required String table,
  required List<R> rows,
  required void Function(BsatnEncoder, R) writeRow,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(table);
  final offsets = <int>[];
  final rowsEncoder = BsatnEncoder();
  for (final row in rows) {
    offsets.add(rowsEncoder.toBytes().length);
    writeRow(rowsEncoder, row);
  }
  final rowsData = rowsEncoder.toBytes();
  encoder.writeU8(1);
  encoder.writeU32(offsets.length);
  for (final offset in offsets) {
    encoder.writeU64(Int64(offset));
  }
  encoder.writeU32(rowsData.length);
  encoder.writeBytes(rowsData);
  return encoder.toBytes();
}

Uint8List _items(int querySetId, List<_Item> rows) => _subscribeApplied(
  querySetId: querySetId,
  table: 'item',
  rows: rows,
  writeRow: _writeItem,
);

Uint8List _unsubscribeAppliedItems(int querySetId, List<_Item> dropped) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(2);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU8(0);
  encoder.writeU32(1);
  encoder.writeString('item');
  final offsets = <int>[];
  final rowsEncoder = BsatnEncoder();
  for (final row in dropped) {
    offsets.add(rowsEncoder.toBytes().length);
    _writeItem(rowsEncoder, row);
  }
  final rowsData = rowsEncoder.toBytes();
  encoder.writeU8(1);
  encoder.writeU32(offsets.length);
  for (final offset in offsets) {
    encoder.writeU64(Int64(offset));
  }
  encoder.writeU32(rowsData.length);
  encoder.writeBytes(rowsData);
  return encoder.toBytes();
}

Uint8List _tagged(int querySetId, List<_Tagged> rows) => _subscribeApplied(
  querySetId: querySetId,
  table: 'tagged',
  rows: rows,
  writeRow: _writeTagged,
);

class _ItemDecoder extends RowDecoder<_Item> {
  @override
  _Item decode(BsatnDecoder decoder) =>
      (id: decoder.readU32(), name: decoder.readString());

  @override
  dynamic getPrimaryKey(_Item row) => row.id;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(_Item row) => {'id': row.id, 'name': row.name};

  @override
  _Item? fromJson(Map<String, dynamic> json) =>
      (id: json['id'] ?? 0, name: json['name'] ?? '');
}

class _TaggedDecoder extends RowDecoder<_Tagged> {
  @override
  _Tagged decode(BsatnDecoder decoder) =>
      (id: decoder.readU32(), tags: decoder.readArray<int>(decoder.readU32));

  @override
  dynamic getPrimaryKey(_Tagged row) => row.id;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(_Tagged row) => {'id': row.id, 'tags': row.tags};

  @override
  _Tagged? fromJson(Map<String, dynamic> json) =>
      (id: json['id'] ?? 0, tags: List<int>.from(json['tags'] ?? const []));
}

class _Recorder<T> {
  final inserts = <TableInsertEvent<T>>[];
  final updates = <TableUpdateEvent<T>>[];
  final deletes = <TableDeleteEvent<T>>[];

  _Recorder(TableCache<T> table) {
    table.onInsert.listen(inserts.add);
    table.onUpdate.listen(updates.add);
    table.onDelete.listen(deletes.add);
  }

  int get total => inserts.length + updates.length + deletes.length;
}

TableCache<T> _register<T>(
  SubscriptionManager manager,
  String name,
  RowDecoder<T> decoder,
) {
  manager.cache.registerDecoder<T>(name, decoder);
  return manager.cache.getTableByTypedName<T>(name);
}

void main() {
  late MockConnection connection;
  late SubscriptionManager manager;

  Future<void> bounce() async {
    await connection.disconnect();
    await connection.connect();
    await pumpEventQueue();
  }

  group('reconnect snapshot reconciles against the cache', () {
    late TableCache<_Item> item;

    setUp(() async {
      connection = MockConnection();
      manager = SubscriptionManager(connection);
      item = _register(manager, 'item', _ItemDecoder());
      await connection.connect();
      final pending = manager.subscribe(['SELECT * FROM item']);
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b'), (id: 3, name: 'c')]),
      );
      await pending.timeout(_timeout);
    });

    tearDown(() async => manager.dispose());

    test('an unchanged row fires no event', () async {
      final events = _Recorder(item);
      await bounce();
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b'), (id: 3, name: 'c')]),
      );
      await pumpEventQueue();

      expect(events.total, 0);
      expect(item.count(), 3);
    });

    test('a changed row fires one update carrying old and new', () async {
      final events = _Recorder(item);
      await bounce();
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'B'), (id: 3, name: 'c')]),
      );
      await pumpEventQueue();

      expect(events.inserts, isEmpty);
      expect(events.deletes, isEmpty);
      expect(events.updates, hasLength(1));
      expect(events.updates.single.oldRow, (id: 2, name: 'b'));
      expect(events.updates.single.newRow, (id: 2, name: 'B'));
      expect(events.updates.single.context.event, isA<SubscribeAppliedEvent>());
    });

    test('a row new to the cache fires one insert', () async {
      final events = _Recorder(item);
      await bounce();
      connection.simulateIncoming(
        _items(1, [
          (id: 1, name: 'a'),
          (id: 2, name: 'b'),
          (id: 3, name: 'c'),
          (id: 4, name: 'd'),
        ]),
      );
      await pumpEventQueue();

      expect(events.updates, isEmpty);
      expect(events.deletes, isEmpty);
      expect(events.inserts.map((e) => e.row), [(id: 4, name: 'd')]);
    });

    test('a row the server deleted while offline fires one delete at '
        'finalize', () async {
      final events = _Recorder(item);
      await bounce();
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 3, name: 'c')]),
      );
      await pumpEventQueue();

      expect(item.find(2), isNull);
      expect(events.inserts, isEmpty);
      expect(events.updates, isEmpty);
      expect(events.deletes, hasLength(1));
      expect(events.deletes.single.row, (id: 2, name: 'b'));
      expect(events.deletes.single.context.event, isA<SubscribeAppliedEvent>());
      expect(
        item.lastBatch.value?.events.single,
        isA<TableDeleteEvent<_Item>>(),
      );
    });

    test('a skipped finalize evicts nothing and fires no delete', () async {
      final second = manager.subscribe(['SELECT * FROM item WHERE id > 1']);
      connection.simulateIncoming(
        _items(2, [(id: 2, name: 'b'), (id: 3, name: 'c')]),
      );
      await second.timeout(_timeout);
      final events = _Recorder(item);

      await connection.disconnect();
      await connection.connect();
      await pumpEventQueue();
      connection.simulateIncoming(_items(1, [(id: 1, name: 'a')]));
      await pumpEventQueue();
      await connection.disconnect();
      await pumpEventQueue();

      expect(item.find(2), isNotNull);
      expect(events.deletes, isEmpty);
    });
  });

  group('reconnect evictions inside the snapshot', () {
    test('a retained row the server deleted fires one delete', () async {
      connection = MockConnection();
      manager = SubscriptionManager(connection, retainRowsOnUnsubscribe: true);
      final item = _register(manager, 'item', _ItemDecoder());
      addTearDown(manager.dispose);
      await connection.connect();

      final first = manager.subscribe(['SELECT * FROM item']);
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      final firstId = await first.timeout(_timeout);
      manager.unsubscribe(firstId);
      expect(item.retainedTagsFor(1), isNotEmpty);

      await connection.disconnect();
      final second = manager.subscribe(['SELECT * FROM item']);
      await connection.connect();
      await pumpEventQueue();
      final events = _Recorder(item);

      connection.simulateIncoming(_items(2, [(id: 1, name: 'a')]));
      await second.timeout(_timeout);
      await pumpEventQueue();

      expect(item.find(2), isNull);
      expect(events.inserts, isEmpty);
      expect(events.updates, isEmpty);
      expect(events.deletes.map((e) => e.row), [(id: 2, name: 'b')]);
    });

    test('an unsubscribe during the reconnect window fires deletes for the '
        'rows it evicts', () async {
      connection = MockConnection();
      manager = SubscriptionManager(connection);
      final item = _register(manager, 'item', _ItemDecoder());
      addTearDown(manager.dispose);
      await connection.connect();

      final pending = manager.subscribe(['SELECT * FROM item']);
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      final id = await pending.timeout(_timeout);
      final events = _Recorder(item);

      await bounce();
      manager.unsubscribe(id);
      await pumpEventQueue();

      expect(item.count(), 0);
      expect(
        events.deletes.map((e) => e.row),
        unorderedEquals([(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
    });

    test('unsubscribe(sendDroppedRows: true) in the reconnect window fires '
        'one delete per row, not two', () async {
      connection = MockConnection();
      manager = SubscriptionManager(connection);
      final item = _register(manager, 'item', _ItemDecoder());
      addTearDown(manager.dispose);
      await connection.connect();

      final all = manager.subscribe(['SELECT * FROM item']);
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      final allId = await all.timeout(_timeout);
      final other = manager.subscribe(['SELECT * FROM item WHERE id > 100']);
      connection.simulateIncoming(_items(2, const []));
      await other.timeout(_timeout);

      await bounce();
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      await pumpEventQueue();
      final events = _Recorder(item);

      manager.unsubscribe(allId, sendDroppedRows: true);
      connection.simulateIncoming(
        _unsubscribeAppliedItems(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      await pumpEventQueue();

      expect(item.count(), 0);
      expect(
        events.deletes.map((e) => e.row),
        unorderedEquals([(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
    });

    test('an evicted row is deleted once, not again at finalize', () async {
      connection = MockConnection();
      manager = SubscriptionManager(connection, retainRowsOnUnsubscribe: true);
      final item = _register(manager, 'item', _ItemDecoder());
      addTearDown(manager.dispose);
      await connection.connect();

      final first = manager.subscribe(['SELECT * FROM item']);
      connection.simulateIncoming(
        _items(1, [(id: 1, name: 'a'), (id: 2, name: 'b')]),
      );
      manager.unsubscribe(await first.timeout(_timeout));

      final owned = manager.subscribe(['SELECT * FROM item WHERE id = 3']);
      connection.simulateIncoming(_items(2, [(id: 3, name: 'c')]));
      await owned.timeout(_timeout);

      await connection.disconnect();
      final retained = manager.subscribe(['SELECT * FROM item']);
      await connection.connect();
      await pumpEventQueue();
      final events = _Recorder(item);
      connection.simulateIncoming(_items(3, [(id: 1, name: 'a')]));
      connection.simulateIncoming(_items(2, const []));
      await retained.timeout(_timeout);
      await pumpEventQueue();

      expect(item.count(), 1);
      expect(
        events.deletes.map((e) => e.row),
        unorderedEquals([(id: 2, name: 'b'), (id: 3, name: 'c')]),
      );
    });
  });

  group('reconnect compares rows by content, not List identity', () {
    late TableCache<_Tagged> tagged;

    setUp(() async {
      connection = MockConnection();
      manager = SubscriptionManager(connection);
      tagged = _register(manager, 'tagged', _TaggedDecoder());
      await connection.connect();
      final pending = manager.subscribe(['SELECT * FROM tagged']);
      connection.simulateIncoming(
        _tagged(1, [
          (id: 1, tags: [1, 2]),
          (id: 2, tags: [3]),
        ]),
      );
      await pending.timeout(_timeout);
    });

    tearDown(() async => manager.dispose());

    test('an unchanged row with a List field fires no event', () async {
      final events = _Recorder(tagged);
      await bounce();
      connection.simulateIncoming(
        _tagged(1, [
          (id: 1, tags: [1, 2]),
          (id: 2, tags: [3]),
        ]),
      );
      await pumpEventQueue();

      expect(events.total, 0);
    });

    test('a row whose list contents changed fires one update', () async {
      final events = _Recorder(tagged);
      await bounce();
      connection.simulateIncoming(
        _tagged(1, [
          (id: 1, tags: [1, 2]),
          (id: 2, tags: [3, 4]),
        ]),
      );
      await pumpEventQueue();

      expect(events.inserts, isEmpty);
      expect(events.updates, hasLength(1));
      expect(events.updates.single.newRow.tags, [3, 4]);
    });
  });

  group('cold start keeps its insert events', () {
    test(
      'rows loaded from disk are re-inserted by the first snapshot',
      () async {
        connection = MockConnection();
        manager = SubscriptionManager(connection);
        final item = _register(manager, 'item', _ItemDecoder());
        addTearDown(manager.dispose);
        item.loadFromSerializable([
          {'id': 1, 'name': 'a'},
          {'id': 2, 'name': 'b'},
        ]);
        final events = _Recorder(item);

        await connection.connect();
        final pending = manager.subscribe(['SELECT * FROM item']);
        connection.simulateIncoming(
          _items(1, [(id: 1, name: 'a'), (id: 2, name: 'B')]),
        );
        await pending.timeout(_timeout);

        expect(events.inserts.map((e) => e.row), [
          (id: 1, name: 'a'),
          (id: 2, name: 'B'),
        ]);
        expect(events.updates, isEmpty);
      },
    );
  });
}
