import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';
import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:test/test.dart';

Uint8List _emptyBsatnRowListBytes() {
  final enc = BsatnEncoder();
  enc.writeU8(0); // RowSizeHint tag 0 = FixedSize
  enc.writeU16(0); // row size 0
  enc.writeU32(0); // rows_data length 0
  return enc.toBytes();
}

void main() {
  group('BsatnRowList', () {
    test('decodes fixed-size empty list', () {
      final bytes = _emptyBsatnRowListBytes();
      final list = BsatnRowList.decode(BsatnDecoder(bytes));
      expect(list.rowsData, isEmpty);
      expect(list.getRows(), isEmpty);
    });

    test('empty() factory returns a zero-row list', () {
      final empty = BsatnRowList.empty();
      expect(empty.rowsData, isEmpty);
      expect(empty.getRows(), isEmpty);
    });
  });

  group('TableUpdateRows (v2 sealed)', () {
    test('decodes PersistentTable variant (tag 0)', () {
      final enc = BsatnEncoder();
      enc.writeU8(0); // TableUpdateRows tag 0 = PersistentTable
      // inserts
      enc.writeU8(0);
      enc.writeU16(0);
      enc.writeU32(0);
      // deletes
      enc.writeU8(0);
      enc.writeU16(0);
      enc.writeU32(0);

      final row = TableUpdateRows.decode(BsatnDecoder(enc.toBytes()));
      expect(row, isA<PersistentTableRows>());
    });

    test('decodes EventTable variant (tag 1)', () {
      final enc = BsatnEncoder();
      enc.writeU8(1); // tag 1 = EventTable
      // events
      enc.writeU8(0);
      enc.writeU16(0);
      enc.writeU32(0);

      final row = TableUpdateRows.decode(BsatnDecoder(enc.toBytes()));
      expect(row, isA<EventTableRows>());
    });

    test('throws on unknown tag', () {
      final frame = Uint8List.fromList([99]);
      expect(
        () => TableUpdateRows.decode(BsatnDecoder(frame)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('QuerySetUpdate', () {
    test('decodes empty tables list', () {
      final enc = BsatnEncoder();
      enc.writeU32(7); // query_set_id
      enc.writeU32(0); // tables length

      final qsu = QuerySetUpdate.decode(BsatnDecoder(enc.toBytes()));
      expect(qsu.querySetId, equals(7));
      expect(qsu.tables, isEmpty);
    });
  });
}
