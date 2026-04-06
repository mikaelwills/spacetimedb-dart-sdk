import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';

class TableGenerator {
  final DatabaseSchema schema;
  final TableSchema table;

  TableGenerator(this.schema, this.table);

  String generate() {
    final buf = StringBuffer();

    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln();
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );

    final productType = schema.typeSpace.types[table.productTypeRef].product;
    if (productType == null) {
      throw Exception('Table ${table.name} has no product type');
    }

    final imports = <String>{};
    for (final element in productType.elements) {
      if (element.type.isRef) {
        final refTypeName = element.type.refTypeName(schema.types);
        if (refTypeName != null) {
          final fileName = _toSnakeCase(refTypeName);
          imports.add("import '$fileName.dart';");
        }
      }
    }

    for (final import in imports) {
      buf.writeln(import);
    }
    buf.writeln();

    final className = _toPascalCase(table.name);
    buf.writeln('class $className {');

    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final dartType = element.type.toDartTypeName(
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      buf.writeln('  final $dartType $fieldName;');
    }
    buf.writeln();

    buf.writeln('  $className({');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      buf.writeln('    required this.$fieldName,');
    }
    buf.writeln('  });');
    buf.writeln();

    buf.writeln('  void encodeBsatn(BsatnEncoder encoder) {');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');

      if (element.type.isRef) {
        buf.writeln('    $fieldName.encode(encoder);');
      } else {
        buf.writeln('    encoder.${element.type.encoderMethod}($fieldName);');
      }
    }
    buf.writeln('  }');
    buf.writeln();

    buf.writeln('  static $className decodeBsatn(BsatnDecoder decoder) {');
    buf.writeln('    return $className(');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');

      if (element.type.isRef) {
        final typeName = element.type.toDartTypeName(
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );
        buf.writeln('      $fieldName: $typeName.decode(decoder),');
      } else {
        buf.writeln(
          '      $fieldName: decoder.${element.type.decoderMethod}(),',
        );
      }
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln();

    buf.writeln('  Map<String, dynamic> toJson() {');
    buf.writeln('    return {');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final jsonValue = _getToJsonExpression(fieldName, element.type);
      buf.writeln("      '$fieldName': $jsonValue,");
    }
    buf.writeln('    };');
    buf.writeln('  }');
    buf.writeln();

    buf.writeln('  factory $className.fromJson(Map<String, dynamic> json) {');
    buf.writeln('    return $className(');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final fromJsonExpr = _getFromJsonExpression(fieldName, element.type);
      buf.writeln('      $fieldName: $fromJsonExpr,');
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln();

    buf.writeln('}');
    buf.writeln();

    buf.writeln('class ${className}Decoder extends RowDecoder<$className> {');
    buf.writeln('  @override');
    buf.writeln('  $className decode(BsatnDecoder decoder) {');
    buf.writeln('    return $className.decodeBsatn(decoder);');
    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  @override');

    if (table.primaryKey.isNotEmpty && productType.elements.isNotEmpty) {
      final pkIndex = table.primaryKey.first;
      if (pkIndex < productType.elements.length) {
        final pkElement = productType.elements[pkIndex];
        final pkFieldName = _toCamelCase(pkElement.name ?? 'unknown');
        final pkDartType = pkElement.type.toDartTypeName(
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );
        buf.writeln('  $pkDartType? getPrimaryKey($className row) {');
        buf.writeln('    return row.$pkFieldName;');
      } else {
        buf.writeln('  dynamic getPrimaryKey($className row) {');
        buf.writeln('    return null;');
      }
    } else {
      buf.writeln('  dynamic getPrimaryKey($className row) {');
      buf.writeln('    return null;');
    }

    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln(
      '  Map<String, dynamic>? toJson($className row) => row.toJson();',
    );
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln(
      '  $className? fromJson(Map<String, dynamic> json) => $className.fromJson(json);',
    );
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln('  bool get supportsJsonSerialization => true;');
    buf.writeln('}');

    return buf.toString();
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

  String _toPascalCase(String input) {
    return input
        .split('_')
        .map((word) {
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join('');
  }

  String _toSnakeCase(String input) {
    return input
        .replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '_${match.group(0)!.toLowerCase()}',
        )
        .replaceFirst(RegExp(r'^_'), '');
  }

  String _toCamelCase(String input) {
    final parts = input.split('_');
    if (parts.isEmpty) return input;

    final first = parts.first.toLowerCase();
    final rest = parts
        .skip(1)
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join('');

    return first + rest;
  }
}
