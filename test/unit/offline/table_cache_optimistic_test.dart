import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note createNote(int id, String title) => Note(
  id: id,
  title: title,
  content: '',
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

OptimisticChange insertChange(int id, String title) =>
    OptimisticChange.insert('note', createNote(id, title).toJson());

OptimisticChange updateChange(int id, String oldTitle, String newTitle) =>
    OptimisticChange.update(
      'note',
      createNote(id, oldTitle).toJson(),
      createNote(id, newTitle).toJson(),
    );

OptimisticChange deleteChange(int id, String title) =>
    OptimisticChange.delete('note', createNote(id, title).toJson());

void main() {
  group('OptimisticStateManager', () {
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

    test('optimistic insert adds row and tracks change', () {
      manager.applyOptimisticChanges('req-1', [insertChange(1, 'Test')]);

      expect(table.find(1)?.id, equals(1));
      expect(manager.hasOptimisticChange('req-1'), isTrue);
    });

    test('optimistic update replaces row and tracks old value', () {
      table.insertRow(createNote(1, 'Old'));
      manager.applyOptimisticChanges('req-1', [updateChange(1, 'Old', 'New')]);

      expect(table.find(1)?.title, equals('New'));
      expect(manager.hasOptimisticChange('req-1'), isTrue);
    });

    test('optimistic delete removes row and tracks deleted value', () {
      table.insertRow(createNote(1, 'Test'));
      manager.applyOptimisticChanges('req-1', [deleteChange(1, 'Test')]);

      expect(table.find(1), isNull);
      expect(manager.hasOptimisticChange('req-1'), isTrue);
    });

    test('confirm removes tracking but keeps changes', () {
      manager.applyOptimisticChanges('req-1', [insertChange(1, 'Test')]);
      manager.confirmOptimisticChange('req-1');

      expect(table.find(1)?.id, equals(1));
      expect(manager.hasOptimisticChange('req-1'), isFalse);
    });

    group('rollback', () {
      test('rollback insert removes row', () {
        manager.applyOptimisticChanges('req-1', [insertChange(1, 'Test')]);
        manager.rollbackOptimisticChanges('req-1');

        expect(table.find(1), isNull);
        expect(manager.hasOptimisticChange('req-1'), isFalse);
      });

      test('rollback update restores old value', () {
        table.insertRow(createNote(1, 'Old'));
        manager.applyOptimisticChanges('req-1', [
          updateChange(1, 'Old', 'New'),
        ]);
        manager.rollbackOptimisticChanges('req-1');

        expect(table.find(1)?.title, equals('Old'));
      });

      test('rollback delete restores row', () {
        table.insertRow(createNote(1, 'Test'));
        manager.applyOptimisticChanges('req-1', [deleteChange(1, 'Test')]);
        manager.rollbackOptimisticChanges('req-1');

        expect(table.find(1)?.id, equals(1));
      });

      test('rollback multiple changes in reverse order', () {
        manager.applyOptimisticChanges('req-1', [
          insertChange(1, 'Note 1'),
          insertChange(2, 'Note 2'),
          insertChange(3, 'Note 3'),
        ]);

        manager.rollbackOptimisticChanges('req-1');

        expect(table.count(), equals(0));
      });

      test('rollback only affects specified request', () {
        manager.applyOptimisticChanges('req-1', [insertChange(1, 'Note 1')]);
        manager.applyOptimisticChanges('req-2', [insertChange(2, 'Note 2')]);

        manager.rollbackOptimisticChanges('req-1');

        expect(table.find(1), isNull);
        expect(table.find(2)?.id, equals(2));
        expect(manager.hasOptimisticChange('req-2'), isTrue);
      });
    });

    group('touch-based confirm/rollback', () {
      test('touched keys are confirmed, untouched are rolled back', () {
        manager.applyOptimisticChanges('req-1', [
          insertChange(1, 'Note 1'),
          insertChange(2, 'Note 2'),
        ]);

        manager.confirmOrRollbackWithTouchedKeys('req-1', {
          'note': {1},
        });

        expect(table.find(1)?.id, equals(1));
        expect(table.find(2), isNull);
        expect(manager.hasOptimisticChange('req-1'), isFalse);
      });

      test('tables not in touchedKeys map get fully rolled back', () {
        manager.applyOptimisticChanges('req-1', [insertChange(1, 'Test')]);

        manager.confirmOrRollbackWithTouchedKeys('req-1', {});

        expect(table.find(1), isNull);
      });
    });

    group('clearNonOptimisticRows', () {
      test('clears non-optimistic rows, preserves optimistic ones', () {
        table.insertRow(createNote(1, 'Server'));
        table.insertRow(createNote(2, 'Also Server'));
        manager.applyOptimisticChanges('req-1', [
          insertChange(3, 'Optimistic'),
        ]);

        manager.clearNonOptimisticRows('note');

        expect(table.find(1), isNull);
        expect(table.find(2), isNull);
        expect(table.find(3)?.title, equals('Optimistic'));
      });

      test('clears all rows when no optimistic changes exist', () {
        table.insertRow(createNote(1, 'Server'));
        table.insertRow(createNote(2, 'Also Server'));

        manager.clearNonOptimisticRows('note');

        expect(table.count(), equals(0));
      });
    });

    test(
      'loadFromSerializable no longer needs to preserve optimistic state',
      () {
        manager.applyOptimisticChanges('req-1', [
          insertChange(1, 'Optimistic'),
        ]);

        table.loadFromSerializable([createNote(2, 'Server Note').toJson()]);

        expect(manager.hasOptimisticChange('req-1'), isTrue);
        expect(table.find(2)?.title, equals('Server Note'));
      },
    );

    test('optimisticPrimaryKeysForTable returns correct keys', () {
      manager.applyOptimisticChanges('req-1', [
        insertChange(1, 'A'),
        insertChange(2, 'B'),
      ]);
      manager.applyOptimisticChanges('req-2', [insertChange(3, 'C')]);

      final keys = manager.optimisticPrimaryKeysForTable('note');
      expect(keys, containsAll([1, 2, 3]));
    });
  });
}
