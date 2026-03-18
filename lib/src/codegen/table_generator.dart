import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/type_mapper.dart';

class TableGenerator {
  final DatabaseSchema schema;
  final TableSchema table;

  TableGenerator(this.schema, this.table);

  String generate() {
    final buf = StringBuffer();

    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln();
    buf.writeln("import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';");

    final productType = schema.typeSpace.types[table.productTypeRef].product;
    if (productType == null) {
      throw Exception('Table ${table.name} has no product type');
    }

    // Collect imports for Ref types
    final imports = <String>{};
    for (final element in productType.elements) {
      if (TypeMapper.isRefType(element.algebraicType)) {
        final refTypeName = TypeMapper.getRefTypeName(
          element.algebraicType,
          schema.types,
        );
        if (refTypeName != null) {
          final fileName = _toSnakeCase(refTypeName);
          imports.add("import '$fileName.dart';");
        }
      }
    }

    // Add imports
    for (final import in imports) {
      buf.writeln(import);
    }
    buf.writeln();

    final className = _toPascalCase(table.name);
    buf.writeln('class $className {');

    // Fields
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final dartType = TypeMapper.toDartType(
        element.algebraicType,
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      buf.writeln('  final $dartType $fieldName;');
    }
    buf.writeln();

    // Constructor
    buf.writeln('  $className({');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      buf.writeln('    required this.$fieldName,');
    }
    buf.writeln('  });');
    buf.writeln();

    // encodeBsatn method
    buf.writeln('  void encodeBsatn(BsatnEncoder encoder) {');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');

      if (TypeMapper.isRefType(element.algebraicType)) {
        // For Ref types, call the type's encode method
        buf.writeln('    $fieldName.encode(encoder);');
      } else {
        final method = TypeMapper.getEncoderMethod(element.algebraicType);
        buf.writeln('    encoder.$method($fieldName);');
      }
    }
    buf.writeln('  }');
    buf.writeln();

    // decodeBsatn method
    buf.writeln('  static $className decodeBsatn(BsatnDecoder decoder) {');
    buf.writeln('    return $className(');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');

      if (TypeMapper.isRefType(element.algebraicType)) {
        final typeName = TypeMapper.toDartType(
          element.algebraicType,
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );
        buf.writeln('      $fieldName: $typeName.decode(decoder),');
      } else {
        final method = TypeMapper.getDecoderMethod(element.algebraicType);
        buf.writeln('      $fieldName: decoder.$method(),');
      }
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln();

    // toJson method
    buf.writeln('  Map<String, dynamic> toJson() {');
    buf.writeln('    return {');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final jsonValue = _getToJsonExpression(fieldName, element.algebraicType);
      buf.writeln("      '$fieldName': $jsonValue,");
    }
    buf.writeln('    };');
    buf.writeln('  }');
    buf.writeln();

    // fromJson factory
    buf.writeln('  factory $className.fromJson(Map<String, dynamic> json) {');
    buf.writeln('    return $className(');
    for (final element in productType.elements) {
      final fieldName = _toCamelCase(element.name ?? 'unknown');
      final fromJsonExpr = _getFromJsonExpression(fieldName, element.algebraicType);
      buf.writeln('      $fieldName: $fromJsonExpr,');
    }
    buf.writeln('    );');
    buf.writeln('  }');
    buf.writeln();

    // Close class
    buf.writeln('}');
    buf.writeln();

    // Generate Decoder class
    buf.writeln('class ${className}Decoder extends RowDecoder<$className> {');
    buf.writeln('  @override');
    buf.writeln('  $className decode(BsatnDecoder decoder) {');
    buf.writeln('    return $className.decodeBsatn(decoder);');
    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  @override');

    // Find the actual primary key column and its type
    if (table.primaryKey.isNotEmpty && productType.elements.isNotEmpty) {
      final pkIndex = table.primaryKey.first;
      if (pkIndex < productType.elements.length) {
        final pkElement = productType.elements[pkIndex];
        final pkFieldName = _toCamelCase(pkElement.name ?? 'unknown');
        final pkDartType = TypeMapper.toDartType(
          pkElement.algebraicType,
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );
        // Use dynamic to support any PK type (int, String, etc.)
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
    buf.writeln('  Map<String, dynamic>? toJson($className row) => row.toJson();');
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln('  $className? fromJson(Map<String, dynamic> json) => $className.fromJson(json);');
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln('  bool get supportsJsonSerialization => true;');
    buf.writeln('}');

    return buf.toString();
  }

  String _getToJsonExpression(String fieldName, Map<String, dynamic> algebraicType) {
    if (TypeMapper.isIdentityProduct(algebraicType)) {
      return '$fieldName.toJson()';
    }
    if (_isTimestamp(algebraicType)) {
      return '$fieldName.toInt()';
    }
    if (algebraicType.containsKey('U64') || algebraicType.containsKey('I64')) {
      return '$fieldName.toInt()';
    }
    if (TypeMapper.isRefType(algebraicType)) {
      return '$fieldName.toJson()';
    }
    if (algebraicType.containsKey('Array')) {
      final elementType = algebraicType['Array'] as Map<String, dynamic>;
      if (TypeMapper.isRefType(elementType)) {
        return '$fieldName.map((e) => e.toJson()).toList()';
      }
      if (elementType.containsKey('U64') || elementType.containsKey('I64')) {
        return '$fieldName.map((e) => e.toInt()).toList()';
      }
    }
    return fieldName;
  }

  String _getFromJsonExpression(String fieldName, Map<String, dynamic> algebraicType) {
    final dartType = TypeMapper.toDartType(
      algebraicType,
      typeSpace: schema.typeSpace,
      typeDefs: schema.types,
    );

    if (TypeMapper.isIdentityProduct(algebraicType)) {
      return "Identity.fromJson(json['$fieldName'] as String)";
    }
    if (_isTimestamp(algebraicType)) {
      return "Int64((json['$fieldName'] as int?) ?? 0)";
    }
    if (algebraicType.containsKey('U64') || algebraicType.containsKey('I64')) {
      return "Int64((json['$fieldName'] as int?) ?? 0)";
    }
    if (TypeMapper.isRefType(algebraicType)) {
      return "$dartType.fromJson(json['$fieldName'] as Map<String, dynamic>)";
    }
    if (algebraicType.containsKey('Array')) {
      final elementType = algebraicType['Array'] as Map<String, dynamic>;
      final innerDartType = TypeMapper.toDartType(
        elementType,
        typeSpace: schema.typeSpace,
        typeDefs: schema.types,
      );
      if (TypeMapper.isRefType(elementType)) {
        return "(json['$fieldName'] as List?)?.map((e) => $innerDartType.fromJson(e as Map<String, dynamic>)).toList() ?? []";
      }
      if (elementType.containsKey('U64') || elementType.containsKey('I64')) {
        return "(json['$fieldName'] as List?)?.map((e) => Int64(e as int)).toList() ?? []";
      }
      return "(json['$fieldName'] as List?)?.cast<$innerDartType>() ?? []";
    }
    if (algebraicType.containsKey('String')) {
      return "(json['$fieldName'] as String?) ?? ''";
    }
    if (algebraicType.containsKey('Bool')) {
      return "(json['$fieldName'] as bool?) ?? false";
    }
    if (algebraicType.containsKey('F32') || algebraicType.containsKey('F64')) {
      return "(json['$fieldName'] as num?)?.toDouble() ?? 0.0";
    }
    if (_isIntType(algebraicType)) {
      return "(json['$fieldName'] as int?) ?? 0";
    }
    return "json['$fieldName']";
  }

  bool _isTimestamp(Map<String, dynamic> algebraicType) {
    if (algebraicType.containsKey('Product')) {
      final product = algebraicType['Product'];
      if (product is Map && product.containsKey('elements')) {
        final elements = product['elements'] as List;
        if (elements.length == 1) {
          final element = elements[0];
          if (element['name'] != null &&
              element['name']['some'] == '__timestamp_micros_since_unix_epoch__') {
            return true;
          }
        }
      }
    }
    return false;
  }

  bool _isIntType(Map<String, dynamic> algebraicType) {
    return algebraicType.containsKey('U8') ||
        algebraicType.containsKey('U16') ||
        algebraicType.containsKey('U32') ||
        algebraicType.containsKey('I8') ||
        algebraicType.containsKey('I16') ||
        algebraicType.containsKey('I32');
  }

  String _toPascalCase(String input) {
    return input.split('_').map((word) {
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join('');
  }

  String _toSnakeCase(String input) {
    return input
        .replaceAllMapped(
            RegExp(r'[A-Z]'), (match) => '_${match.group(0)!.toLowerCase()}')
        .replaceFirst(RegExp(r'^_'), '');
  }

  String _toCamelCase(String input) {
    final parts = input.split('_');
    if (parts.isEmpty) return input;

    final first = parts.first.toLowerCase();
    final rest = parts.skip(1).map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join('');

    return first + rest;
  }
}
