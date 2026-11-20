import 'package:code_builder/code_builder.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/product_class_builder.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/ref_import_files.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/row_decoder_builder.dart';

class TableGenerator {
  final DatabaseSchema schema;
  final TableSchema table;

  TableGenerator(this.schema, this.table);

  String generate() {
    final productType = schema.typeSpace.types[table.productTypeRef].product;
    if (productType == null) {
      throw Exception('Table ${table.name} has no product type');
    }

    final className = toPascalCase(table.name);
    final imports = <Directive>[];

    imports.add(Directive.import('package:spacetimedb_sdk/codegen.dart'));

    final refFiles = refImportFiles(
      productType.elements.map((element) => element.type),
      ownFileName: '${table.name}.dart',
      typeDefs: schema.types,
      tables: schema.tables,
    );
    imports.addAll(refFiles.map(Directive.import));

    final dataClass = ProductClassBuilder(
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
      tables: schema.tables,
    ).buildDataClass(className, productType);

    final decoderClass = RowDecoderBuilder(
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
      tables: schema.tables,
    ).buildDecoderClass(className, productType, table.primaryKey);

    final lib = Library(
      (b) => b
        ..directives.addAll(imports)
        ..body.addAll([dataClass, decoderClass]),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }
}
