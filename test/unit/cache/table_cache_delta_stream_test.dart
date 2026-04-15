import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note createNote(int id, String title, {String content = ''}) => Note(
  id: id,
  title: title,
  content: content,
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

BsatnRowList _rowList(List<Note> notes) {
  if (notes.isEmpty) return BsatnRowList.empty();
  final encoded =
      notes.map((n) {
        final e = BsatnEncoder();
        n.encodeBsatn(e);
        return e.toBytes();
      }).toList();
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

class _StringNoPkDecoder extends RowDecoder<String> {
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

BsatnRowList _stringRowList(List<String> values) {
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
  group('TableCache delta streams', () {
    late ClientCache clientCache;
    late TableCache<Note> cache;
    late EventContext context;

    setUp(() {
      clientCache = ClientCache();
      clientCache.registerDecoder<Note>('note', NoteDecoder());
      cache = clientCache.getTableByTypedName<Note>('note');
      context = EventContext.optimistic(requestId: 'test');
    });

    tearDown(() => cache.dispose());

    test('onInsert fires on server-driven insert', () {
      final events = <TableInsertEvent<Note>>[];
      final sub = cache.onInsert.listen(events.add);
      addTearDown(sub.cancel);

      final note = createNote(1, 'inserted');
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList([note]),
        context,
      );

      expect(events, hasLength(1));
      expect(events.single.row, equals(note));
      expect(events.single.context, equals(context));
    });

    test('onUpdate fires on coalesced delete+insert of same PK', () {
      final original = createNote(5, 'orig', content: 'a');
      cache.insertRow(original);

      final events = <TableUpdateEvent<Note>>[];
      final sub = cache.onUpdate.listen(events.add);
      addTearDown(sub.cancel);

      final updated = createNote(5, 'updated', content: 'b');
      cache.applyTransactionUpdate(
        _rowList([original]),
        _rowList([updated]),
        context,
      );

      expect(events, hasLength(1));
      expect(events.single.oldRow.content, equals('a'));
      expect(events.single.newRow.content, equals('b'));
    });

    test('onDelete fires on server-driven delete', () {
      final note = createNote(3, 'gone');
      cache.insertRow(note);

      final events = <TableDeleteEvent<Note>>[];
      final sub = cache.onDelete.listen(events.add);
      addTearDown(sub.cancel);

      cache.applyTransactionUpdate(
        _rowList([note]),
        BsatnRowList.empty(),
        context,
      );

      expect(events, hasLength(1));
      expect(events.single.row, equals(note));
    });

    test('mixed batch: each stream receives only its own event type', () {
      final toKeep = createNote(1, 'keep');
      final toUpdate = createNote(2, 'orig');
      final toDelete = createNote(3, 'delete');
      cache.insertRow(toKeep);
      cache.insertRow(toUpdate);
      cache.insertRow(toDelete);

      final inserts = <TableInsertEvent<Note>>[];
      final updates = <TableUpdateEvent<Note>>[];
      final deletes = <TableDeleteEvent<Note>>[];
      final subI = cache.onInsert.listen(inserts.add);
      final subU = cache.onUpdate.listen(updates.add);
      final subD = cache.onDelete.listen(deletes.add);
      addTearDown(() {
        subI.cancel();
        subU.cancel();
        subD.cancel();
      });

      final freshInsert = createNote(4, 'new');
      final updated = createNote(2, 'updated');
      cache.applyTransactionUpdate(
        _rowList([toUpdate, toDelete]),
        _rowList([freshInsert, updated]),
        context,
      );

      expect(inserts, hasLength(1));
      expect(inserts.single.row.id, equals(4));
      expect(updates, hasLength(1));
      expect(updates.single.newRow.title, equals('updated'));
      expect(deletes, hasLength(1));
      expect(deletes.single.row.id, equals(3));
    });

    test('optimistic emitBatch fires the streams', () {
      final inserts = <TableInsertEvent<Note>>[];
      final sub = cache.onInsert.listen(inserts.add);
      addTearDown(sub.cancel);

      final note = createNote(1, 'optimistic');
      cache.insertRow(note);
      cache.emitBatch([TableEventSpec.insert(note)], context);

      expect(inserts, hasLength(1));
      expect(inserts.single.row, equals(note));
    });

    test('broadcast: two subscribers both receive the event', () {
      final a = <TableInsertEvent<Note>>[];
      final b = <TableInsertEvent<Note>>[];
      final subA = cache.onInsert.listen(a.add);
      final subB = cache.onInsert.listen(b.add);
      addTearDown(() {
        subA.cancel();
        subB.cancel();
      });

      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList([createNote(1, 'fanout')]),
        context,
      );

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    test('late subscriber receives no past events', () {
      cache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _rowList([createNote(1, 'early')]),
        context,
      );

      final events = <TableInsertEvent<Note>>[];
      final sub = cache.onInsert.listen(events.add);
      addTearDown(sub.cancel);

      expect(events, isEmpty);
    });

    test(
      'ordering: inside onInsert listener, rows.value already reflects new state',
      () {
        List<Note>? rowsSeen;
        final sub = cache.onInsert.listen((_) {
          rowsSeen = cache.rows.value;
        });
        addTearDown(sub.cancel);

        cache.applyTransactionUpdate(
          BsatnRowList.empty(),
          _rowList([createNote(1, 'new')]),
          context,
        );

        expect(rowsSeen, isNotNull);
        expect(rowsSeen!.map((n) => n.id), contains(1));
      },
    );

    test(
      'ordering: inside lastBatch listener, delta streams have already fired',
      () {
        var insertStreamFired = false;
        final sub = cache.onInsert.listen((_) => insertStreamFired = true);
        addTearDown(sub.cancel);

        bool? insertStreamFiredWhenLastBatchObserved;
        cache.lastBatch.addListener(() {
          insertStreamFiredWhenLastBatchObserved = insertStreamFired;
        });

        cache.applyTransactionUpdate(
          BsatnRowList.empty(),
          _rowList([createNote(1, 'new')]),
          context,
        );

        expect(insertStreamFiredWhenLastBatchObserved, isTrue);
      },
    );

    test('no-PK table: onInsert and onDelete fire; onUpdate does not', () {
      final noPkCache = TableCache<String>(
        tableName: 'tagless',
        decoder: _StringNoPkDecoder(),
      );
      addTearDown(noPkCache.dispose);

      final inserts = <TableInsertEvent<String>>[];
      final updates = <TableUpdateEvent<String>>[];
      final deletes = <TableDeleteEvent<String>>[];
      final subI = noPkCache.onInsert.listen(inserts.add);
      final subU = noPkCache.onUpdate.listen(updates.add);
      final subD = noPkCache.onDelete.listen(deletes.add);
      addTearDown(() {
        subI.cancel();
        subU.cancel();
        subD.cancel();
      });

      noPkCache.applyTransactionUpdate(
        BsatnRowList.empty(),
        _stringRowList(['alpha', 'beta']),
        context,
      );

      expect(inserts, hasLength(2));
      expect(updates, isEmpty);
      expect(deletes, isEmpty);

      noPkCache.applyTransactionUpdate(
        _stringRowList(['alpha']),
        BsatnRowList.empty(),
        context,
      );

      expect(deletes, hasLength(1));
      expect(updates, isEmpty);
    });

    test('subscribing after dispose does not throw', () {
      final localCache = TableCache<Note>(
        tableName: 'note',
        decoder: NoteDecoder(),
      );
      localCache.dispose();

      expect(() {
        final sub = localCache.onInsert.listen((_) {});
        sub.cancel();
      }, returnsNormally);
    });
  });
}
