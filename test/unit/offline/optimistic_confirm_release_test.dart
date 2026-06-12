import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note createNote(int id, String content) => Note(
  id: id,
  title: 'Note $id',
  content: content,
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

OptimisticChange updateChange(int id, String oldContent, String newContent) =>
    OptimisticChange.update(
      'note',
      createNote(id, oldContent).toJson(),
      createNote(id, newContent).toJson(),
    );

void main() {
  group('confirm releases keys', () {
    late ClientCache clientCache;
    late OptimisticStateManager manager;
    late TableCache<Note> table;

    setUp(() {
      clientCache = ClientCache();
      clientCache.registerDecoder<Note>('note', NoteDecoder());
      table = clientCache.getTableByTypedName<Note>('note');
      manager = OptimisticStateManager(clientCache);
    });

    tearDown(() => table.dispose());

    test('key stays protected until its last overlay confirms', () {
      table.insertRow(createNote(1, 'v1'));
      manager.applyOptimisticChanges('req-1', [updateChange(1, 'v1', 'v2')]);
      manager.applyOptimisticChanges('req-2', [updateChange(1, 'v2', 'v3')]);

      expect(manager.optimisticPrimaryKeysForTable('note'), contains(1));

      final firstRemoved = manager.confirmOptimisticChange('req-1');
      expect(firstRemoved, hasLength(1));
      expect(firstRemoved.single.primaryKey, equals(1));
      expect(
        manager.optimisticPrimaryKeysForTable('note'),
        contains(1),
        reason: 'req-2 still pending, key must remain protected',
      );

      final secondRemoved = manager.confirmOptimisticChange('req-2');
      expect(secondRemoved, hasLength(1));
      expect(
        manager.optimisticPrimaryKeysForTable('note'),
        isEmpty,
        reason: 'last overlay confirmed, key is released',
      );
    });

    test('distinct keys release independently', () {
      table.insertRow(createNote(1, 'a1'));
      table.insertRow(createNote(2, 'b1'));
      manager.applyOptimisticChanges('req-a', [updateChange(1, 'a1', 'a2')]);
      manager.applyOptimisticChanges('req-b', [updateChange(2, 'b1', 'b2')]);

      manager.confirmOptimisticChange('req-b');

      final keys = manager.optimisticPrimaryKeysForTable('note');
      expect(keys, contains(1));
      expect(keys, isNot(contains(2)));
    });

    test('rollback also releases the key', () {
      table.insertRow(createNote(1, 'v1'));
      manager.applyOptimisticChanges('req-1', [updateChange(1, 'v1', 'v2')]);

      manager.rollbackOptimisticChanges('req-1');

      expect(manager.optimisticPrimaryKeysForTable('note'), isEmpty);
      expect(table.find(1)?.content, equals('v1'));
    });

    test('confirming an unknown request returns no entries', () {
      expect(manager.confirmOptimisticChange('nope'), isEmpty);
    });
  });
}
