import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'package:spacetimedb_dart_sdk/protocol.dart';

class StringRowDecoder extends RowDecoder<String> {
  @override
  bool get hasPrimaryKey => false;

  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => null;
}

Uint8List _encodeString(String value) {
  final encoder = BsatnEncoder();
  encoder.writeString(value);
  return encoder.toBytes();
}

BsatnRowList _rowList(List<String> values) {
  if (values.isEmpty) return BsatnRowList.empty();

  final encoded = values.map(_encodeString).toList();
  final offsets = <int>[];
  var cursor = 0;
  for (final row in encoded) {
    offsets.add(cursor);
    cursor += row.length;
  }

  final combined = Uint8List(cursor);
  var write = 0;
  for (final row in encoded) {
    combined.setRange(write, write + row.length, row);
    write += row.length;
  }

  return BsatnRowList(
    sizeHint: RowSizeHint.rowOffsets(offsets),
    rowsData: combined,
  );
}

void main() {
  group('TableCache no-PK branch', () {
    late TableCache<String> cache;
    late EventContext context;

    setUp(() {
      cache = TableCache<String>(
        tableName: 'tagless',
        decoder: StringRowDecoder(),
      );
      context = EventContext.optimistic(requestId: 'test');
    });

    tearDown(() => cache.dispose());

    test('hasPrimaryKey flag is false', () {
      expect(cache.hasPrimaryKey, isFalse);
    });

    test('freshly constructed cache reports zero count and empty iter', () {
      expect(cache.count(), equals(0));
      expect(cache.iter(), isEmpty);
      expect(cache.rows.value, isEmpty);
    });

    test('applyTransactionUpdate inserts rows and refreshes notifiers', () {
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList(['alpha', 'beta', 'gamma']),
        context,
      );

      expect(cache.count(), equals(3));
      expect(cache.iter().toList(), equals(['alpha', 'beta', 'gamma']));
      expect(cache.rows.value, equals(['alpha', 'beta', 'gamma']));
      expect(cache.lastBatch.value?.events.length, equals(3));
      expect(
        cache.lastBatch.value?.events.every((e) => e is TableInsertEvent),
        isTrue,
      );
    });

    test('applyTransactionUpdate deletes a row via content equality', () {
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList(['alpha', 'beta', 'gamma']),
        context,
      );

      cache.applyTransactionUpdate(
        _rowList(['beta']),
        BsatnRowList.empty(),
        context,
      );

      expect(cache.count(), equals(2));
      expect(cache.iter().toList(), equals(['alpha', 'gamma']));
      expect(cache.lastBatch.value?.events.length, equals(1));
      expect(cache.lastBatch.value?.events.first, isA<TableDeleteEvent>());
    });

    test('clear empties everything', () {
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList(['alpha', 'beta']),
        context,
      );
      cache.clear();

      expect(cache.count(), equals(0));
      expect(cache.iter(), isEmpty);
      expect(cache.rows.value, isEmpty);
    });

    test('find returns null for no-PK tables', () {
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList(['alpha']),
        context,
      );
      expect(cache.find('alpha'), isNull);
    });

    test('deleteRow throws StateError on no-PK table', () {
      expect(
        () => cache.deleteRow('alpha'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no-PK table "tagless"'),
          ),
        ),
      );
    });

    test('updateRow throws StateError on no-PK table', () {
      expect(
        () => cache.updateRow('alpha'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no-PK table "tagless"'),
          ),
        ),
      );
    });

    test('insertRow still works for no-PK tables', () {
      cache.insertRow('lone-row');
      expect(cache.count(), equals(1));
      expect(cache.iter().toList(), equals(['lone-row']));
      expect(cache.rows.value, equals(['lone-row']));
    });
  });

  group('TableCache PK branch — count/iter on empty cache', () {
    test('empty PK-having cache reports zero without proxy bug', () {
      final cache = TableCache<String>(
        tableName: 'keyed',
        decoder: _KeyedStringDecoder(),
      );
      addTearDown(cache.dispose);

      expect(cache.hasPrimaryKey, isTrue);
      expect(cache.count(), equals(0));
      expect(cache.iter(), isEmpty);
      expect(cache.rows.value, isEmpty);
    });
  });
}

class _KeyedStringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;
}
