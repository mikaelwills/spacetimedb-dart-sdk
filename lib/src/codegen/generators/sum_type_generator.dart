import '../models/type_models.dart';

enum VariantType { unit, tupleSingle, tupleMultiple, struct }

class SumTypeGenerator {
  final String enumName;
  final SumType sumType;
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;

  SumTypeGenerator({
    required this.enumName,
    required this.sumType,
    required this.typeSpace,
    required this.typeDefs,
  });

  String generate() {
    final buffer = StringBuffer();

    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln();
    buffer.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buffer.writeln();

    buffer.writeln(_generateSealedClass());
    buffer.writeln();

    for (var i = 0; i < sumType.variants.length; i++) {
      buffer.writeln(_generateVariantClass(sumType.variants[i], i));
      buffer.writeln();
    }

    return buffer.toString();
  }

  String _generateSealedClass() {
    return '''
sealed class $enumName {
  const $enumName();

  factory $enumName.decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    switch (tag) {
${_generateSwitchCases()}
      default: throw Exception('Unknown $enumName variant: \$tag');
    }
  }

  factory $enumName.fromJson(Map<String, dynamic> json) {
    final type = json['type'] ?? '';
    switch (type) {
${_generateFromJsonSwitchCases()}
      default: throw Exception('Unknown $enumName variant: \$type');
    }
  }

  void encode(BsatnEncoder encoder);
  Map<String, dynamic> toJson();
}''';
  }

  String _generateSwitchCases() {
    final cases = <String>[];
    for (var i = 0; i < sumType.variants.length; i++) {
      final variant = sumType.variants[i];
      final variantClassName = _getVariantClassName(variant, i);
      cases.add('      case $i: return $variantClassName.decode(decoder);');
    }
    return cases.join('\n');
  }

  String _generateFromJsonSwitchCases() {
    final cases = <String>[];
    for (var i = 0; i < sumType.variants.length; i++) {
      final variant = sumType.variants[i];
      final variantClassName = _getVariantClassName(variant, i);
      final variantName = variant.name ?? 'Variant$i';
      cases.add(
        "      case '$variantName': return $variantClassName.fromJson(json);",
      );
    }
    return cases.join('\n');
  }

  String _generateVariantClass(SumVariant variant, int tag) {
    final variantType = _getVariantType(variant);
    final className = _getVariantClassName(variant, tag);
    final variantName = variant.name ?? 'Variant$tag';

    switch (variantType) {
      case VariantType.unit:
        return _generateUnitVariant(className, tag, variantName);
      case VariantType.tupleSingle:
        return _generateTupleSingleVariant(
          className,
          variant,
          tag,
          variantName,
        );
      case VariantType.tupleMultiple:
        return _generateTupleMultipleVariant(
          className,
          variant,
          tag,
          variantName,
        );
      case VariantType.struct:
        return _generateStructVariant(className, variant, tag, variantName);
    }
  }

  String _generateUnitVariant(String className, int tag, String variantName) {
    return '''
class $className extends $enumName {
  const $className();

  factory $className.decode(BsatnDecoder decoder) {
    return const $className();
  }

  factory $className.fromJson(Map<String, dynamic> json) {
    return const $className();
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8($tag);
  }

  @override
  Map<String, dynamic> toJson() => {'type': '$variantName'};
}''';
  }

  String _generateTupleSingleVariant(
    String className,
    SumVariant variant,
    int tag,
    String variantName,
  ) {
    final type = variant.algebraicType;
    final AlgebraicType fieldType;

    if (type.product != null && type.product!.elements.isNotEmpty) {
      fieldType = type.product!.elements[0].type;
    } else {
      fieldType = variant.parsedType;
    }

    final dartType = fieldType.toDartTypeName();
    final decoderMethod = fieldType.decoderMethod;
    final encoderMethod = fieldType.encoderMethod;
    final toJsonValue = _getToJsonValue('value', fieldType);
    final fromJsonValue = _getFromJsonValue('value', fieldType, dartType);

    return '''
class $className extends $enumName {
  final $dartType value;

  const $className(this.value);

  factory $className.decode(BsatnDecoder decoder) {
    return $className(decoder.$decoderMethod());
  }

  factory $className.fromJson(Map<String, dynamic> json) {
    return $className($fromJsonValue);
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8($tag);
    encoder.$encoderMethod(value);
  }

  @override
  Map<String, dynamic> toJson() => {'type': '$variantName', 'value': $toJsonValue};
}''';
  }

  String _generateTupleMultipleVariant(
    String className,
    SumVariant variant,
    int tag,
    String variantName,
  ) {
    final elements = variant.algebraicType.product!.elements;
    final fields = <String>[];
    final params = <String>[];
    final decodeStatements = <String>[];
    final encodeStatements = <String>[];
    final toJsonFields = <String>[];
    final fromJsonArgs = <String>[];

    for (var i = 0; i < elements.length; i++) {
      final element = elements[i];
      final fieldName = 'field$i';
      final dartType = element.type.toDartTypeName();
      final decoderMethod = element.type.decoderMethod;
      final encoderMethod = element.type.encoderMethod;
      final toJsonValue = _getToJsonValue(fieldName, element.type);
      final fromJsonValue = _getFromJsonValue(
        fieldName,
        element.type,
        dartType,
      );

      fields.add('  final $dartType $fieldName;');
      params.add('this.$fieldName');
      decodeStatements.add('      decoder.$decoderMethod(),');
      encodeStatements.add('    encoder.$encoderMethod($fieldName);');
      toJsonFields.add("      '$fieldName': $toJsonValue,");
      fromJsonArgs.add('      $fromJsonValue,');
    }

    return '''
class $className extends $enumName {
${fields.join('\n')}

  const $className(${params.join(', ')});

  factory $className.decode(BsatnDecoder decoder) {
    return $className(
${decodeStatements.join('\n')}
    );
  }

  factory $className.fromJson(Map<String, dynamic> json) {
    return $className(
${fromJsonArgs.join('\n')}
    );
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8($tag);
${encodeStatements.join('\n')}
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': '$variantName',
${toJsonFields.join('\n')}
  };
}''';
  }

  String _generateStructVariant(
    String className,
    SumVariant variant,
    int tag,
    String variantName,
  ) {
    final elements = variant.algebraicType.product!.elements;
    final fields = <String>[];
    final namedParams = <String>[];
    final decodeStatements = <String>[];
    final encodeStatements = <String>[];
    final toJsonFields = <String>[];
    final fromJsonArgs = <String>[];

    for (final element in elements) {
      final fieldName = element.name ?? 'field';
      final dartType = element.type.toDartTypeName();
      final decoderMethod = element.type.decoderMethod;
      final encoderMethod = element.type.encoderMethod;
      final toJsonValue = _getToJsonValue(fieldName, element.type);
      final fromJsonValue = _getFromJsonValue(
        fieldName,
        element.type,
        dartType,
      );

      fields.add('  final $dartType $fieldName;');
      namedParams.add('required this.$fieldName');
      decodeStatements.add('      $fieldName: decoder.$decoderMethod(),');
      encodeStatements.add('    encoder.$encoderMethod($fieldName);');
      toJsonFields.add("      '$fieldName': $toJsonValue,");
      fromJsonArgs.add('      $fieldName: $fromJsonValue,');
    }

    return '''
class $className extends $enumName {
${fields.join('\n')}

  const $className({${namedParams.join(', ')}});

  factory $className.decode(BsatnDecoder decoder) {
    return $className(
${decodeStatements.join('\n')}
    );
  }

  factory $className.fromJson(Map<String, dynamic> json) {
    return $className(
${fromJsonArgs.join('\n')}
    );
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8($tag);
${encodeStatements.join('\n')}
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': '$variantName',
${toJsonFields.join('\n')}
  };
}''';
  }

  String _getVariantClassName(SumVariant variant, int tag) {
    if (variant.name != null && variant.name!.isNotEmpty) {
      return '$enumName${_toPascalCase(variant.name!)}';
    }
    return '${enumName}Variant$tag';
  }

  VariantType _getVariantType(SumVariant variant) {
    final type = variant.algebraicType;

    if (type.product == null &&
        type.sum == null &&
        variant.parsedType.isPrimitive) {
      return VariantType.tupleSingle;
    }

    if (type.product == null) {
      return VariantType.unit;
    }

    final elements = type.product!.elements;

    if (elements.isEmpty) {
      return VariantType.unit;
    }

    final allUnnamed = elements.every((e) => e.name == null || e.name!.isEmpty);

    if (allUnnamed) {
      return elements.length == 1
          ? VariantType.tupleSingle
          : VariantType.tupleMultiple;
    }

    return VariantType.struct;
  }

  String _toPascalCase(String input) {
    if (input.isEmpty) return input;
    return input[0].toUpperCase() + input.substring(1);
  }

  String _getToJsonValue(String fieldName, AlgebraicType type) =>
      switch (type) {
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName.toInt()',
        _ => fieldName,
      };

  String _getFromJsonValue(
    String fieldName,
    AlgebraicType type,
    String dartType,
  ) => switch (type) {
    PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
      "Int64(json['$fieldName'] ?? 0)",
    PrimitiveType(kind: PrimitiveKind.string) => "json['$fieldName'] ?? ''",
    PrimitiveType(kind: PrimitiveKind.bool_) => "json['$fieldName'] ?? false",
    PrimitiveType(kind: PrimitiveKind.f32 || PrimitiveKind.f64) =>
      "(json['$fieldName'] ?? 0.0).toDouble()",
    PrimitiveType() when type.isInt => "json['$fieldName'] ?? 0",
    _ => "json['$fieldName']",
  };
}
