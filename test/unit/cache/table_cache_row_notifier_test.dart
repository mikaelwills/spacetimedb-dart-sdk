import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'package:spacetimedb_dart_sdk/protocol.dart';

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

void main() {
  group('TableCache.rowNotifier', () {
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

    group('API', () {
      test('returns same instance on repeated calls with same key', () {
        expect(identical(cache.rowNotifier(1), cache.rowNotifier(1)), isTrue);
      });

      test('returns different instances for different keys', () {
        expect(identical(cache.rowNotifier(1), cache.rowNotifier(2)), isFalse);
      });

      test('.value is null for an absent key', () {
        expect(cache.rowNotifier(999).value, isNull);
      });

      test('.value matches find(pk) when present at creation time', () {
        final note = createNote(7, 'hello');
        cache.insertRow(note);
        expect(cache.rowNotifier(7).value, equals(note));
      });

      test('typed as ValueNotifier<Note?>', () {
        expect(cache.rowNotifier(1), isA<ValueNotifier<Note?>>());
      });

      test('throws StateError on a no-PK table', () {
        final noPk = TableCache<String>(
          tableName: 'tagless',
          decoder: _StringNoPkDecoder(),
        );
        addTearDown(noPk.dispose);
        expect(() => noPk.rowNotifier('foo'), throwsStateError);
      });
    });

    group('server-driven path (_emitChanges)', () {
      test('fires on insert for the watched key with the new value', () {
        final n = cache.rowNotifier(10);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        final note = createNote(10, 'inserted');
        cache.applyTransactionUpdate(
          BsatnRowList.empty(),
          _rowList([note]),
          context,
        );

        expect(fires, hasLength(1));
        expect(fires.single, equals(note));
      });

      test('fires on update via coalesced delete+insert with new value', () {
        final original = createNote(5, 'orig', content: 'a');
        cache.insertRow(original);

        final n = cache.rowNotifier(5);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        final updated = createNote(5, 'updated', content: 'b');
        cache.applyTransactionUpdate(
          _rowList([original]),
          _rowList([updated]),
          context,
        );

        expect(fires, hasLength(1));
        expect(fires.single?.content, equals('b'));
      });

      test('fires with null on delete', () {
        final note = createNote(3, 'gone');
        cache.insertRow(note);

        final n = cache.rowNotifier(3);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        cache.applyTransactionUpdate(
          _rowList([note]),
          BsatnRowList.empty(),
          context,
        );

        expect(fires, hasLength(1));
        expect(fires.single, isNull);
      });

      test('does NOT fire for transactions touching a different row', () {
        final n = cache.rowNotifier(1);
        var fireCount = 0;
        n.addListener(() => fireCount++);

        cache.applyTransactionUpdate(
          BsatnRowList.empty(),
          _rowList([createNote(2, 'other')]),
          context,
        );

        expect(fireCount, equals(0));
      });

      test('fires when a previously-deleted key is re-inserted', () {
        final note = createNote(8, 'first');
        cache.insertRow(note);
        cache.deleteRow(8);

        final n = cache.rowNotifier(8);
        expect(n.value, isNull);

        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        final reborn = createNote(8, 'reborn');
        cache.applyTransactionUpdate(
          BsatnRowList.empty(),
          _rowList([reborn]),
          context,
        );

        expect(fires, hasLength(1));
        expect(fires.single?.title, equals('reborn'));
      });

      test(
        'inside lastBatch listener, rowNotifier value is already current',
        () {
          cache.insertRow(createNote(1, 'start'));
          Note? valueSeen;
          cache.lastBatch.addListener(() {
            valueSeen = cache.rowNotifier(1).value;
          });

          final updated = createNote(1, 'mid');
          cache.applyTransactionUpdate(
            _rowList([createNote(1, 'start')]),
            _rowList([updated]),
            context,
          );

          expect(valueSeen?.title, equals('mid'));
        },
      );
    });

    group('optimistic path', () {
      test('insertRow fires the row notifier', () {
        final n = cache.rowNotifier(1);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        cache.insertRow(createNote(1, 'via insertRow'));

        expect(fires, hasLength(1));
        expect(fires.single?.title, equals('via insertRow'));
      });

      test('updateRow fires the row notifier', () {
        cache.insertRow(createNote(2, 'orig'));
        final n = cache.rowNotifier(2);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        cache.updateRow(createNote(2, 'updated'));

        expect(fires, hasLength(1));
        expect(fires.single?.title, equals('updated'));
      });

      test('deleteRow fires with null', () {
        cache.insertRow(createNote(3, 'doomed'));
        final n = cache.rowNotifier(3);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        cache.deleteRow(3);

        expect(fires, hasLength(1));
        expect(fires.single, isNull);
      });
    });

    group('clear()', () {
      test('sets all row notifiers to null', () {
        cache.insertRow(createNote(1, 'a'));
        cache.insertRow(createNote(2, 'b'));
        final n1 = cache.rowNotifier(1);
        final n2 = cache.rowNotifier(2);

        cache.clear();

        expect(n1.value, isNull);
        expect(n2.value, isNull);
      });
    });

    group('loadFromSerializable', () {
      test('fires existing row notifiers with restored values', () {
        cache.insertRow(createNote(1, 'original'));
        final n = cache.rowNotifier(1);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        final restored = createNote(1, 'restored');
        cache.loadFromSerializable([NoteDecoder().toJson(restored)!]);

        expect(fires, hasLength(1));
        expect(fires.single?.title, equals('restored'));
      });

      test('fires with null for a key that was removed from the snapshot', () {
        cache.insertRow(createNote(5, 'will be gone'));
        final n = cache.rowNotifier(5);
        final fires = <Note?>[];
        n.addListener(() => fires.add(n.value));

        cache.loadFromSerializable([]);

        expect(fires, hasLength(1));
        expect(fires.single, isNull);
      });
    });

    group('equality de-dupe', () {
      test('does NOT fire when updateRow sets a field-equal row', () {
        final note = createNote(1, 'same');
        cache.insertRow(note);
        final n = cache.rowNotifier(1);
        var fires = 0;
        n.addListener(() => fires++);

        cache.updateRow(createNote(1, 'same'));

        expect(fires, equals(0), reason: 'ValueNotifier dedupes equal values');
      });
    });

    group('auto-disposal', () {
      test(
        'removes notifier from cache after last listener detaches',
        () async {
          final n = cache.rowNotifier(1);
          void listener() {}
          n.addListener(listener);
          n.removeListener(listener);

          await Future<void>.delayed(Duration.zero);

          final fresh = cache.rowNotifier(1);
          expect(identical(fresh, n), isFalse);
        },
      );

      test(
        'does NOT auto-dispose while listeners are still attached',
        () async {
          final n = cache.rowNotifier(1);
          void keep() {}
          n.addListener(keep);
          void transient() {}
          n.addListener(transient);
          n.removeListener(transient);

          await Future<void>.delayed(Duration.zero);

          expect(identical(cache.rowNotifier(1), n), isTrue);
          n.removeListener(keep);
        },
      );
    });

    group('dispose()', () {
      test('disposes all row notifiers without error', () {
        final localCache = TableCache<Note>(
          tableName: 'note',
          decoder: NoteDecoder(),
        );
        localCache.rowNotifier(1);
        localCache.rowNotifier(2);
        localCache.rowNotifier(3);
        expect(localCache.dispose, returnsNormally);
      });

      test(
        'pending auto-dispose microtask after cache.dispose is safe',
        () async {
          final localCache = TableCache<Note>(
            tableName: 'note',
            decoder: NoteDecoder(),
          );
          final n = localCache.rowNotifier(1);
          void listener() {}
          n.addListener(listener);
          n.removeListener(listener);

          localCache.dispose();

          await expectLater(Future<void>.delayed(Duration.zero), completes);
        },
      );
    });
  });
}
