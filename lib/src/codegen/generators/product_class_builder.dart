import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';

class ProductClassBuilder {
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;

  ProductClassBuilder({required this.typeSpace, required this.typeDefs});

  Class buildDataClass(String className, ProductType productType) {
    return Class((b) {
      b.name = className;

      for (final element in productType.elements) {
        final fieldName = toCamelCase(element.name ?? 'unknown');
        final dartType = element.type.toDartTypeName(
          typeSpace: typeSpace,
          typeDefs: typeDefs,
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
    final body =
        comparisons.isEmpty
            ? 'return identical(this, other) || other is $className;'
            : 'return identical(this, other) || other is $className && $comparisons;';

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
            ..body = Code(body),
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
            ..body = Code('return Object.hashAll([$hashArgs]);'),
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
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      final nullableType = dartType.endsWith('?') ? dartType : '$dartType?';
      params.add(
        Parameter(
          (p) =>
              p
                ..name = fieldName
                ..named = true
                ..type = refer(nullableType),
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
        typeSpace: typeSpace,
        typeDefs: typeDefs,
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
        typeSpace: typeSpace,
        typeDefs: typeDefs,
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

  String _getToJsonExpression(String fieldName, AlgebraicType type) =>
      switch (type) {
        IdentityType() => '$fieldName.toJson()',
        ConnectionIdType() => '$fieldName.toJson()',
        UuidType() => '$fieldName.toJson()',
        TimestampType() => '$fieldName.toInt()',
        TimeDurationType() => '$fieldName.toInt()',
        ScheduleAtType() => '$fieldName.toJson()',
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName.toInt()',
        RefType() => '$fieldName.toJson()',
        ArrayType(element: final inner) => _getArrayToJsonExpression(
          fieldName,
          inner,
        ),
        OptionType(element: final inner) => _getOptionToJsonExpression(
          fieldName,
          inner,
        ),
        _ => fieldName,
      };

  String _getOptionToJsonExpression(String fieldName, AlgebraicType inner) =>
      switch (inner) {
        IdentityType() => '$fieldName?.toJson()',
        ConnectionIdType() => '$fieldName?.toJson()',
        UuidType() => '$fieldName?.toJson()',
        TimestampType() => '$fieldName?.toInt()',
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName?.toInt()',
        RefType() => '$fieldName?.toJson()',
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
      typeSpace: typeSpace,
      typeDefs: typeDefs,
    );

    return switch (type) {
      IdentityType() => "Identity.fromJson(json['$fieldName'] ?? '')",
      ConnectionIdType() =>
        "ConnectionId.fromJson(json['$fieldName'] as String)",
      UuidType() => "Uuid.fromJson(json['$fieldName'] as String)",
      TimestampType() => "Int64(json['$fieldName'] ?? 0)",
      TimeDurationType() => "Int64(json['$fieldName'] ?? 0)",
      ScheduleAtType() =>
        "ScheduleAt.fromJson(Map<String, dynamic>.from(json['$fieldName'] ?? {}))",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "Int64(json['$fieldName'] ?? 0)",
      RefType() =>
        "$dartType.fromJson(Map<String, dynamic>.from(json['$fieldName'] ?? {}))",
      ArrayType(element: final inner) => _getArrayFromJsonExpression(
        fieldName,
        inner,
      ),
      OptionType(element: final inner) => _getOptionFromJsonExpression(
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

  String _getOptionFromJsonExpression(String fieldName, AlgebraicType inner) {
    final innerDartType = inner.toDartTypeName(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
    );
    return switch (inner) {
      IdentityType() =>
        "json['$fieldName'] == null ? null : Identity.fromJson(json['$fieldName'])",
      ConnectionIdType() =>
        "json['$fieldName'] == null ? null : ConnectionId.fromJson(json['$fieldName'] as String)",
      UuidType() =>
        "json['$fieldName'] == null ? null : Uuid.fromJson(json['$fieldName'] as String)",
      TimestampType() =>
        "json['$fieldName'] == null ? null : Int64(json['$fieldName'])",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "json['$fieldName'] == null ? null : Int64(json['$fieldName'])",
      RefType() =>
        "json['$fieldName'] == null ? null : $innerDartType.fromJson(Map<String, dynamic>.from(json['$fieldName']))",
      _ => "json['$fieldName']",
    };
  }

  String _getArrayFromJsonExpression(String fieldName, AlgebraicType inner) {
    final innerDartType = inner.toDartTypeName(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
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
