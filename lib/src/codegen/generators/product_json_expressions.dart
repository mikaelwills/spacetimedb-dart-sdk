import 'package:spacetimedb_sdk/src/codegen/models.dart';

class ProductJsonExpressions {
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;
  final List<TableSchema> tables;

  ProductJsonExpressions({
    required this.typeSpace,
    required this.typeDefs,
    required this.tables,
  });

  String toJsonValue(String fieldName, AlgebraicType type) => switch (type) {
    IdentityType() => '$fieldName.toJson()',
    ConnectionIdType() => '$fieldName.toJson()',
    UuidType() => '$fieldName.toJson()',
    TimestampType() => '$fieldName.toInt()',
    TimeDurationType() => '$fieldName.toInt()',
    ScheduleAtType() => '$fieldName.toJson()',
    PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
      '$fieldName.toInt()',
    RefType() => '$fieldName.toJson()',
    ArrayType(element: final inner) => _arrayToJsonValue(fieldName, inner),
    OptionType(element: final inner) => _optionToJsonValue(fieldName, inner),
    _ => fieldName,
  };

  String fromJsonValue(String jsonKey, AlgebraicType type) {
    final dartType = _dartTypeOf(type);

    return switch (type) {
      IdentityType() => "Identity.fromJson(json['$jsonKey'] ?? '')",
      ConnectionIdType() => "ConnectionId.fromJson(json['$jsonKey'] as String)",
      UuidType() => "Uuid.fromJson(json['$jsonKey'] as String)",
      TimestampType() => "Int64(json['$jsonKey'] ?? 0)",
      TimeDurationType() => "Int64(json['$jsonKey'] ?? 0)",
      ScheduleAtType() =>
        "ScheduleAt.fromJson(Map<String, dynamic>.from(json['$jsonKey'] ?? {}))",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "Int64(json['$jsonKey'] ?? 0)",
      RefType() =>
        "$dartType.fromJson(Map<String, dynamic>.from(json['$jsonKey'] ?? {}))",
      ArrayType(element: final inner) => _arrayFromJsonValue(jsonKey, inner),
      OptionType(element: final inner) => _optionFromJsonValue(jsonKey, inner),
      PrimitiveType(kind: PrimitiveKind.string) => "json['$jsonKey'] ?? ''",
      PrimitiveType(kind: PrimitiveKind.bool_) => "json['$jsonKey'] ?? false",
      PrimitiveType(kind: PrimitiveKind.f32 || PrimitiveKind.f64) =>
        "(json['$jsonKey'] ?? 0.0).toDouble()",
      PrimitiveType() when type.isInt => "json['$jsonKey'] ?? 0",
      _ => "json['$jsonKey']",
    };
  }

  String _optionToJsonValue(String fieldName, AlgebraicType inner) =>
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

  String _arrayToJsonValue(String fieldName, AlgebraicType inner) =>
      switch (inner) {
        RefType() => '$fieldName.map((e) => e.toJson()).toList()',
        PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
          '$fieldName.map((e) => e.toInt()).toList()',
        _ => fieldName,
      };

  String _optionFromJsonValue(String jsonKey, AlgebraicType inner) {
    final innerDartType = _dartTypeOf(inner);

    return switch (inner) {
      IdentityType() =>
        "json['$jsonKey'] == null ? null : Identity.fromJson(json['$jsonKey'])",
      ConnectionIdType() =>
        "json['$jsonKey'] == null ? null : ConnectionId.fromJson(json['$jsonKey'] as String)",
      UuidType() =>
        "json['$jsonKey'] == null ? null : Uuid.fromJson(json['$jsonKey'] as String)",
      TimestampType() =>
        "json['$jsonKey'] == null ? null : Int64(json['$jsonKey'])",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "json['$jsonKey'] == null ? null : Int64(json['$jsonKey'])",
      RefType() =>
        "json['$jsonKey'] == null ? null : $innerDartType.fromJson(Map<String, dynamic>.from(json['$jsonKey']))",
      _ => "json['$jsonKey']",
    };
  }

  String _arrayFromJsonValue(String jsonKey, AlgebraicType inner) {
    final innerDartType = _dartTypeOf(inner);

    return switch (inner) {
      RefType() =>
        "(json['$jsonKey'] ?? []).cast<Map<String, dynamic>>().map((e) => $innerDartType.fromJson(e)).toList()",
      PrimitiveType(kind: PrimitiveKind.u64 || PrimitiveKind.i64) =>
        "(json['$jsonKey'] ?? []).cast<int>().map((e) => Int64(e)).toList()",
      _ => "List<$innerDartType>.from(json['$jsonKey'] ?? [])",
    };
  }

  String _dartTypeOf(AlgebraicType type) => type.toDartTypeName(
    typeSpace: typeSpace,
    typeDefs: typeDefs,
    tables: tables,
  );
}
