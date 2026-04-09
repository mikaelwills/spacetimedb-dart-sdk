import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/schema_extractor.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/view_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/client_generator.dart';

void main() {
  group('Views', () {
    test('schema extraction includes views from misc_exports', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      expect(
        schema.views,
        isNotEmpty,
        reason: 'Schema should contain views from test module',
      );
      expect(
        schema.views.length,
        equals(3),
        reason:
            'Test module has three views: all_notes, first_note, notes_query_all',
      );

      final allNotesView = schema.views.firstWhere(
        (v) => v.name == 'all_notes',
      );
      expect(allNotesView.name, equals('all_notes'));
      expect(allNotesView.isPublic, isTrue);
      expect(allNotesView.isAnonymous, isTrue);
    });

    test('ViewGenerator correctly identifies view row type', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');
      final viewGenerator = ViewGenerator(schema);

      final allNotesView = schema.views.firstWhere(
        (v) => v.name == 'all_notes',
      );

      final rowType = viewGenerator.getViewRowType(allNotesView);
      expect(
        rowType,
        equals('Note'),
        reason: 'View should return Note type (mapped from table)',
      );

      final noteTable = schema.tables.firstWhere((t) => t.name == 'note');
      final expectedTypeRef = noteTable.productTypeRef;

      final viewTypeRef = viewGenerator.getViewTypeRef(allNotesView);
      expect(
        viewTypeRef,
        equals(expectedTypeRef),
        reason:
            'View type ref should match Note table product type ref ($expectedTypeRef)',
      );
    });

    test('ViewGenerator detects query-builder pattern', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');
      final viewGenerator = ViewGenerator(schema);

      final queryView = schema.views.firstWhere(
        (v) => v.name == 'notes_query_all',
      );

      expect(
        viewGenerator.getViewReturnPattern(queryView),
        equals(ViewReturnType.query),
      );

      final rowType = viewGenerator.getViewRowType(queryView);
      expect(rowType, equals('Note'));

      final noteTable = schema.tables.firstWhere((t) => t.name == 'note');
      final viewTypeRef = viewGenerator.getViewTypeRef(queryView);
      expect(viewTypeRef, equals(noteTable.productTypeRef));
    });

    test('generated client includes view accessor', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      final clientGenerator = ClientGenerator(schema);
      final clientCode = clientGenerator.generate();

      expect(
        clientCode,
        contains('TableCache<Note> get allNotes {'),
        reason: 'Client should have allNotes view accessor',
      );

      expect(
        clientCode,
        contains("getTableByTypedName<Note>('all_notes')"),
        reason: 'View accessor should query cache with view name',
      );

      expect(
        clientCode,
        contains(
          "subscriptionManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());",
        ),
        reason: 'View should be registered with decoder',
      );
    });

    test('generated client includes query-builder view accessor', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      final clientGenerator = ClientGenerator(schema);
      final clientCode = clientGenerator.generate();

      expect(clientCode, contains('TableCache<Note> get notesQueryAll {'));

      expect(
        clientCode,
        contains("getTableByTypedName<Note>('notes_query_all')"),
      );

      expect(
        clientCode,
        contains(
          "subscriptionManager.cache.registerDecoder<Note>('notes_query_all', NoteDecoder());",
        ),
      );
    });
  });
}
