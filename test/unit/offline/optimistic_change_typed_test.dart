import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note buildNote(int id, String title) => Note(
  id: id,
  title: title,
  content: '',
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

void main() {
  late ClientCache clientCache;
  late TableCache<Note> table;

  setUp(() {
    clientCache = ClientCache();
    clientCache.registerDecoder<Note>('note', NoteDecoder());
    table = clientCache.getTableByTypedName<Note>('note');
  });

  group('OptimisticChange typed-row helpers', () {
    test('insertRow extracts table name and serializes via decoder', () {
      final note = buildNote(1, 'Hi');
      final change = OptimisticChange.insertRow(table, note);

      expect(change.tableName, equals('note'));
      expect(change.type, equals(OptimisticChangeType.insert));
      expect(change.newRowJson, equals(note.toJson()));
      expect(change.oldRowJson, isNull);
    });

    test('updateRow serializes both old and new rows', () {
      final before = buildNote(1, 'old');
      final after = buildNote(1, 'new');
      final change = OptimisticChange.updateRow(table, before, after);

      expect(change.tableName, equals('note'));
      expect(change.type, equals(OptimisticChangeType.update));
      expect(change.oldRowJson, equals(before.toJson()));
      expect(change.newRowJson, equals(after.toJson()));
    });

    test('deleteRow serializes the row into oldRowJson', () {
      final note = buildNote(7, 'bye');
      final change = OptimisticChange.deleteRow(table, note);

      expect(change.tableName, equals('note'));
      expect(change.type, equals(OptimisticChangeType.delete));
      expect(change.oldRowJson, equals(note.toJson()));
      expect(change.newRowJson, isNull);
    });

    test('round-trips through toJson / fromJson', () {
      final note = buildNote(1, 'Hi');
      final original = OptimisticChange.insertRow(table, note);
      final restored = OptimisticChange.fromJson(original.toJson());

      expect(restored.tableName, equals(original.tableName));
      expect(restored.type, equals(original.type));
      expect(restored.newRowJson, equals(original.newRowJson));
    });
  });

  group('nextOptimisticIntId', () {
    test('returns a negative integer', () {
      expect(nextOptimisticIntId(), lessThan(0));
    });

    test('successive calls return distinct values', () async {
      final a = nextOptimisticIntId();
      await Future<void>.delayed(const Duration(microseconds: 1));
      final b = nextOptimisticIntId();
      expect(a, isNot(equals(b)));
    });
  });
}
