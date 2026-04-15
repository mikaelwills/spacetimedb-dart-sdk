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

BsatnRowList createRowList(List<Note> notes) {
  if (notes.isEmpty) {
    return BsatnRowList.empty();
  }

  final encodedRows =
      notes.map((note) {
        final encoder = BsatnEncoder();
        note.encodeBsatn(encoder);
        return encoder.toBytes();
      }).toList();

  final offsets = <int>[];
  var currentOffset = 0;

  for (final row in encodedRows) {
    offsets.add(currentOffset);
    currentOffset += row.length;
  }

  final combinedData = Uint8List(currentOffset);
  var writeOffset = 0;
  for (final row in encodedRows) {
    combinedData.setRange(writeOffset, writeOffset + row.length, row);
    writeOffset += row.length;
  }

  return BsatnRowList(
    sizeHint: RowSizeHint.rowOffsets(offsets),
    rowsData: combinedData,
  );
}

void main() {
  group('TableCache delete+insert coalesce', () {
    late ClientCache clientCache;
    late TableCache<Note> cache;
    late EventContext dummyContext;

    setUp(() {
      clientCache = ClientCache();
      clientCache.registerDecoder<Note>('note', NoteDecoder());
      cache = clientCache.getTableByTypedName<Note>('note');
      dummyContext = EventContext.optimistic(requestId: 'dummy');
    });

    tearDown(() => cache.dispose());

    test(
      'V1: single PK delete+insert pair produces one TableUpdateEvent, no TableDeleteEvent',
      () {
        final oldNote = createNote(42, 'old title', content: 'before');
        cache.insertRow(oldNote);
        expect(cache.find(42)?.content, equals('before'));

        final newNote = createNote(42, 'new title', content: 'after');
        cache.applyTransactionUpdate(
          createRowList([oldNote]),
          createRowList([newNote]),
          dummyContext,
        );

        final batch = cache.lastBatch.value;
        expect(batch, isNotNull, reason: 'lastBatch should have fired once');
        expect(
          batch!.length,
          equals(1),
          reason:
              'A single PK delete+insert pair must coalesce into exactly one event. '
              'Events observed: ${batch.events}',
        );
        expect(batch.deletes, isEmpty, reason: 'no phantom delete expected');
        expect(
          batch.inserts,
          isEmpty,
          reason: 'insert must coalesce to update',
        );
        expect(batch.updates.length, equals(1));

        final update = batch.updates.first;
        expect(update.oldRow.content, equals('before'));
        expect(update.newRow.content, equals('after'));
        expect(update.oldRow.id, equals(42));
        expect(update.newRow.id, equals(42));

        expect(cache.find(42)?.content, equals('after'));
      },
    );

    test(
      'V2: mixed batch — standalone deletes + fresh inserts + PK-update pairs — correct counts',
      () {
        cache.insertRow(createNote(1, 'to-delete-1'));
        cache.insertRow(createNote(2, 'to-delete-2'));
        cache.insertRow(createNote(3, 'to-update-1', content: 'before'));
        cache.insertRow(createNote(4, 'to-update-2', content: 'before'));

        final deletes = createRowList([
          createNote(1, 'to-delete-1'),
          createNote(2, 'to-delete-2'),
          createNote(3, 'to-update-1', content: 'before'),
          createNote(4, 'to-update-2', content: 'before'),
        ]);

        final inserts = createRowList([
          createNote(3, 'to-update-1', content: 'after'),
          createNote(4, 'to-update-2', content: 'after'),
          createNote(5, 'fresh-1'),
          createNote(6, 'fresh-2'),
        ]);

        cache.applyTransactionUpdate(deletes, inserts, dummyContext);

        final batch = cache.lastBatch.value;
        expect(batch, isNotNull);
        expect(
          batch!.length,
          equals(6),
          reason:
              '2 standalone deletes + 2 fresh inserts + 2 updates = 6 events. '
              'Observed: ${batch.events}',
        );
        expect(batch.deletes.length, equals(2));
        expect(batch.inserts.length, equals(2));
        expect(batch.updates.length, equals(2));

        final deletedIds = batch.deletes.map((e) => e.row.id).toSet();
        expect(deletedIds, equals({1, 2}));

        final insertedIds = batch.inserts.map((e) => e.row.id).toSet();
        expect(insertedIds, equals({5, 6}));

        final updatedIds = batch.updates.map((e) => e.newRow.id).toSet();
        expect(updatedIds, equals({3, 4}));

        for (final update in batch.updates) {
          expect(update.oldRow.content, equals('before'));
          expect(update.newRow.content, equals('after'));
        }

        expect(cache.find(1), isNull);
        expect(cache.find(2), isNull);
        expect(cache.find(3)?.content, equals('after'));
        expect(cache.find(4)?.content, equals('after'));
        expect(cache.find(5)?.title, equals('fresh-1'));
        expect(cache.find(6)?.title, equals('fresh-2'));
      },
    );

    test(
      'V-ghost: delete for a row not in cache still emits TableDeleteEvent',
      () {
        final ghost = createNote(99, 'never-seen');
        cache.applyTransactionUpdate(
          createRowList([ghost]),
          BsatnRowList.empty(),
          dummyContext,
        );

        final batch = cache.lastBatch.value;
        expect(batch, isNotNull);
        expect(batch!.length, equals(1));
        expect(batch.deletes.length, equals(1));
        expect(batch.deletes.first.row.id, equals(99));
        expect(batch.updates, isEmpty);
        expect(batch.inserts, isEmpty);
      },
    );
  });
}
