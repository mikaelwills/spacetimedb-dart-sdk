import 'package:code_builder/code_builder.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/product_class_builder.dart';

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

    for (final element in productType.elements) {
      if (element.type.isRef) {
        final refTypeName = element.type.refTypeName(schema.types);
        if (refTypeName != null) {
          final fileName = toSnakeCase(refTypeName);
          imports.add(Directive.import('$fileName.dart'));
        }
      }
    }

    final dataClass = ProductClassBuilder(
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
    ).buildDataClass(className, productType);

    final lib = Library(
      (b) =>
          b
            ..directives.addAll(imports)
            ..body.addAll([
              dataClass,
              _buildDecoderClass(className, productType),
            ]),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }

  Class _buildDecoderClass(String className, ProductType productType) {
    return Class((b) {
      b.name = '${className}Decoder';
      b.extend = refer('RowDecoder<$className>');

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'decode'
                ..annotations.add(refer('override'))
                ..returns = refer(className)
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'decoder'
                          ..type = refer('BsatnDecoder'),
                  ),
                )
                ..body = Code('return $className.decodeBsatn(decoder);'),
        ),
      );

      if (table.primaryKey.isNotEmpty && productType.elements.isNotEmpty) {
        final pkIndex = table.primaryKey.first;
        if (pkIndex < productType.elements.length) {
          final pkElement = productType.elements[pkIndex];
          final pkFieldName = toCamelCase(pkElement.name ?? 'unknown');
          final pkDartType = pkElement.type.toDartTypeName(
            typeSpace: schema.typeSpace,
            typeDefs: schema.types,
          );
          b.methods.add(
            Method(
              (m) =>
                  m
                    ..name = 'getPrimaryKey'
                    ..annotations.add(refer('override'))
                    ..returns = refer('$pkDartType?')
                    ..requiredParameters.add(
                      Parameter(
                        (p) =>
                            p
                              ..name = 'row'
                              ..type = refer(className),
                      ),
                    )
                    ..body = Code('return row.$pkFieldName;'),
            ),
          );
        } else {
          _addNullPkMethod(b, className);
        }
      } else {
        _addNullPkMethod(b, className);
      }

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'toJson'
                ..annotations.add(refer('override'))
                ..returns = refer('Map<String, dynamic>?')
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'row'
                          ..type = refer(className),
                  ),
                )
                ..body = const Code('return row.toJson();'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'fromJson'
                ..annotations.add(refer('override'))
                ..returns = refer('$className?')
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'json'
                          ..type = refer('Map<String, dynamic>'),
                  ),
                )
                ..body = Code('return $className.fromJson(json);'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'supportsJsonSerialization'
                ..annotations.add(refer('override'))
                ..type = MethodType.getter
                ..returns = refer('bool')
                ..body = const Code('return true;'),
        ),
      );
    });
  }

  void _addNullPkMethod(ClassBuilder b, String className) {
    b.methods.add(
      Method(
        (m) =>
            m
              ..name = 'hasPrimaryKey'
              ..annotations.add(refer('override'))
              ..type = MethodType.getter
              ..returns = refer('bool')
              ..body = const Code('return false;'),
      ),
    );
    b.methods.add(
      Method(
        (m) =>
            m
              ..name = 'getPrimaryKey'
              ..annotations.add(refer('override'))
              ..returns = refer('dynamic')
              ..requiredParameters.add(
                Parameter(
                  (p) =>
                      p
                        ..name = 'row'
                        ..type = refer(className),
                ),
              )
              ..body = const Code('return null;'),
      ),
    );
  }
}
