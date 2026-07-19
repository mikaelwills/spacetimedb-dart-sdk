import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:test/test.dart';

TypeDef _typeDef(String name, int ty) =>
    TypeDef(scope: const [], name: name, typeRef: ty, customOrdering: false);

DatabaseSchema _schema() {
  final position = ProductType(
    elements: [
      ProductElement(name: 'x', type: const PrimitiveType(PrimitiveKind.f32)),
      ProductElement(name: 'y', type: const PrimitiveType(PrimitiveKind.f32)),
    ],
  );
  final entityRow = ProductType(
    elements: [
      ProductElement(name: 'id', type: const PrimitiveType(PrimitiveKind.u64)),
    ],
  );

  return DatabaseSchema(
    databaseName: 'test',
    typeSpace: TypeSpace(
      types: [
        TypeSpaceEntry(product: entityRow),
        TypeSpaceEntry(product: position),
      ],
    ),
    tables: [
      TableSchema(
        name: 'entity',
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
    types: [_typeDef('Entity', 0), _typeDef('ServerPosition', 1)],
    views: const [],
  );
}

void main() {
  group('DartGenerator standalone product types', () {
    test('generates a class file for a non-table product type', () {
      final files = DartGenerator(_schema()).generateAll();

      final posFile =
          files.where((f) => f.filename == 'server_position.dart').firstOrNull;
      expect(
        posFile,
        isNotNull,
        reason: 'a non-table [SpacetimeDB.Type] struct must be generated',
      );

      final content = posFile!.content;
      expect(content, contains('class ServerPosition {'));
      expect(content, contains('final double x;'));
      expect(content, contains('final double y;'));
      expect(content, contains('void encodeBsatn(BsatnEncoder encoder)'));
      expect(
        content,
        contains('static ServerPosition decodeBsatn(BsatnDecoder decoder)'),
      );
    });

    test('does NOT emit a separate file for a table product type', () {
      final files = DartGenerator(_schema()).generateAll();
      expect(
        files.where((f) => f.filename == 'entity.dart').length,
        equals(1),
        reason: 'table type emitted once via TableGenerator, not duplicated',
      );
    });

    test('zero-field product type emits compilable operator ==', () {
      final schema = DatabaseSchema(
        databaseName: 'test',
        typeSpace: TypeSpace(
          types: [TypeSpaceEntry(product: ProductType(elements: []))],
        ),
        tables: const [],
        reducers: const [],
        types: [_typeDef('Unit', 0)],
        views: const [],
      );

      final files = DartGenerator(schema).generateAll();
      final content =
          files.firstWhere((f) => f.filename == 'unit.dart').content;

      expect(content, contains('class Unit {'));
      expect(content, isNot(contains('other is Unit && ;')));
      expect(
        content,
        contains('return identical(this, other) || other is Unit;'),
      );
    });
  });
}
