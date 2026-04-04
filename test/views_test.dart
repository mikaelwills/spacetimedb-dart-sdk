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
        equals(2),
        reason: 'Test module has two views: all_notes and first_note',
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

      final view = schema.views.first;

      // all_notes returns Vec<Note>, so row type should be "Note"
      final rowType = viewGenerator.getViewRowType(view);
      expect(
        rowType,
        equals('Note'),
        reason: 'View should return Note type (mapped from table)',
      );

      // Check type reference matches the Note table's product type ref
      final noteTable = schema.tables.firstWhere((t) => t.name == 'note');
      final expectedTypeRef = noteTable.productTypeRef;

      final viewTypeRef = viewGenerator.getViewTypeRef(view);
      expect(
        viewTypeRef,
        equals(expectedTypeRef),
        reason:
            'View type ref should match Note table product type ref ($expectedTypeRef)',
      );
    });

    test('generated client includes view accessor', () async {
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      // Generate the actual client code
      final clientGenerator = ClientGenerator(schema);
      final clientCode = clientGenerator.generate();

      // Verify view accessor getter exists
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

      // Verify view registration in connect method
      expect(
        clientCode,
        contains('// Auto-register view decoders'),
        reason: 'Client should have view decoder registration comment',
      );

      expect(
        clientCode,
        contains(
          "subscriptionManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());",
        ),
        reason: 'View should be registered with decoder',
      );
    });
  });
}
