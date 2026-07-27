import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note _note(int id, String title) => Note(
  id: id,
  title: title,
  content: '',
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

BsatnRowList _stringRowList(List<String> values) {
  if (values.isEmpty) return BsatnRowList.empty();
  final encoded =
      values.map((value) {
        final encoder = BsatnEncoder();
        encoder.writeString(value);
        return encoder.toBytes();
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

void main() {
  group('applyServerDelta onOwnershipGained', () {
    late ClientCache clientCache;
    late TableCache<Note> cache;
    late EventContext context;
    late List<dynamic> gains;

    setUp(() {
      clientCache = ClientCache();
      clientCache.registerDecoder<Note>('note', NoteDecoder());
      cache = clientCache.getTableByTypedName<Note>('note');
      context = EventContext.optimistic(requestId: 'test');
      gains = [];
    });

    tearDown(() => cache.dispose());

    void applyInserts(
      List<Note> inserts, {
      int querySetId = 1,
      Set<dynamic>? protectedKeys,
    }) {
      cache.applyServerDelta(
        BsatnRowList.empty(),
        _rowList(inserts),
        context,
        querySetId: querySetId,
        protectedKeys: protectedKeys,
        onOwnershipGained: gains.add,
      );
    }

    test('fires once for a key gaining its first owner', () {
      applyInserts([_note(1, 'a')]);
      expect(gains, equals([1]));
    });

    test('fires for a PROTECTED key gaining its first owner even though '
        'the row itself is filtered', () {
      applyInserts([_note(1, 'server-version')], protectedKeys: {1});
      expect(gains, equals([1]));
      expect(
        cache.find(1),
        isNull,
        reason: 'the protected row must still not be written to the cache',
      );
    });

    test('silent for a key that already had an owner', () {
      applyInserts([_note(1, 'a')]);
      gains.clear();
      applyInserts([_note(1, 'a-again')]);
      expect(gains, isEmpty);
    });

    test('silent when a second query set adds ownership of an owned key', () {
      applyInserts([_note(1, 'a')]);
      gains.clear();
      applyInserts([_note(1, 'a')], querySetId: 2);
      expect(gains, isEmpty);
      expect(cache.ownedKeys(1), equals({1, 2}));
    });

    test('silent for a delete-only delta', () {
      applyInserts([_note(1, 'a')]);
      gains.clear();
      cache.applyServerDelta(
        _rowList([_note(1, 'a')]),
        BsatnRowList.empty(),
        context,
        querySetId: 1,
        onOwnershipGained: gains.add,
      );
      expect(gains, isEmpty);
    });

    test('fires per gained key in a multi-insert delta', () {
      applyInserts([_note(1, 'a')]);
      gains.clear();
      applyInserts([_note(1, 'a'), _note(2, 'b'), _note(3, 'c')]);
      expect(gains, unorderedEquals([2, 3]));
    });

    test('silent on no-PK tables', () {
      final noPkGains = <dynamic>[];
      clientCache.registerDecoder<String>('tag', _StringNoPkDecoder());
      final noPkCache = clientCache.getTableByTypedName<String>('tag');
      noPkCache.applyServerDelta(
        BsatnRowList.empty(),
        _stringRowList(['x', 'y']),
        context,
        querySetId: 1,
        onOwnershipGained: noPkGains.add,
      );
      expect(noPkGains, isEmpty);
      noPkCache.dispose();
    });
  });
}
