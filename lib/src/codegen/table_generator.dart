import 'package:code_builder/code_builder.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/codegen_emitter.dart';

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

    imports.add(Directive.import('package:spacetimedb_dart_sdk/codegen.dart'));

    for (final element in productType.elements) {
      if (element.type.isRef) {
        final refTypeName = element.type.refTypeName(schema.types);
        if (refTypeName != null) {
          final fileName = toSnakeCase(refTypeName);
          imports.add(Directive.import('$fileName.dart'));
        }
      }
    }

    final lib = Library(
      (b) =>
          b
            ..directives.addAll(imports)
            ..body.addAll([
              _buildDataClass(className, productType),
              _buildDecoderClass(className, productType),
            ]),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }

  Class _buildDataClass(String className, ProductType productType) {
    return Class((b) {
      b.name = className;

      for (final element in productType.elements) {
        final fieldName = toCamelCase(element.name ?? 'unknown');
        final dartType = element.type.toDartTypeName(
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );
        b.fields.add(
          Field(
            (f) =>
                f
                  ..name = fieldName
                  ..type = refer(dartType)
                  ..modifier = FieldModifier.final$,
          ),
        );
      }

      b.constructors.add(
        Constructor((c) {
          for (final element in productType.elements) {
            final fieldName = toCamelCase(element.name ?? 'unknown');
            c.optionalParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = fieldName
                      ..named = true
                      ..required = true
                      ..toThis = true,
              ),
            );
          }
        }),
      );

      b.methods.add(_buildEncodeBsatn(productType));
      b.methods.add(_buildDecodeBsatn(className, productType));
      b.methods.add(_buildToJson(productType));
      b.constructors.add(_buildFromJson(className, productType));
      b.methods.add(_buildEquals(className, productType));
      b.methods.add(_buildHashCode(productType));
      b.methods.add(_buildToString(className, productType));
      b.methods.add(_buildCopyWith(className, productType));
    });
  }

  Method _buildEquals(String className, ProductType productType) {
    final fields =
        productType.elements
            .map((e) => toCamelCase(e.name ?? 'unknown'))
            .toList();
    final comparisons = fields.map((f) => '$f == other.$f').join(' && ');

    return Method(
      (m) =>
          m
            ..name = 'operator =='
            ..annotations.add(refer('override'))
            ..returns = refer('bool')
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'other'
                      ..type = refer('Object'),
              ),
            )
            ..body = Code(
              'return identical(this, other) || other is $className && $comparisons;',
            ),
    );
  }

  Method _buildHashCode(ProductType productType) {
    final fields =
        productType.elements
            .map((e) => toCamelCase(e.name ?? 'unknown'))
            .toList();
    final hashArgs = fields.join(', ');

    return Method(
      (m) =>
          m
            ..name = 'hashCode'
            ..annotations.add(refer('override'))
            ..type = MethodType.getter
            ..returns = refer('int')
            ..body = Code('return Object.hash($hashArgs);'),
    );
  }

  Method _buildToString(String className, ProductType productType) {
    final fields =
        productType.elements
            .map((e) => toCamelCase(e.name ?? 'unknown'))
            .toList();
    final parts = fields.map((f) => '$f: \$$f').join(', ');

    return Method(
      (m) =>
          m
            ..name = 'toString'
            ..annotations.add(refer('override'))
            ..returns = refer('String')
            ..body = Code("return '$className($parts)';"),
    );
  }

  Method _buildCopyWith(String className, ProductType productType) {
    final params = <Parameter>[];
    final args = StringBuffer();

    for (final element in productType.elements) {
      final fieldName = toCamelCase(element.name ?? 'unknown');
      final dartType = element.type.toDartTypeName(
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      params.add(
        Parameter(
          (p) =>
              p
                ..name = fieldName
                ..named = true
                ..type = refer('$dartType?'),
        ),
      );
      args.writeln('$fieldName: $fieldName ?? this.$fieldName,');
    }

    return Method(
      (m) =>
          m
            ..name = 'copyWith'
            ..returns = refer(className)
            ..optionalParameters.addAll(params)
            ..body = Code('return $className($args);'),
    );
  }

  Method _buildEncodeBsatn(ProductType productType) {
    final body = StringBuffer();
    for (final element in productType.elements) {
      final fieldName = toCamelCase(element.name ?? 'unknown');
      final expr = element.type.encodeExpression(
        fieldName,
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      body.writeln('$expr;');
    }

    return Method(
      (m) =>
          m
            ..name = 'encodeBsatn'
            ..returns = refer('void')
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'encoder'
                      ..type = refer('BsatnEncoder'),
              ),
            )
            ..body = Code(body.toString()),
    );
  }

  Method _buildDecodeBsatn(String className, ProductType productType) {
    final args = StringBuffer();
    for (final element in productType.elements) {
      final fieldName = toCamelCase(element.name ?? 'unknown');
      final expr = element.type.decodeExpression(
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      args.writeln('$fieldName: $expr,');
    }

    return Method(
      (m) =>
          m
            ..name = 'decodeBsatn'
            ..static = true
            ..returns = refer(className)
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'decoder'
                      ..type = refer('BsatnDecoder'),
              ),
            )
            ..body = Code('return $className($args);'),
    );
  }

  Method _buildToJson(ProductType productType) {
    final entries = StringBuffer();
    for (final element in productType.elements) {
      final fieldName = toCamelCase(element.name ?? 'unknown');
      final jsonValue = _getToJsonExpression(fieldName, element.type);
      entries.writeln("'$fieldName': $jsonValue,");
    }

    return Method(
      (m) =>
          m
            ..name = 'toJson'
            ..returns = refer('Map<String, dynamic>')
            ..body = Code('return {$entries};'),
    );
  }

  Constructor _buildFromJson(String className, ProductType productType) {
    final args = StringBuffer();
    for (final element in productType.elements) {
      final fieldName = toCamelCase(element.name ?? 'unknown');
      final fromJsonExpr = _getFromJsonExpression(fieldName, element.type);
      args.writeln('$fieldName: $fromJsonExpr,');
    }

    return Constructor(
      (c) =>
          c
            ..factory = true
            ..name = 'fromJson'
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'json'
                      ..type = refer('Map<String, dynamic>'),
              ),
            )
            ..body = Code('return $className($args);'),
    );
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

  String _getToJsonExpression(String fieldName, AlgebraicType type) =>
      switch (type) {
        IdentityType() => '$fieldName.toJson()',
        TimestampType() => '$fieldName.toInt()',
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName.toInt()',
        RefType() => '$fieldName.toJson()',
        ArrayType(element: final inner) => _getArrayToJsonExpression(
          fieldName,
          inner,
        ),
        _ => fieldName,
      };

  String _getArrayToJsonExpression(String fieldName, AlgebraicType inner) =>
      switch (inner) {
        RefType() => '$fieldName.map((e) => e.toJson()).toList()',
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName.map((e) => e.toInt()).toList()',
        _ => fieldName,
      };

  String _getFromJsonExpression(String fieldName, AlgebraicType type) {
    final dartType = type.toDartTypeName(
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
    );

    return switch (type) {
      IdentityType() => "Identity.fromJson(json['$fieldName'] ?? '')",
      TimestampType() => "Int64(json['$fieldName'] ?? 0)",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "Int64(json['$fieldName'] ?? 0)",
      RefType() =>
        "$dartType.fromJson(Map<String, dynamic>.from(json['$fieldName'] ?? {}))",
      ArrayType(element: final inner) => _getArrayFromJsonExpression(
        fieldName,
        inner,
      ),
      PrimitiveType(kind: PrimitiveKind.string) => "json['$fieldName'] ?? ''",
      PrimitiveType(kind: PrimitiveKind.bool_) => "json['$fieldName'] ?? false",
      PrimitiveType(kind: PrimitiveKind.f32 || PrimitiveKind.f64) =>
        "(json['$fieldName'] ?? 0.0).toDouble()",
      PrimitiveType() when type.isInt => "json['$fieldName'] ?? 0",
      _ => "json['$fieldName']",
    };
  }

  String _getArrayFromJsonExpression(String fieldName, AlgebraicType inner) {
    final innerDartType = inner.toDartTypeName(
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
    );

    return switch (inner) {
      RefType() =>
        "(json['$fieldName'] ?? []).cast<Map<String, dynamic>>().map((e) => $innerDartType.fromJson(e)).toList()",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "(json['$fieldName'] ?? []).cast<int>().map((e) => Int64(e)).toList()",
      _ => "List<$innerDartType>.from(json['$fieldName'] ?? [])",
    };
  }
}
