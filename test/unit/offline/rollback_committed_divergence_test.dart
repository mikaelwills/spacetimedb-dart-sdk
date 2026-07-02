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

void applyCommit({
  required TableCache<Note> table,
  required OptimisticStateManager optimistic,
  required EventContext context,
  required List<Note> deletes,
  required List<Note> inserts,
  required Set<dynamic> stillPending,
}) {
  void onProtectedKeyCommitted(
    dynamic primaryKey,
    Map<String, dynamic>? committedRowJson,
  ) {
    optimistic.stashCommittedState('note', primaryKey, committedRowJson);
  }

  table.applyTransactionUpdateAndCollectKeys(
    createRowList(deletes),
    createRowList(inserts),
    context,
    protectedKeys: stillPending,
    reconcile: true,
    onProtectedKeyCommitted: onProtectedKeyCommitted,
  );
}

void main() {
  group('rollback-after-overlapping-confirm divergence', () {
    late ClientCache clientCache;
    late TableCache<Note> table;
    late OptimisticStateManager optimistic;
    late EventContext dummyContext;

    setUp(() {
      clientCache = ClientCache();
      clientCache.registerDecoder<Note>('note', NoteDecoder());
      table = clientCache.getTableByTypedName<Note>('note');
      optimistic = OptimisticStateManager(clientCache);
      dummyContext = EventContext.optimistic(requestId: 'dummy');
    });

    tearDown(() => table.dispose());

    test(
      'PROOF: rollback of M2 restores server post-M1 row, not client-predicted v1',
      () {
        final server0 = createNote(1, 'title', content: 'server0');
        table.insertRow(server0);

        final v1Predicted = createNote(1, 'title', content: 'v1-predicted');
        optimistic.applyOptimisticChanges('m1', [
          OptimisticChange.update(
            'note',
            server0.toJson(),
            v1Predicted.toJson(),
          ),
        ]);
        expect(table.find(1)?.content, equals('v1-predicted'));

        final v2 = createNote(1, 'title', content: 'v2');
        optimistic.applyOptimisticChanges('m2', [
          OptimisticChange.update('note', v1Predicted.toJson(), v2.toJson()),
        ]);
        expect(table.find(1)?.content, equals('v2'));

        final v1Actual = createNote(1, 'title', content: 'v1-actual-server');

        applyCommit(
          table: table,
          optimistic: optimistic,
          context: dummyContext,
          deletes: [server0],
          inserts: [v1Actual],
          stillPending: {1},
        );
        optimistic.confirmOptimisticChange('m1');

        expect(
          table.find(1)?.content,
          equals('v2'),
          reason: 'M2 overlay still applies on top while M2 is pending',
        );

        optimistic.rollbackOptimisticChanges('m2');

        expect(
          table.find(1)?.content,
          equals('v1-actual-server'),
          reason:
              'Rollback of M2 must restore the servers actual post-M1 row, '
              'not the client-predicted v1 recorded in M2s undo snapshot',
        );
      },
    );

    test('delete case: M1 commit is a pure delete, rollback of M2 leaves row absent', () {
      final server0 = createNote(2, 'title', content: 'server0');
      table.insertRow(server0);

      optimistic.applyOptimisticChanges('m1', [
        OptimisticChange.delete('note', server0.toJson()),
      ]);
      expect(table.find(2), isNull);

      final v2 = createNote(2, 'title', content: 'v2-resurrected');
      optimistic.applyOptimisticChanges('m2', [
        OptimisticChange.insert('note', v2.toJson()),
      ]);
      expect(table.find(2)?.content, equals('v2-resurrected'));

      applyCommit(
        table: table,
        optimistic: optimistic,
        context: dummyContext,
        deletes: [server0],
        inserts: [],
        stillPending: {2},
      );
      optimistic.confirmOptimisticChange('m1');

      expect(table.find(2)?.content, equals('v2-resurrected'));

      optimistic.rollbackOptimisticChanges('m2');

      expect(
        table.find(2),
        isNull,
        reason: 'Server committed a delete for key 2; rollback of M2 must '
            'leave the row absent (tombstone), not resurrect the pre-M2 state',
      );
    });

    test('regression: single mutation, no overlapping commit, rollback restores oldRowJson exactly', () {
      final original = createNote(3, 'title', content: 'original');
      table.insertRow(original);

      final updated = createNote(3, 'title', content: 'updated');
      optimistic.applyOptimisticChanges('solo', [
        OptimisticChange.update('note', original.toJson(), updated.toJson()),
      ]);
      expect(table.find(3)?.content, equals('updated'));

      optimistic.rollbackOptimisticChanges('solo');

      expect(table.find(3)?.content, equals('original'));
    });

    test('confirm-path regression: M1 then M2 both confirm, cache ends on M2 committed row', () {
      final server0 = createNote(4, 'title', content: 'server0');
      table.insertRow(server0);

      final v1Predicted = createNote(4, 'title', content: 'v1-predicted');
      optimistic.applyOptimisticChanges('m1', [
        OptimisticChange.update(
          'note',
          server0.toJson(),
          v1Predicted.toJson(),
        ),
      ]);

      final v2Predicted = createNote(4, 'title', content: 'v2-predicted');
      optimistic.applyOptimisticChanges('m2', [
        OptimisticChange.update(
          'note',
          v1Predicted.toJson(),
          v2Predicted.toJson(),
        ),
      ]);

      final v1Actual = createNote(4, 'title', content: 'v1-actual');
      applyCommit(
        table: table,
        optimistic: optimistic,
        context: dummyContext,
        deletes: [server0],
        inserts: [v1Actual],
        stillPending: {4},
      );
      optimistic.confirmOptimisticChange('m1');
      expect(table.find(4)?.content, equals('v2-predicted'));

      final v2Actual = createNote(4, 'title', content: 'v2-actual');
      applyCommit(
        table: table,
        optimistic: optimistic,
        context: dummyContext,
        deletes: [v1Actual],
        inserts: [v2Actual],
        stillPending: {},
      );
      optimistic.confirmOptimisticChange('m2');

      expect(
        table.find(4)?.content,
        equals('v2-actual'),
        reason: 'Untouched by the rollback fix: full confirm chain still '
            'lands on the servers actual final row',
      );
    });

    test('stash lifecycle: after key is released, a fresh optimistic episode rolls back to its own undo snapshot', () {
      final server0 = createNote(5, 'title', content: 'server0');
      table.insertRow(server0);

      final v1Predicted = createNote(5, 'title', content: 'v1-predicted');
      optimistic.applyOptimisticChanges('m1', [
        OptimisticChange.update(
          'note',
          server0.toJson(),
          v1Predicted.toJson(),
        ),
      ]);

      final v2 = createNote(5, 'title', content: 'v2');
      optimistic.applyOptimisticChanges('m2', [
        OptimisticChange.update('note', v1Predicted.toJson(), v2.toJson()),
      ]);

      final v1Actual = createNote(5, 'title', content: 'v1-actual');
      applyCommit(
        table: table,
        optimistic: optimistic,
        context: dummyContext,
        deletes: [server0],
        inserts: [v1Actual],
        stillPending: {5},
      );
      optimistic.confirmOptimisticChange('m1');

      optimistic.rollbackOptimisticChanges('m2');
      expect(table.find(5)?.content, equals('v1-actual'));

      final freshOld = createNote(5, 'title', content: 'v1-actual');
      final freshNew = createNote(5, 'title', content: 'fresh-predicted');
      optimistic.applyOptimisticChanges('m3', [
        OptimisticChange.update('note', freshOld.toJson(), freshNew.toJson()),
      ]);
      expect(table.find(5)?.content, equals('fresh-predicted'));

      optimistic.rollbackOptimisticChanges('m3');

      expect(
        table.find(5)?.content,
        equals('v1-actual'),
        reason: 'm3 rollback must use its own undo snapshot (freshOld), not '
            'a stale stash left over from the m1/m2 episode',
      );
    });
  });
}
