import 'package:spacetimedb_sdk/src/exceptions.dart';
import '../codegen_emitter.dart';
import '../models/type_models.dart';

enum PrimitiveKind {
  u8,
  u16,
  u32,
  u64,
  i8,
  i16,
  i32,
  i64,
  f32,
  f64,
  bool_,
  string,
}

sealed class AlgebraicType {
  const AlgebraicType();

  static const _primitiveMap = {
    'U8': PrimitiveKind.u8,
    'U16': PrimitiveKind.u16,
    'U32': PrimitiveKind.u32,
    'U64': PrimitiveKind.u64,
    'I8': PrimitiveKind.i8,
    'I16': PrimitiveKind.i16,
    'I32': PrimitiveKind.i32,
    'I64': PrimitiveKind.i64,
    'F32': PrimitiveKind.f32,
    'F64': PrimitiveKind.f64,
    'Bool': PrimitiveKind.bool_,
    'String': PrimitiveKind.string,
  };

  static AlgebraicType fromJson(Map<String, dynamic> json) {
    final ref = json['Ref'];
    if (ref is int) {
      return RefType(ref);
    }

    if (json.containsKey('Array')) {
      final inner = json['Array'];
      if (inner is Map<String, dynamic> && inner.containsKey('U8')) {
        return const ByteArrayType();
      }
      if (inner is Map<String, dynamic>) {
        return ArrayType(fromJson(inner));
      }
      return ArrayType(fromJson(Map<String, dynamic>.from(inner)));
    }

    final product = json['Product'];
    if (product is Map<String, dynamic>) {
      final elementsJson = product['elements'];
      if (elementsJson is List && elementsJson.length == 1) {
        final element = elementsJson[0];
        if (element is Map<String, dynamic>) {
          final name = element['name'];
          if (name is Map && name['some'] == '__identity__') {
            return const IdentityType();
          }
          if (name is Map &&
              name['some'] == '__timestamp_micros_since_unix_epoch__') {
            return const TimestampType();
          }
          if (name is Map && name['some'] == '__time_duration_micros__') {
            return const TimeDurationType();
          }
        }
      }
      final elements =
          elementsJson is List
              ? elementsJson
                  .whereType<Map<String, dynamic>>()
                  .map(ProductField.fromJson)
                  .toList()
              : <ProductField>[];
      return IrProductType(elements: elements);
    }

    final sum = json['Sum'];
    if (sum is Map<String, dynamic>) {
      final variantsJson = sum['variants'];
      final variants =
          variantsJson is List
              ? variantsJson
                  .whereType<Map<String, dynamic>>()
                  .map(IrSumVariant.fromJson)
                  .toList()
              : <IrSumVariant>[];
      final optionInner = _detectOptionInner(variants);
      if (optionInner != null) {
        return OptionType(optionInner);
      }
      if (_isScheduleAt(variants)) {
        return const ScheduleAtType();
      }
      return IrSumType(variants: variants);
    }

    for (final entry in _primitiveMap.entries) {
      if (json.containsKey(entry.key)) {
        return PrimitiveType(entry.value);
      }
    }

    if (json.containsKey('Timestamp')) {
      return const TimestampType();
    }

    throw SpacetimeDbSchemaException(
      'Unknown algebraic type shape: ${json.keys.toList()}',
    );
  }

  String toDartTypeName({
    TypeSpace? typeSpace,
    List<TypeDef>? typeDefs,
  }) => switch (this) {
    PrimitiveType(kind: PrimitiveKind.u8) => 'int',
    PrimitiveType(kind: PrimitiveKind.u16) => 'int',
    PrimitiveType(kind: PrimitiveKind.u32) => 'int',
    PrimitiveType(kind: PrimitiveKind.u64) => 'Int64',
    PrimitiveType(kind: PrimitiveKind.i8) => 'int',
    PrimitiveType(kind: PrimitiveKind.i16) => 'int',
    PrimitiveType(kind: PrimitiveKind.i32) => 'int',
    PrimitiveType(kind: PrimitiveKind.i64) => 'Int64',
    PrimitiveType(kind: PrimitiveKind.f32) => 'double',
    PrimitiveType(kind: PrimitiveKind.f64) => 'double',
    PrimitiveType(kind: PrimitiveKind.bool_) => 'bool',
    PrimitiveType(kind: PrimitiveKind.string) => 'String',
    IdentityType() => 'Identity',
    TimestampType() => 'Int64',
    TimeDurationType() => 'Int64',
    ScheduleAtType() => 'ScheduleAt',
    ByteArrayType() => 'List<int>',
    ArrayType(element: final inner) =>
      'List<${inner.toDartTypeName(typeSpace: typeSpace, typeDefs: typeDefs)}>',
    OptionType(element: final inner) =>
      '${inner.toDartTypeName(typeSpace: typeSpace, typeDefs: typeDefs)}?',
    RefType(index: final i) => _resolveRefTypeName(i, typeSpace, typeDefs),
    IrProductType() => 'dynamic',
    IrSumType() => 'dynamic',
  };

  String get encoderMethod => switch (this) {
    PrimitiveType(kind: PrimitiveKind.u8) => 'writeU8',
    PrimitiveType(kind: PrimitiveKind.u16) => 'writeU16',
    PrimitiveType(kind: PrimitiveKind.u32) => 'writeU32',
    PrimitiveType(kind: PrimitiveKind.u64) => 'writeU64',
    PrimitiveType(kind: PrimitiveKind.i8) => 'writeI8',
    PrimitiveType(kind: PrimitiveKind.i16) => 'writeI16',
    PrimitiveType(kind: PrimitiveKind.i32) => 'writeI32',
    PrimitiveType(kind: PrimitiveKind.i64) => 'writeI64',
    PrimitiveType(kind: PrimitiveKind.f32) => 'writeF32',
    PrimitiveType(kind: PrimitiveKind.f64) => 'writeF64',
    PrimitiveType(kind: PrimitiveKind.bool_) => 'writeBool',
    PrimitiveType(kind: PrimitiveKind.string) => 'writeString',
    IdentityType() => 'writeIdentity',
    TimestampType() => 'writeI64',
    TimeDurationType() => 'writeI64',
    ByteArrayType() => 'writeByteArray',
    _ => 'write',
  };

  String get decoderMethod => switch (this) {
    PrimitiveType(kind: PrimitiveKind.u8) => 'readU8',
    PrimitiveType(kind: PrimitiveKind.u16) => 'readU16',
    PrimitiveType(kind: PrimitiveKind.u32) => 'readU32',
    PrimitiveType(kind: PrimitiveKind.u64) => 'readU64',
    PrimitiveType(kind: PrimitiveKind.i8) => 'readI8',
    PrimitiveType(kind: PrimitiveKind.i16) => 'readI16',
    PrimitiveType(kind: PrimitiveKind.i32) => 'readI32',
    PrimitiveType(kind: PrimitiveKind.i64) => 'readI64',
    PrimitiveType(kind: PrimitiveKind.f32) => 'readF32',
    PrimitiveType(kind: PrimitiveKind.f64) => 'readF64',
    PrimitiveType(kind: PrimitiveKind.bool_) => 'readBool',
    PrimitiveType(kind: PrimitiveKind.string) => 'readString',
    IdentityType() => 'readIdentity',
    TimestampType() => 'readI64',
    TimeDurationType() => 'readI64',
    ByteArrayType() => 'readByteArray',
    _ => 'read',
  };

  String encodeExpression(
    String valueName, {
    TypeSpace? typeSpace,
    List<TypeDef>? typeDefs,
  }) => switch (this) {
    PrimitiveType() ||
    IdentityType() ||
    TimestampType() ||
    TimeDurationType() ||
    ByteArrayType() => 'encoder.$encoderMethod($valueName)',
    ScheduleAtType() => '$valueName.encodeBsatn(encoder)',
    ArrayType(element: final inner) => () {
      final innerDart = inner.toDartTypeName(
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      final innerExpr = inner.encodeExpression(
        'item',
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      return 'encoder.writeArray<$innerDart>($valueName, (item) => $innerExpr)';
    }(),
    OptionType(element: final inner) => () {
      final innerDart = inner.toDartTypeName(
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      final innerExpr = inner.encodeExpression(
        'value',
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      return 'encoder.writeOption<$innerDart>($valueName, (value) => $innerExpr)';
    }(),
    RefType() => '$valueName.encodeBsatn(encoder)',
    IrProductType() =>
      throw StateError(
        'codegen: unhandled IrProductType in encodeExpression for \$$valueName '
        '(inline product types are not supported; use a RefType)',
      ),
    IrSumType() =>
      throw StateError(
        'codegen: unhandled IrSumType in encodeExpression for \$$valueName '
        '(inline sum types are not supported; use a RefType)',
      ),
  };

  String decodeExpression({TypeSpace? typeSpace, List<TypeDef>? typeDefs}) =>
      switch (this) {
        PrimitiveType() ||
        IdentityType() ||
        TimestampType() ||
        TimeDurationType() ||
        ByteArrayType() => 'decoder.$decoderMethod()',
        ScheduleAtType() => 'ScheduleAt.decodeBsatn(decoder)',
        ArrayType(element: final inner) => () {
          final innerDart = inner.toDartTypeName(
            typeSpace: typeSpace,
            typeDefs: typeDefs,
          );
          final innerExpr = inner.decodeExpression(
            typeSpace: typeSpace,
            typeDefs: typeDefs,
          );
          return 'decoder.readArray<$innerDart>(() => $innerExpr)';
        }(),
        OptionType(element: final inner) => () {
          final innerDart = inner.toDartTypeName(
            typeSpace: typeSpace,
            typeDefs: typeDefs,
          );
          final innerExpr = inner.decodeExpression(
            typeSpace: typeSpace,
            typeDefs: typeDefs,
          );
          return 'decoder.readOption<$innerDart>(() => $innerExpr)';
        }(),
        RefType() => () {
          final name = toDartTypeName(typeSpace: typeSpace, typeDefs: typeDefs);
          return '$name.decodeBsatn(decoder)';
        }(),
        IrProductType() =>
          throw StateError(
            'codegen: unhandled IrProductType in decodeExpression '
            '(inline product types are not supported; use a RefType)',
          ),
        IrSumType() =>
          throw StateError(
            'codegen: unhandled IrSumType in decodeExpression '
            '(inline sum types are not supported; use a RefType)',
          ),
      };

  bool get isPrimitive => switch (this) {
    PrimitiveType() => true,
    IdentityType() => true,
    TimestampType() => true,
    TimeDurationType() => true,
    ByteArrayType() => true,
    _ => false,
  };

  bool get isRef => this is RefType;

  bool get isInt => switch (this) {
    PrimitiveType(
      kind: PrimitiveKind.u8 ||
          PrimitiveKind.u16 ||
          PrimitiveKind.u32 ||
          PrimitiveKind.i8 ||
          PrimitiveKind.i16 ||
          PrimitiveKind.i32,
    ) =>
      true,
    _ => false,
  };

  bool get isInt64 => switch (this) {
    PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) => true,
    _ => false,
  };

  bool get isFloat => switch (this) {
    PrimitiveType(kind: PrimitiveKind.f32 || PrimitiveKind.f64) => true,
    _ => false,
  };

  String? refTypeName(List<TypeDef> typeDefs) => switch (this) {
    RefType(index: final i) => () {
      final typeDef = typeDefs.where((td) => td.typeRef == i).firstOrNull;
      return (typeDef != null && typeDef.name.isNotEmpty) ? typeDef.name : null;
    }(),
    _ => null,
  };

  /// Detect the canonical structural Option sum: `[some(T), none]` in that
  /// order, variant names lowercase, with `none` carrying a unit payload
  /// (empty product). Matches `SumType::as_option` in the upstream Rust
  /// crate (`crates/sats/src/sum_type.rs`).
  static AlgebraicType? _detectOptionInner(List<IrSumVariant> variants) {
    if (variants.length != 2) return null;
    final first = variants[0];
    final second = variants[1];
    if (first.name != 'some' || second.name != 'none') return null;
    if (second.type is! IrProductType) return null;
    if ((second.type as IrProductType).elements.isNotEmpty) return null;
    return first.type;
  }

  static bool _isScheduleAt(List<IrSumVariant> variants) {
    if (variants.length != 2) return false;
    final first = variants[0];
    final second = variants[1];
    if (first.name != 'Interval' || second.name != 'Time') return false;
    if (first.type is! TimeDurationType) return false;
    if (second.type is! TimestampType) return false;
    return true;
  }

  static String _resolveRefTypeName(
    int index,
    TypeSpace? typeSpace,
    List<TypeDef>? typeDefs,
  ) {
    if (typeSpace != null && typeDefs != null) {
      final typeDef = typeDefs.where((td) => td.typeRef == index).firstOrNull;
      if (typeDef != null && typeDef.name.isNotEmpty) {
        return toTypeClassName(typeDef.name);
      }
    }
    return 'dynamic';
  }
}

class PrimitiveType extends AlgebraicType {
  final PrimitiveKind kind;
  const PrimitiveType(this.kind);
}

class IdentityType extends AlgebraicType {
  const IdentityType();
}

class TimestampType extends AlgebraicType {
  const TimestampType();
}

class TimeDurationType extends AlgebraicType {
  const TimeDurationType();
}

class ScheduleAtType extends AlgebraicType {
  const ScheduleAtType();
}

class ByteArrayType extends AlgebraicType {
  const ByteArrayType();
}

class ArrayType extends AlgebraicType {
  final AlgebraicType element;
  const ArrayType(this.element);
}

class OptionType extends AlgebraicType {
  final AlgebraicType element;
  const OptionType(this.element);
}

class RefType extends AlgebraicType {
  final int index;
  const RefType(this.index);
}

class IrProductType extends AlgebraicType {
  final List<ProductField> elements;
  const IrProductType({required this.elements});
}

class IrSumType extends AlgebraicType {
  final List<IrSumVariant> variants;
  const IrSumType({required this.variants});
}

class ProductField {
  final String? name;
  final AlgebraicType type;

  const ProductField({required this.type, this.name});

  factory ProductField.fromJson(Map<String, dynamic> json) {
    final nameObj = json['name'];
    final fieldName = nameObj is Map ? (nameObj['some'] ?? '') : '';
    final rawType = json['algebraic_type'];
    final typeJson =
        rawType is Map<String, dynamic> ? rawType : <String, dynamic>{};

    return ProductField(
      name: fieldName is String && fieldName.isNotEmpty ? fieldName : null,
      type: AlgebraicType.fromJson(typeJson),
    );
  }
}

class IrSumVariant {
  final String? name;
  final AlgebraicType type;

  const IrSumVariant({required this.type, this.name});

  factory IrSumVariant.fromJson(Map<String, dynamic> json) {
    final nameObj = json['name'];
    final variantName = nameObj is Map ? (nameObj['some'] ?? '') : '';
    final rawAlgebraicType = json['algebraic_type'];
    final algebraicTypeJson =
        rawAlgebraicType is Map<String, dynamic>
            ? rawAlgebraicType
            : <String, dynamic>{};

    return IrSumVariant(
      name:
          variantName is String && variantName.isNotEmpty ? variantName : null,
      type: AlgebraicType.fromJson(algebraicTypeJson),
    );
  }
}
