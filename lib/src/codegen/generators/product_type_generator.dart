import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/product_class_builder.dart';

class ProductTypeGenerator {
  final String typeName;
  final ProductType productType;
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;

  ProductTypeGenerator({
    required this.typeName,
    required this.productType,
    required this.typeSpace,
    required this.typeDefs,
  });

  String generate() {
    final className = toTypeClassName(typeName);
    final imports = <Directive>[
      Directive.import('package:spacetimedb_sdk/codegen.dart'),
    ];

    for (final element in productType.elements) {
      if (element.type.isRef) {
        final refTypeName = element.type.refTypeName(typeDefs);
        if (refTypeName != null) {
          imports.add(Directive.import('${toSnakeCase(refTypeName)}.dart'));
        }
      }
    }

    final dataClass = ProductClassBuilder(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
    ).buildDataClass(className, productType);

    final lib = Library(
      (b) =>
          b
            ..directives.addAll(imports)
            ..body.add(dataClass),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }
}
