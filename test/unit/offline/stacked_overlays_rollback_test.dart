import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note _note(int id, String content) => Note(
  id: id,
  title: 'n',
  content: content,
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

void main() {
  group('stacked optimistic overlays on one pk', () {
    late ClientCache cache;
    late TableCache<Note> table;
    late OptimisticStateManager optimistic;

    setUp(() {
      cache = ClientCache();
      cache.registerDecoder<Note>('note', NoteDecoder());
      table = cache.getTableByTypedName<Note>('note');
      optimistic = OptimisticStateManager(cache);
    });

    tearDown(() => table.dispose());

    test(
      'rolling back the older of two stacked overlays on the same pk keeps the '
      'newer overlay value, not the pre-optimistic snapshot',
      () {
        final server0 = _note(1, 'server-0');
        table.insertRow(server0);

        final editA = _note(1, 'edit-A');
        optimistic.applyOptimisticChanges('rA', [
          OptimisticChange.update('note', server0.toJson(), editA.toJson()),
        ]);
        expect(table.find(1)?.content, 'edit-A');

        final editB = _note(1, 'edit-B');
        optimistic.applyOptimisticChanges('rB', [
          OptimisticChange.update('note', editA.toJson(), editB.toJson()),
        ]);
        expect(table.find(1)?.content, 'edit-B');

        optimistic.rollbackOptimisticChanges('rA');

        expect(
          table.find(1)?.content,
          'edit-B',
          reason:
              'rB is still pending on pk 1; rolling back rA must leave rB\'s '
              'newer overlay in the cache, not resurrect the pre-optimistic '
              'server-0 value',
        );
      },
    );

    test(
      'Phantom B: rolling back an uncommitted INSERT with a stacked pending '
      'UPDATE must NOT resurrect a phantom row (no committed base)',
      () {
        final insA = _note(1, 'insert-A');
        optimistic.applyOptimisticChanges('rA', [
          OptimisticChange.insert('note', insA.toJson()),
        ]);
        expect(table.find(1)?.content, 'insert-A');

        final updB = _note(1, 'insert-B');
        optimistic.applyOptimisticChanges('rB', [
          OptimisticChange.update('note', insA.toJson(), updB.toJson()),
        ]);
        expect(table.find(1)?.content, 'insert-B');

        optimistic.rollbackOptimisticChanges('rA');

        expect(
          table.find(1),
          isNull,
          reason:
              'the base insert rA had NO committed row under it; rolling it '
              'back must remove pk 1 entirely, not leave rB\'s update overlay '
              'as a phantom over a row that never committed',
        );
      },
    );

    test(
      'Phantom A: rolling back a stacked UPDATE whose oldRow was another '
      'uncommitted overlay must NOT blind-restore that phantom',
      () {
        final insA = _note(1, 'insert-A');
        optimistic.applyOptimisticChanges('rA', [
          OptimisticChange.insert('note', insA.toJson()),
        ]);
        final updB = _note(1, 'insert-B');
        optimistic.applyOptimisticChanges('rB', [
          OptimisticChange.update('note', insA.toJson(), updB.toJson()),
        ]);
        expect(table.find(1)?.content, 'insert-B');

        optimistic.rollbackOptimisticChanges('rB');

        expect(
          table.find(1)?.content,
          'insert-A',
          reason:
              'rB rolled back → rA insert overlay still pending, so pk 1 shows '
              'insert-A (rA is uncommitted but still active, not yet rolled '
              'back)',
        );

        optimistic.rollbackOptimisticChanges('rA');
        expect(
          table.find(1),
          isNull,
          reason:
              'now rA rolled back too and nothing committed under it → pk 1 '
              'must be gone, no phantom',
        );
      },
    );
  });
}
