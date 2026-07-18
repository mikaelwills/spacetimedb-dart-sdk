/// Type system models for SpacetimeDB schema
library;

import 'package:spacetimedb_sdk/src/codegen/ir/algebraic_type.dart';

export 'package:spacetimedb_sdk/src/codegen/ir/algebraic_type.dart';

class TypeSpace {
  final List<TypeSpaceEntry> types;

  TypeSpace({required this.types});

  factory TypeSpace.fromJson(Map<String, dynamic> json) {
    final typesJson = json['types'];

    return TypeSpace(
      types:
          typesJson is List
              ? typesJson.map((t) => TypeSpaceEntry.fromJson(t)).toList()
              : [],
    );
  }
}

class TypeSpaceEntry {
  final ProductType? product;
  final SumType? sum;

  TypeSpaceEntry({this.product, this.sum});

  bool get isProduct => product != null;
  bool get isSum => sum != null;

  factory TypeSpaceEntry.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('Product')) {
      return TypeSpaceEntry(product: ProductType.fromJson(json['Product']));
    }

    if (json.containsKey('Sum')) {
      return TypeSpaceEntry(sum: SumType.fromJson(json['Sum']));
    }

    return TypeSpaceEntry();
  }
}

class ProductType {
  final List<ProductElement> elements;
  ProductType({required this.elements});
  factory ProductType.fromJson(Map<String, dynamic> json) {
    final elementsJson = json['elements'];

    return ProductType(
      elements:
          elementsJson is List
              ? elementsJson.map((e) => ProductElement.fromJson(e)).toList()
              : [],
    );
  }
}

class ProductElement {
  final String? name;
  AlgebraicType type;

  ProductElement({required this.type, this.name});

  factory ProductElement.fromJson(Map<String, dynamic> json) {
    final nameObj = json['name'];
    final fieldName = nameObj['some'] ?? "";

    final rawType = json['algebraic_type'];
    final typeJson =
        rawType is Map<String, dynamic> ? rawType : <String, dynamic>{};

    return ProductElement(
      name: fieldName,
      type: AlgebraicType.fromJson(typeJson),
    );
  }
}

class TypeDef {
  final List<String> scope;
  final String name;
  final int typeRef;
  final bool customOrdering;

  TypeDef({
    required this.scope,
    required this.name,
    required this.typeRef,
    required this.customOrdering,
  });

  factory TypeDef.fromJson(Map<String, dynamic> json) {
    final nameJson = json['name'];
    final typeName = nameJson['name'] ?? "";
    final scopeJson = nameJson['scope'] ?? "";
    final scopeList =
        scopeJson is List
            ? scopeJson.map((s) => s.toString()).toList()
            : <String>[];

    return TypeDef(
      scope: scopeList,
      name: typeName,
      typeRef: json['ty'] ?? 0,
      customOrdering: json['custom_ordering'] ?? false,
    );
  }
}

class SumType {
  final List<SumVariant> variants;

  SumType({required this.variants});

  factory SumType.fromJson(Map<String, dynamic> json) {
    final variantsJson = json['variants'];

    return SumType(
      variants:
          variantsJson is List
              ? variantsJson.map((v) => SumVariant.fromJson(v)).toList()
              : [],
    );
  }
}

class SumVariant {
  final String? name;
  final TypeSpaceEntry algebraicType;
  final AlgebraicType parsedType;

  SumVariant({
    required this.algebraicType,
    required this.parsedType,
    this.name,
  });

  factory SumVariant.fromJson(Map<String, dynamic> json) {
    final nameObj = json['name'];
    final variantName = nameObj?['some'] ?? "";
    final rawAlgebraicType = json['algebraic_type'];
    final algebraicTypeJson =
        rawAlgebraicType is Map<String, dynamic>
            ? rawAlgebraicType
            : <String, dynamic>{};

    return SumVariant(
      name: variantName.isNotEmpty ? variantName : null,
      algebraicType: TypeSpaceEntry.fromJson(algebraicTypeJson),
      parsedType: AlgebraicType.fromJson(algebraicTypeJson),
    );
  }
}
