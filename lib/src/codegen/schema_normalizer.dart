import 'package:spacetimedb_sdk/src/codegen/models.dart';

class SchemaNormalizer {
  final DatabaseSchema schema;

  final Map<String, int> _companionByShape = {};
  final Set<String> _usedNames = {};

  SchemaNormalizer(this.schema);

  static void normalize(DatabaseSchema schema) {
    SchemaNormalizer(schema)._run();
  }

  void _run() {
    for (final def in schema.types) {
      if (def.name.isNotEmpty) _usedNames.add(def.name);
    }

    final originalEntries = List<TypeSpaceEntry>.of(schema.typeSpace.types);
    for (final entry in originalEntries) {
      final product = entry.product;
      if (product == null) continue;
      for (final element in product.elements) {
        element.type = _rewrite(element.type, element.name);
      }
    }

    for (final reducer in schema.reducers) {
      for (final element in reducer.params.elements) {
        element.type = _rewrite(element.type, element.name);
      }
    }
  }

  AlgebraicType _rewrite(AlgebraicType type, String? hint) => switch (type) {
    IrSumType() => RefType(_companionFor(type, hint)),
    ArrayType(element: final inner) => ArrayType(_rewrite(inner, hint)),
    OptionType(element: final inner) => OptionType(_rewrite(inner, hint)),
    _ => type,
  };

  int _companionFor(IrSumType sum, String? hint) {
    final shape = _shapeKey(sum);
    final existing = _companionByShape[shape];
    if (existing != null) return existing;

    final typeRef = schema.typeSpace.types.length;
    schema.typeSpace.types.add(TypeSpaceEntry(sum: _toSumType(sum)));
    schema.types.add(
      TypeDef(
        scope: const [],
        name: _companionName(hint),
        typeRef: typeRef,
        customOrdering: false,
      ),
    );
    _companionByShape[shape] = typeRef;
    return typeRef;
  }

  SumType _toSumType(IrSumType sum) {
    return SumType(variants: sum.variants.map(_toSumVariant).toList());
  }

  SumVariant _toSumVariant(IrSumVariant variant) {
    final payload = variant.type;
    final TypeSpaceEntry entry;
    if (payload is IrProductType) {
      entry = TypeSpaceEntry(
        product: ProductType(
          elements:
              payload.elements
                  .map((e) => ProductElement(name: e.name, type: e.type))
                  .toList(),
        ),
      );
    } else {
      entry = TypeSpaceEntry(
        product: ProductType(elements: [ProductElement(type: payload)]),
      );
    }
    return SumVariant(
      name: variant.name,
      algebraicType: entry,
      parsedType: payload,
    );
  }

  String _shapeKey(IrSumType sum) {
    return sum.variants.map((v) => '${v.name}:${_typeKey(v.type)}').join('|');
  }

  String _typeKey(AlgebraicType type) => switch (type) {
    PrimitiveType(kind: final k) => 'p:$k',
    IdentityType() => 'identity',
    ConnectionIdType() => 'connectionid',
    UuidType() => 'uuid',
    TimestampType() => 'timestamp',
    TimeDurationType() => 'timeduration',
    ScheduleAtType() => 'scheduleat',
    ByteArrayType() => 'bytes',
    RefType(index: final i) => 'ref:$i',
    OptionType(element: final e) => 'opt(${_typeKey(e)})',
    ArrayType(element: final e) => 'arr(${_typeKey(e)})',
    IrProductType(elements: final els) =>
      'prod(${els.map((e) => '${e.name}=${_typeKey(e.type)}').join(',')})',
    IrSumType(variants: final vs) =>
      'sum(${vs.map((v) => '${v.name}=${_typeKey(v.type)}').join(',')})',
  };

  String _companionName(String? hint) {
    final base =
        (hint != null && hint.isNotEmpty) ? _pascal(hint) : 'InlineSum';
    var name = base;
    var suffix = 2;
    while (_usedNames.contains(name)) {
      name = '$base$suffix';
      suffix++;
    }
    _usedNames.add(name);
    return name;
  }

  String _pascal(String input) {
    if (input.isEmpty) return input;
    final cleaned = input.replaceAll(r'$', '');
    if (cleaned.isEmpty) return 'InlineSum';
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }
}
