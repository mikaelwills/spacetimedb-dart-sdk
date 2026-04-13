import 'package:code_builder/code_builder.dart' hide TypeDef;
import '../../codegen/codegen_emitter.dart';
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
    final variantClasses = <Spec>[];
    for (var i = 0; i < sumType.variants.length; i++) {
      variantClasses.add(_buildVariantClass(sumType.variants[i], i));
    }

    final lib = Library(
      (b) =>
          b
            ..directives.add(
              Directive.import('package:spacetimedb_dart_sdk/codegen.dart'),
            )
            ..body.addAll([_buildSealedClass(), ...variantClasses]),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }

  Code _buildSealedClass() {
    final switchCases = StringBuffer();
    for (var i = 0; i < sumType.variants.length; i++) {
      final variant = sumType.variants[i];
      final variantClassName = _getVariantClassName(variant, i);
      switchCases.writeln('case $i: return $variantClassName.decode(decoder);');
    }

    final fromJsonCases = StringBuffer();
    for (var i = 0; i < sumType.variants.length; i++) {
      final variant = sumType.variants[i];
      final variantClassName = _getVariantClassName(variant, i);
      final variantName = variant.name ?? 'Variant$i';
      fromJsonCases.writeln(
        "case '$variantName': return $variantClassName.fromJson(json);",
      );
    }

    return Code('''
sealed class $enumName {
  const $enumName();

  factory $enumName.decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    switch (tag) {
$switchCases      default: throw Exception('Unknown $enumName variant: \$tag');
    }
  }

  factory $enumName.fromJson(Map<String, dynamic> json) {
    final type = json['type'] ?? '';
    switch (type) {
$fromJsonCases      default: throw Exception('Unknown $enumName variant: \$type');
    }
  }

  void encode(BsatnEncoder encoder);
  Map<String, dynamic> toJson();
}
''');
  }

  Class _buildVariantClass(SumVariant variant, int tag) {
    final variantType = _getVariantType(variant);
    final className = _getVariantClassName(variant, tag);
    final variantName = variant.name ?? 'Variant$tag';

    return switch (variantType) {
      VariantType.unit => _buildUnitVariant(className, tag, variantName),
      VariantType.tupleSingle => _buildTupleSingleVariant(
        className,
        variant,
        tag,
        variantName,
      ),
      VariantType.tupleMultiple => _buildTupleMultipleVariant(
        className,
        variant,
        tag,
        variantName,
      ),
      VariantType.struct => _buildStructVariant(
        className,
        variant,
        tag,
        variantName,
      ),
    };
  }

  Class _buildUnitVariant(String className, int tag, String variantName) {
    return Class((b) {
      b
        ..name = className
        ..extend = refer(enumName)
        ..constructors.add(Constructor((c) => c..constant = true))
        ..constructors.add(
          Constructor(
            (c) =>
                c
                  ..factory = true
                  ..name = 'decode'
                  ..requiredParameters.add(
                    Parameter(
                      (p) =>
                          p
                            ..name = 'decoder'
                            ..type = refer('BsatnDecoder'),
                    ),
                  )
                  ..body = Code('return const $className();'),
          ),
        )
        ..constructors.add(
          Constructor(
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
                  ..body = Code('return const $className();'),
          ),
        )
        ..methods.add(
          Method(
            (m) =>
                m
                  ..name = 'encode'
                  ..annotations.add(refer('override'))
                  ..returns = refer('void')
                  ..requiredParameters.add(
                    Parameter(
                      (p) =>
                          p
                            ..name = 'encoder'
                            ..type = refer('BsatnEncoder'),
                    ),
                  )
                  ..body = Code('encoder.writeU8($tag);'),
          ),
        )
        ..methods.add(
          Method(
            (m) =>
                m
                  ..name = 'toJson'
                  ..annotations.add(refer('override'))
                  ..returns = refer('Map<String, dynamic>')
                  ..body = Code("return {'type': '$variantName'};"),
          ),
        );
      _addEqualityMethods(b, className, []);
    });
  }

  Class _buildTupleSingleVariant(
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
    final decodeExpr = fieldType.decodeExpression();
    final encodeExpr = fieldType.encodeExpression('value');
    final toJsonValue = _getToJsonValue('value', fieldType);
    final fromJsonValue = _getFromJsonValue('value', fieldType, dartType);

    return Class((b) {
      b
        ..name = className
        ..extend = refer(enumName)
        ..fields.add(
          Field(
            (f) =>
                f
                  ..name = 'value'
                  ..type = refer(dartType)
                  ..modifier = FieldModifier.final$,
          ),
        )
        ..constructors.add(
          Constructor(
            (c) =>
                c
                  ..constant = true
                  ..requiredParameters.add(
                    Parameter(
                      (p) =>
                          p
                            ..name = 'value'
                            ..toThis = true,
                    ),
                  ),
          ),
        )
        ..constructors.add(
          Constructor(
            (c) =>
                c
                  ..factory = true
                  ..name = 'decode'
                  ..requiredParameters.add(
                    Parameter(
                      (p) =>
                          p
                            ..name = 'decoder'
                            ..type = refer('BsatnDecoder'),
                    ),
                  )
                  ..body = Code('return $className($decodeExpr);'),
          ),
        )
        ..constructors.add(
          Constructor(
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
                  ..body = Code('return $className($fromJsonValue);'),
          ),
        )
        ..methods.add(
          Method(
            (m) =>
                m
                  ..name = 'encode'
                  ..annotations.add(refer('override'))
                  ..returns = refer('void')
                  ..requiredParameters.add(
                    Parameter(
                      (p) =>
                          p
                            ..name = 'encoder'
                            ..type = refer('BsatnEncoder'),
                    ),
                  )
                  ..body = Code('encoder.writeU8($tag); $encodeExpr;'),
          ),
        )
        ..methods.add(
          Method(
            (m) =>
                m
                  ..name = 'toJson'
                  ..annotations.add(refer('override'))
                  ..returns = refer('Map<String, dynamic>')
                  ..body = Code(
                    "return {'type': '$variantName', 'value': $toJsonValue};",
                  ),
          ),
        );
      _addEqualityMethods(b, className, ['value']);
    });
  }

  Class _buildTupleMultipleVariant(
    String className,
    SumVariant variant,
    int tag,
    String variantName,
  ) {
    final elements = variant.algebraicType.product!.elements;

    return Class((b) {
      b
        ..name = className
        ..extend = refer(enumName);

      final constructorParams = <Parameter>[];
      final decodeArgs = StringBuffer();
      final encodeBody = StringBuffer('encoder.writeU8($tag);\n');
      final toJsonEntries = StringBuffer("'type': '$variantName',\n");
      final fromJsonArgs = StringBuffer();

      for (var i = 0; i < elements.length; i++) {
        final element = elements[i];
        final fieldName = 'field$i';
        final dartType = element.type.toDartTypeName();
        final toJsonValue = _getToJsonValue(fieldName, element.type);
        final fromJsonValue = _getFromJsonValue(
          fieldName,
          element.type,
          dartType,
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

        constructorParams.add(
          Parameter(
            (p) =>
                p
                  ..name = fieldName
                  ..toThis = true,
          ),
        );
        decodeArgs.writeln('${element.type.decodeExpression()},');
        encodeBody.writeln('${element.type.encodeExpression(fieldName)};');
        toJsonEntries.writeln("'$fieldName': $toJsonValue,");
        fromJsonArgs.writeln('$fromJsonValue,');
      }

      b.constructors.add(
        Constructor(
          (c) =>
              c
                ..constant = true
                ..requiredParameters.addAll(constructorParams),
        ),
      );

      b.constructors.add(
        Constructor(
          (c) =>
              c
                ..factory = true
                ..name = 'decode'
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'decoder'
                          ..type = refer('BsatnDecoder'),
                  ),
                )
                ..body = Code('return $className($decodeArgs);'),
        ),
      );

      b.constructors.add(
        Constructor(
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
                ..body = Code('return $className($fromJsonArgs);'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'encode'
                ..annotations.add(refer('override'))
                ..returns = refer('void')
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'encoder'
                          ..type = refer('BsatnEncoder'),
                  ),
                )
                ..body = Code(encodeBody.toString()),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'toJson'
                ..annotations.add(refer('override'))
                ..returns = refer('Map<String, dynamic>')
                ..body = Code('return {$toJsonEntries};'),
        ),
      );

      final tupleFields = List.generate(elements.length, (i) => 'field$i');
      _addEqualityMethods(b, className, tupleFields);
    });
  }

  Class _buildStructVariant(
    String className,
    SumVariant variant,
    int tag,
    String variantName,
  ) {
    final elements = variant.algebraicType.product!.elements;

    return Class((b) {
      b
        ..name = className
        ..extend = refer(enumName);

      final constructorParams = <Parameter>[];
      final decodeArgs = StringBuffer();
      final encodeBody = StringBuffer('encoder.writeU8($tag);\n');
      final toJsonEntries = StringBuffer("'type': '$variantName',\n");
      final fromJsonArgs = StringBuffer();

      for (final element in elements) {
        final fieldName = element.name ?? 'field';
        final dartType = element.type.toDartTypeName();
        final toJsonValue = _getToJsonValue(fieldName, element.type);
        final fromJsonValue = _getFromJsonValue(
          fieldName,
          element.type,
          dartType,
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

        constructorParams.add(
          Parameter(
            (p) =>
                p
                  ..name = fieldName
                  ..named = true
                  ..required = true
                  ..toThis = true,
          ),
        );
        decodeArgs.writeln('$fieldName: ${element.type.decodeExpression()},');
        encodeBody.writeln('${element.type.encodeExpression(fieldName)};');
        toJsonEntries.writeln("'$fieldName': $toJsonValue,");
        fromJsonArgs.writeln('$fieldName: $fromJsonValue,');
      }

      b.constructors.add(
        Constructor(
          (c) =>
              c
                ..constant = true
                ..optionalParameters.addAll(constructorParams),
        ),
      );

      b.constructors.add(
        Constructor(
          (c) =>
              c
                ..factory = true
                ..name = 'decode'
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'decoder'
                          ..type = refer('BsatnDecoder'),
                  ),
                )
                ..body = Code('return $className($decodeArgs);'),
        ),
      );

      b.constructors.add(
        Constructor(
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
                ..body = Code('return $className($fromJsonArgs);'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'encode'
                ..annotations.add(refer('override'))
                ..returns = refer('void')
                ..requiredParameters.add(
                  Parameter(
                    (p) =>
                        p
                          ..name = 'encoder'
                          ..type = refer('BsatnEncoder'),
                  ),
                )
                ..body = Code(encodeBody.toString()),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'toJson'
                ..annotations.add(refer('override'))
                ..returns = refer('Map<String, dynamic>')
                ..body = Code('return {$toJsonEntries};'),
        ),
      );

      final structFields = elements.map((e) => e.name ?? 'field').toList();
      _addEqualityMethods(b, className, structFields);
    });
  }

  void _addEqualityMethods(
    ClassBuilder b,
    String className,
    List<String> fieldNames,
  ) {
    if (fieldNames.isEmpty) {
      b.methods.add(
        Method(
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
                  'return identical(this, other) || other is $className;',
                ),
        ),
      );
      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'hashCode'
                ..annotations.add(refer('override'))
                ..type = MethodType.getter
                ..returns = refer('int')
                ..body = const Code('return runtimeType.hashCode;'),
        ),
      );
      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'toString'
                ..annotations.add(refer('override'))
                ..returns = refer('String')
                ..body = Code("return '$className()';"),
        ),
      );
    } else {
      final comparisons = fieldNames.map((f) => '$f == other.$f').join(' && ');
      final hashArgs = fieldNames.join(', ');
      final strParts = fieldNames.map((f) => '$f: \$$f').join(', ');

      b.methods.add(
        Method(
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
        ),
      );
      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'hashCode'
                ..annotations.add(refer('override'))
                ..type = MethodType.getter
                ..returns = refer('int')
                ..body = Code(
                  fieldNames.length == 1
                      ? 'return $hashArgs.hashCode;'
                      : 'return Object.hash($hashArgs);',
                ),
        ),
      );
      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'toString'
                ..annotations.add(refer('override'))
                ..returns = refer('String')
                ..body = Code("return '$className($strParts)';"),
        ),
      );
    }
  }

  String _getVariantClassName(SumVariant variant, int tag) {
    if (variant.name != null && variant.name!.isNotEmpty) {
      return '$enumName${_sumToPascalCase(variant.name!)}';
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

  String _sumToPascalCase(String input) {
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
