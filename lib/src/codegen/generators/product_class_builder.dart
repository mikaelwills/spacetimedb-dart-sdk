import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/dart_identifiers.dart';
import 'package:spacetimedb_sdk/src/codegen/generators/product_json_expressions.dart';

class ProductClassBuilder {
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;
  final List<TableSchema> tables;
  final ProductJsonExpressions _json;

  ProductClassBuilder({
    required this.typeSpace,
    required this.typeDefs,
    this.tables = const [],
  }) : _json = ProductJsonExpressions(
         typeSpace: typeSpace,
         typeDefs: typeDefs,
         tables: tables,
       );

  Class buildDataClass(String className, ProductType productType) {
    return Class((b) {
      b.name = className;

      for (final element in productType.elements) {
        b.fields.add(
          Field(
            (f) => f
              ..name = _fieldName(element)
              ..type = refer(_dartTypeOf(element.type))
              ..modifier = FieldModifier.final$,
          ),
        );
      }

      b.constructors.add(
        Constructor((c) {
          for (final element in productType.elements) {
            c.optionalParameters.add(
              Parameter(
                (p) => p
                  ..name = _fieldName(element)
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

  String _fieldName(ProductElement element) =>
      toSafeMemberName(_jsonKey(element));

  String _jsonKey(ProductElement element) =>
      toCamelCase(element.name ?? 'unknown');

  String _dartTypeOf(AlgebraicType type) => type.toDartTypeName(
    typeSpace: typeSpace,
    typeDefs: typeDefs,
    tables: tables,
  );

  List<String> _fieldNames(ProductType productType) =>
      productType.elements.map(_fieldName).toList();

  Method _buildEquals(String className, ProductType productType) {
    final fields = _fieldNames(productType);
    final comparisons = fields.map((f) => '$f == other.$f').join(' && ');
    final body = comparisons.isEmpty
        ? 'return identical(this, other) || other is $className;'
        : 'return identical(this, other) || other is $className && $comparisons;';

    return Method(
      (m) => m
        ..name = 'operator =='
        ..annotations.add(refer('override'))
        ..returns = refer('bool')
        ..requiredParameters.add(
          Parameter(
            (p) => p
              ..name = 'other'
              ..type = refer('Object'),
          ),
        )
        ..body = Code(body),
    );
  }

  Method _buildHashCode(ProductType productType) {
    final hashArgs = _fieldNames(productType).join(', ');

    return Method(
      (m) => m
        ..name = 'hashCode'
        ..annotations.add(refer('override'))
        ..type = MethodType.getter
        ..returns = refer('int')
        ..body = Code('return Object.hashAll([$hashArgs]);'),
    );
  }

  Method _buildToString(String className, ProductType productType) {
    final parts = _fieldNames(productType).map((f) => '$f: \$$f').join(', ');

    return Method(
      (m) => m
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
      final fieldName = _fieldName(element);
      final dartType = _dartTypeOf(element.type);
      final nullableType = dartType.endsWith('?') ? dartType : '$dartType?';
      params.add(
        Parameter(
          (p) => p
            ..name = fieldName
            ..named = true
            ..type = refer(nullableType),
        ),
      );
      args.writeln('$fieldName: $fieldName ?? this.$fieldName,');
    }

    return Method(
      (m) => m
        ..name = 'copyWith'
        ..returns = refer(className)
        ..optionalParameters.addAll(params)
        ..body = Code('return $className($args);'),
    );
  }

  Method _buildEncodeBsatn(ProductType productType) {
    final body = StringBuffer();
    for (final element in productType.elements) {
      final expr = element.type.encodeExpression(
        _fieldName(element),
        typeSpace: typeSpace,
        typeDefs: typeDefs,
        tables: tables,
      );
      body.writeln('$expr;');
    }

    return Method(
      (m) => m
        ..name = 'encodeBsatn'
        ..returns = refer('void')
        ..requiredParameters.add(
          Parameter(
            (p) => p
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
      final expr = element.type.decodeExpression(
        typeSpace: typeSpace,
        typeDefs: typeDefs,
        tables: tables,
      );
      args.writeln('${_fieldName(element)}: $expr,');
    }

    return Method(
      (m) => m
        ..name = 'decodeBsatn'
        ..static = true
        ..returns = refer(className)
        ..requiredParameters.add(
          Parameter(
            (p) => p
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
      final jsonValue = _json.toJsonValue(_fieldName(element), element.type);
      entries.writeln("'${_jsonKey(element)}': $jsonValue,");
    }

    return Method(
      (m) => m
        ..name = 'toJson'
        ..returns = refer('Map<String, dynamic>')
        ..body = Code('return {$entries};'),
    );
  }

  Constructor _buildFromJson(String className, ProductType productType) {
    final args = StringBuffer();
    for (final element in productType.elements) {
      final fromJsonExpr = _json.fromJsonValue(_jsonKey(element), element.type);
      args.writeln('${_fieldName(element)}: $fromJsonExpr,');
    }

    return Constructor(
      (c) => c
        ..factory = true
        ..name = 'fromJson'
        ..requiredParameters.add(
          Parameter(
            (p) => p
              ..name = 'json'
              ..type = refer('Map<String, dynamic>'),
          ),
        )
        ..body = Code('return $className($args);'),
    );
  }
}
