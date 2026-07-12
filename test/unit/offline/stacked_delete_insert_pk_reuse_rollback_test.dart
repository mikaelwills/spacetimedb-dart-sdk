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
  group('stacked DELETE-then-INSERT pk reuse rollback', () {
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
      'delete-then-insert reusing the same pk, older-first rollback keeps the '
      'committed row, not null',
      () {
        final committed = _note(1, 'C');
        table.insertRow(committed);

        optimistic.applyOptimisticChanges('reqA', [
          OptimisticChange.delete('note', committed.toJson()),
        ]);
        expect(table.find(1), isNull, reason: 'reqA deleted C optimistically');

        final insB = _note(1, 'B');
        optimistic.applyOptimisticChanges('reqB', [
          OptimisticChange.insert('note', insB.toJson()),
        ]);
        expect(table.find(1)?.content, 'B', reason: 'reqB inserted B at pk 1');

        optimistic.rollbackOptimisticChanges('reqA');
        expect(
          table.find(1)?.content,
          'B',
          reason:
              'reqB still pending; rolling back reqA restores C then reapplies '
              'reqB overlay B',
        );

        optimistic.rollbackOptimisticChanges('reqB');

        expect(
          table.find(1)?.content,
          'C',
          reason:
              'delete of C rejected -> C stays; insert of B rejected -> B '
              'drops; end state is the committed base C, not null',
        );
      },
    );

    test(
      'reverse-order control: newest-first rollback of the same delete/insert '
      'stack also restores committed C',
      () {
        final committed = _note(1, 'C');
        table.insertRow(committed);

        optimistic.applyOptimisticChanges('reqA', [
          OptimisticChange.delete('note', committed.toJson()),
        ]);
        final insB = _note(1, 'B');
        optimistic.applyOptimisticChanges('reqB', [
          OptimisticChange.insert('note', insB.toJson()),
        ]);
        expect(table.find(1)?.content, 'B');

        optimistic.rollbackOptimisticChanges('reqB');
        expect(
          table.find(1),
          isNull,
          reason:
              'reqB insert rolled back; reqA delete still pending, so pk 1 is '
              'optimistically deleted',
        );

        optimistic.rollbackOptimisticChanges('reqA');
        expect(
          table.find(1)?.content,
          'C',
          reason: 'reqA delete rolled back -> committed C restored',
        );
      },
    );

    test(
      'phantom guard preserved: uncommitted INSERT re-used by a stacked INSERT '
      'still drops the pk on full rollback (no committed base recorded)',
      () {
        // No committed row under pk 1. reqA inserts, reqB inserts same pk.
        final insA = _note(1, 'A');
        optimistic.applyOptimisticChanges('reqA', [
          OptimisticChange.insert('note', insA.toJson()),
        ]);
        final insB = _note(1, 'B');
        optimistic.applyOptimisticChanges('reqB', [
          OptimisticChange.insert('note', insB.toJson()),
        ]);
        expect(table.find(1)?.content, 'B');

        optimistic.rollbackOptimisticChanges('reqA');
        optimistic.rollbackOptimisticChanges('reqB');

        expect(
          table.find(1),
          isNull,
          reason:
              'no committed base was ever recorded for pk 1; rolling both back '
              'must leave nothing — a phantom must not survive',
        );
      },
    );
  });
}
