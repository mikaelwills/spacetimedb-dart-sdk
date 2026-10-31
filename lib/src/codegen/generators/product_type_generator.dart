import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/product_class_builder.dart';

class ProductTypeGenerator {
  final String typeName;
  final ProductType productType;
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;
  final List<TableSchema> tables;

  ProductTypeGenerator({
    required this.typeName,
    required this.productType,
    required this.typeSpace,
    required this.typeDefs,
    this.tables = const [],
  });

  String generate() {
    final className = toTypeClassName(typeName);
    final refFiles =
        productType.elements
            .map((e) => e.type.refImportFile(typeDefs, tables))
            .whereType<String>()
            .toSet()
          ..remove('${toSnakeCase(typeName)}.dart');
    final imports = <Directive>[
      Directive.import('package:spacetimedb_sdk/codegen.dart'),
      ...refFiles.map(Directive.import),
    ];

    final dataClass = ProductClassBuilder(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
      tables: tables,
    ).buildDataClass(className, productType);

    final lib = Library(
      (b) => b
        ..directives.addAll(imports)
        ..body.add(dataClass),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }
}
