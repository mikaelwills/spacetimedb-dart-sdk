import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/generators/product_type_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/row_decoder_builder.dart';

class ViewRowTypeGenerator extends ProductTypeGenerator {
  ViewRowTypeGenerator({
    required super.typeName,
    required super.productType,
    required super.typeSpace,
    required super.typeDefs,
    super.tables,
  });

  @override
  Iterable<Class> extraClasses(String className) => [
    RowDecoderBuilder(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
      tables: tables,
    ).buildRowTypeDecoder(className, productType),
  ];
}
