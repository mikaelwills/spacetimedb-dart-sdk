import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/table_generator.dart';
import 'package:test/test.dart';

DatabaseSchema _schemaWithTable(String tableName, List<String> fieldNames) {
  final elements =
      fieldNames
          .map(
            (name) => ProductElement(
              name: name,
              type: const PrimitiveType(PrimitiveKind.u32),
            ),
          )
          .toList();

  return DatabaseSchema(
    databaseName: 'test',
    typeSpace: TypeSpace(
      types: [TypeSpaceEntry(product: ProductType(elements: elements))],
    ),
    tables: [
      TableSchema(
        name: tableName,
        productTypeRef: 0,
        primaryKey: const [0],
        indexes: const [],
        constraints: const [],
        sequences: const [],
        schedule: const {},
        tableType: const {},
        tableAccess: const {},
      ),
    ],
    reducers: const [],
    types: const [],
    views: const [],
  );
}

void main() {
  group('TableGenerator hashCode', () {
    test(
      'single-field table uses Object.hashAll (Object.hash needs >=2 args)',
      () {
        final schema = _schemaWithTable('single_field', ['id']);
        final code = TableGenerator(schema, schema.tables.first).generate();

        expect(code, contains('return Object.hashAll([id]);'));
        expect(code, isNot(contains('return Object.hash(id);')));
      },
    );

    test('multi-field table also uses Object.hashAll', () {
      final schema = _schemaWithTable('multi', ['id', 'name']);
      final code = TableGenerator(schema, schema.tables.first).generate();

      expect(code, contains('return Object.hashAll([id, name]);'));
    });
  });
}
