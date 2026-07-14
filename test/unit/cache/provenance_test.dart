import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

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
  String? fromJson(Map<String, dynamic> json) => json['v'] ?? '';
}

BsatnRowList _rowList(List<String> rows) {
  if (rows.isEmpty) return BsatnRowList.empty();
  final encodedRows =
      rows.map((row) {
        final encoder = BsatnEncoder();
        encoder.writeString(row);
        return encoder.toBytes();
      }).toList();

  final offsets = <int>[];
  var currentOffset = 0;
  for (final row in encodedRows) {
    offsets.add(currentOffset);
    currentOffset += row.length;
  }
  final combined = Uint8List(currentOffset);
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

void main() {
  group('applySnapshot eviction notifies per-row listeners', () {
    late TableCache<String> table;

    setUp(() {
      table = TableCache<String>(
        tableName: 'strays',
        decoder: _StringDecoder(),
      );
    });

    test(
      'a row evicted by the per-set reconcile strip nulls its rowNotifier',
      () {
        table.applySnapshot(_rowList(['x']), _ctx, querySetId: 1);
        final notifier = table.rowNotifier('x');
        expect(notifier.value, equals('x'));

        table.applySnapshot(BsatnRowList.empty(), _ctx, querySetId: 1);

        expect(table.find('x'), isNull);
        expect(notifier.value, isNull);
      },
    );

    test('a row evicted by the stale-stray sweep nulls its rowNotifier', () {
      table.applySnapshot(_rowList(['a']), _ctx, querySetId: 1);
      table.insertRow('stray');
      final strayNotifier = table.rowNotifier('stray');
      expect(strayNotifier.value, equals('stray'));

      table.applySnapshot(_rowList(['a']), _ctx, querySetId: 2);

      expect(table.find('stray'), isNull);
      expect(strayNotifier.value, isNull);
    });
  });

  group('T6 — owner-entry lifecycle across all six removal paths', () {
    late TableCache<String> table;

    setUp(() {
      table = TableCache<String>(
        tableName: 'strays',
        decoder: _StringDecoder(),
      );
    });

    test('(1) _applyChanges delete branch via applyServerDelta', () {
      table.applySnapshot(_rowList(['a', 'b']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(2));

      table.applyServerDelta(
        _rowList(['a']),
        BsatnRowList.empty(),
        _ctx,
        querySetId: 1,
      );

      expect(table.find('a'), isNull);
      expect(table.ownerEntryCount, equals(1));
    });

    test('(2) deleteRow does not leak an owner entry when the row was never '
        'server-owned (fresh optimistic insert phantom-cleanup case)', () {
      table.insertRow('phantom');
      expect(table.ownerEntryCount, equals(0));

      table.deleteRow('phantom');

      expect(table.find('phantom'), isNull);
      expect(table.ownerEntryCount, equals(0));
    });

    test('(3) removeRowsWhere', () {
      table.applySnapshot(_rowList(['a', 'b', 'c']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(3));

      table.removeRowsWhere((pk) => pk == 'b');

      expect(table.find('b'), isNull);
      expect(table.ownerEntryCount, equals(2));
    });

    test('(4) applyDeletes', () {
      table.applySnapshot(_rowList(['a', 'b']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(2));

      table.applyDeletes(_rowList(['a']));

      expect(table.find('a'), isNull);
      expect(table.ownerEntryCount, equals(1));
    });

    test('(5) clear wipes the owner map wholesale', () {
      table.applySnapshot(_rowList(['a', 'b']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(2));

      table.clear();

      expect(table.ownerEntryCount, equals(0));
    });

    test('(6) loadFromSerializable wipes the owner map wholesale', () {
      table.applySnapshot(_rowList(['a', 'b']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(2));

      table.loadFromSerializable([
        {'v': 'hydrated'},
      ]);

      expect(table.ownerEntryCount, equals(0));
      expect(table.find('hydrated'), isNotNull);
    });

    test('designed exception: optimistic-delete pendency leaves an owner entry '
        'with no cache row, resolved by confirm (owner+entry removed)', () {
      table.applySnapshot(_rowList(['a']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(1));

      table.deleteRow('a');
      expect(table.find('a'), isNull);
      expect(table.ownerEntryCount, equals(1));

      table.applyServerDelta(
        _rowList(['a']),
        BsatnRowList.empty(),
        _ctx,
        querySetId: 1,
        protectedKeys: const {},
      );

      expect(table.ownerEntryCount, equals(0));
    });

    test('designed exception: optimistic-delete pendency leaves an owner entry '
        'with no cache row, resolved by rollback (row restored, ownership '
        'valid)', () {
      table.applySnapshot(_rowList(['a']), _ctx, querySetId: 1);
      table.deleteRow('a');
      expect(table.find('a'), isNull);
      expect(table.ownerEntryCount, equals(1));

      table.insertRow('a');

      expect(table.find('a'), isNotNull);
      expect(table.ownerEntryCount, equals(1));
    });

    test('baseline owner-entry count is restored after exercising every '
        'removal path in sequence', () {
      table.applySnapshot(_rowList(['a', 'b', 'c', 'd']), _ctx, querySetId: 1);
      expect(table.ownerEntryCount, equals(4));

      table.applyServerDelta(
        _rowList(['a']),
        BsatnRowList.empty(),
        _ctx,
        querySetId: 1,
      );
      table.applyDeletes(_rowList(['b']));
      table.removeRowsWhere((pk) => pk == 'c');
      table.dropQuerySet(1);

      expect(table.ownerEntryCount, equals(0));
      expect(table.iter(), isEmpty);
    });
  });

  group('T7 — event-multiplicity pin (0->1 / ->0 across overlapping sets)', () {
    late TableCache<String> table;

    setUp(() {
      table = TableCache<String>(
        tableName: 'overlap',
        decoder: _StringDecoder(),
      );
    });

    test('a row entering two overlapping query sets in one message emits '
        'exactly one insert event', () {
      var insertCount = 0;
      table.onInsert.listen((_) => insertCount++);

      table.applyServerDelta(
        BsatnRowList.empty(),
        _rowList(['shared']),
        _ctx,
        querySetId: 1,
      );
      table.applyServerDelta(
        BsatnRowList.empty(),
        _rowList(['shared']),
        _ctx,
        querySetId: 2,
      );

      expect(insertCount, equals(1));
      expect(table.ownerEntryCount, equals(1));
    });

    test('a row leaving both overlapping query sets emits exactly one delete '
        'event, on the set whose removal empties the owner set', () {
      table.applyServerDelta(
        BsatnRowList.empty(),
        _rowList(['shared']),
        _ctx,
        querySetId: 1,
      );
      table.applyServerDelta(
        BsatnRowList.empty(),
        _rowList(['shared']),
        _ctx,
        querySetId: 2,
      );

      var deleteCount = 0;
      table.onDelete.listen((_) => deleteCount++);

      table.applyServerDelta(
        _rowList(['shared']),
        BsatnRowList.empty(),
        _ctx,
        querySetId: 1,
      );

      expect(deleteCount, equals(0));
      expect(table.find('shared'), isNotNull);

      table.applyServerDelta(
        _rowList(['shared']),
        BsatnRowList.empty(),
        _ctx,
        querySetId: 2,
      );

      expect(deleteCount, equals(1));
      expect(table.find('shared'), isNull);
    });
  });
}
