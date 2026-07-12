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
  group('stacked cross-request UPDATE older-first rollback', () {
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
      'older-first rollback of two rejected stacked UPDATEs keeps the committed '
      'row, not null',
      () {
        final committed = _note(1, 'C');
        table.insertRow(committed);

        final editA = _note(1, 'A');
        optimistic.applyOptimisticChanges('reqA', [
          OptimisticChange.update('note', committed.toJson(), editA.toJson()),
        ]);
        expect(table.find(1)?.content, 'A');

        final editB = _note(1, 'B');
        optimistic.applyOptimisticChanges('reqB', [
          OptimisticChange.update('note', editA.toJson(), editB.toJson()),
        ]);
        expect(table.find(1)?.content, 'B');

        optimistic.rollbackOptimisticChanges('reqA');
        expect(
          table.find(1)?.content,
          'B',
          reason:
              'reqB still pending on pk 1; rolling back reqA must leave reqB\'s '
              'overlay, not resurrect committed C',
        );

        optimistic.rollbackOptimisticChanges('reqB');

        expect(
          table.find(1)?.content,
          'C',
          reason:
              'both edits rejected; after both rollbacks the pk must show the '
              'true committed base C, not vanish',
        );
      },
    );

    test('reverse-order control: newest-first rollback of the same stack also '
        'restores committed C', () {
      final committed = _note(1, 'C');
      table.insertRow(committed);

      final editA = _note(1, 'A');
      optimistic.applyOptimisticChanges('reqA', [
        OptimisticChange.update('note', committed.toJson(), editA.toJson()),
      ]);
      final editB = _note(1, 'B');
      optimistic.applyOptimisticChanges('reqB', [
        OptimisticChange.update('note', editA.toJson(), editB.toJson()),
      ]);
      expect(table.find(1)?.content, 'B');

      optimistic.rollbackOptimisticChanges('reqB');
      expect(
        table.find(1)?.content,
        'A',
        reason: 'reqA still pending; rolling back reqB shows reqA overlay A',
      );

      optimistic.rollbackOptimisticChanges('reqA');
      expect(
        table.find(1)?.content,
        'C',
        reason: 'both rolled back → committed C',
      );
    });

    test(
      '3-deep stack, older-first rollback of all three restores committed C',
      () {
        final committed = _note(1, 'C');
        table.insertRow(committed);

        final e1 = _note(1, 'E1');
        optimistic.applyOptimisticChanges('r1', [
          OptimisticChange.update('note', committed.toJson(), e1.toJson()),
        ]);
        final e2 = _note(1, 'E2');
        optimistic.applyOptimisticChanges('r2', [
          OptimisticChange.update('note', e1.toJson(), e2.toJson()),
        ]);
        final e3 = _note(1, 'E3');
        optimistic.applyOptimisticChanges('r3', [
          OptimisticChange.update('note', e2.toJson(), e3.toJson()),
        ]);
        expect(table.find(1)?.content, 'E3');

        optimistic.rollbackOptimisticChanges('r1');
        expect(table.find(1)?.content, 'E3');
        optimistic.rollbackOptimisticChanges('r2');
        expect(table.find(1)?.content, 'E3');
        optimistic.rollbackOptimisticChanges('r3');

        expect(
          table.find(1)?.content,
          'C',
          reason: 'all three rejected and rolled back → committed C',
        );
      },
    );

    test('Option B: E2 rejected out of a 4-deep stack — E1 kept, E2 removed, '
        'E3/E4 re-apply against the true base', () {
      final committed = _note(1, 'C');
      table.insertRow(committed);

      final e1 = _note(1, 'E1');
      optimistic.applyOptimisticChanges('r1', [
        OptimisticChange.update('note', committed.toJson(), e1.toJson()),
      ]);
      final e2 = _note(1, 'E2');
      optimistic.applyOptimisticChanges('r2', [
        OptimisticChange.update('note', e1.toJson(), e2.toJson()),
      ]);
      final e3 = _note(1, 'E3');
      optimistic.applyOptimisticChanges('r3', [
        OptimisticChange.update('note', e2.toJson(), e3.toJson()),
      ]);
      final e4 = _note(1, 'E4');
      optimistic.applyOptimisticChanges('r4', [
        OptimisticChange.update('note', e3.toJson(), e4.toJson()),
      ]);
      expect(table.find(1)?.content, 'E4');

      optimistic.rollbackOptimisticChanges('r2');

      expect(
        table.find(1)?.content,
        'E4',
        reason:
            'only E2 was rejected; E1, E3, E4 survive → newest surviving '
            'overlay E4 stays on the pk',
      );
    });
  });
}
