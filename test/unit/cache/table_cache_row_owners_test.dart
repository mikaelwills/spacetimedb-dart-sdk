import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/src/events/table_event.dart';
import 'package:spacetimedb_sdk/src/events/transaction_batch.dart';

import '../../helpers/value_notifier_helpers.dart';

const _rowKey = 'row';
const _firstSubscription = 1;
const _secondSubscription = 2;

class _StringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(String row) => {'v': row};

  @override
  String? fromJson(Map<String, dynamic> json) {
    final value = json['v'];
    return value is String ? value : '';
  }
}

Uint8List _encodeRow(String row) {
  final encoder = BsatnEncoder();
  encoder.writeString(row);
  return encoder.toBytes();
}

BsatnRowList _rowList(List<String> rows) {
  if (rows.isEmpty) return BsatnRowList.empty();
  final encodedRows = rows.map(_encodeRow).toList();
  final offsets = <int>[];
  var offset = 0;
  for (final row in encodedRows) {
    offsets.add(offset);
    offset += row.length;
  }
  final combined = Uint8List(offset);
  var writeOffset = 0;
  for (final row in encodedRows) {
    combined.setRange(writeOffset, writeOffset + row.length, row);
    writeOffset += row.length;
  }
  return BsatnRowList(
    sizeHint: RowSizeHint.rowOffsets(offsets),
    rowsData: combined,
  );
}

EventContext get _ctx =>
    EventContext(myConnectionId: null, event: UnknownTransactionEvent());

TableCache<String> _createTable(String name) =>
    TableCache<String>(tableName: name, decoder: _StringDecoder());

void _applySnapshotFor(TableCache<String> table, int querySetId) {
  table.applySnapshot(_rowList([_rowKey]), _ctx, querySetId: querySetId);
}

void main() {
  group('row ownership storage', () {
    late TableCache<String> table;

    setUp(() => table = _createTable('owned'));

    tearDown(() => table.dispose());

    test('a row owned by one subscription allocates no owner set', () {
      _applySnapshotFor(table, _firstSubscription);

      expect(table.sharesOwnerSet(_rowKey), isFalse);
      expect(table.ownedKeys(_rowKey), equals({_firstSubscription}));
    });

    test(
      'a second subscription on the same row allocates an owner set and '
      'keeps the row after the first unsubscribes',
      () {
        _applySnapshotFor(table, _firstSubscription);
        _applySnapshotFor(table, _secondSubscription);
        expect(table.sharesOwnerSet(_rowKey), isTrue);

        table.dropQuerySet(_firstSubscription, deleteContext: _ctx);

        expect(table.find(_rowKey), equals(_rowKey));
        expect(table.ownedKeys(_rowKey), equals({_secondSubscription}));
        expect(table.sharesOwnerSet(_rowKey), isFalse);
      },
    );

    test(
      'when both subscriptions unsubscribe the row is removed and a delete '
      'event fires',
      () {
        final deleted = <TableDeleteEvent<String>>[];
        table.onDelete.listen(deleted.add);
        _applySnapshotFor(table, _firstSubscription);
        _applySnapshotFor(table, _secondSubscription);

        table.dropQuerySet(_firstSubscription, deleteContext: _ctx);
        table.dropQuerySet(_secondSubscription, deleteContext: _ctx);

        expect(table.find(_rowKey), isNull);
        expect(table.count(), equals(0));
        expect(deleted.map((event) => event.row), equals([_rowKey]));
      },
    );
  });

  group('lastBatch', () {
    late TableCache<String> table;

    setUp(() => table = _createTable('batched'));

    tearDown(() => table.dispose());

    test('holds the batch while its listeners run and is empty afterwards', () {
      final published = NotifierFireRecorder(table.lastBatch);

      table.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList([_rowKey]),
        _ctx,
      );

      expect(lastPublishedBatch(published)?.inserts.length, equals(1));
      expect(table.lastBatch.value, isNull);
    });
  });
}
