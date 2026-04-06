import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';

enum ViewReturnType { array, option, single, query, unknown }

const kQueryViewReturnTag = '__query__';

class ViewGenerator {
  final DatabaseSchema schema;

  ViewGenerator(this.schema);

  ViewReturnType getViewReturnPattern(ViewSchema view) => switch (view
      .returnType) {
    ArrayType() => ViewReturnType.array,
    IrSumType(variants: final variants)
        when variants.any((v) => v.name == 'none') =>
      ViewReturnType.option,
    IrProductType(elements: [ProductField(name: kQueryViewReturnTag)]) =>
      ViewReturnType.query,
    RefType() => ViewReturnType.single,
    _ => ViewReturnType.unknown,
  };

  String? getViewRowType(ViewSchema view) {
    final pattern = getViewReturnPattern(view);
    final rt = view.returnType;
    if (rt == null) return null;

    return switch (pattern) {
      ViewReturnType.array => _rowTypeFromAlgebraic(
        rt is ArrayType ? rt.element : null,
      ),
      ViewReturnType.option => _rowTypeFromOption(rt),
      ViewReturnType.query => _rowTypeFromQuery(rt),
      ViewReturnType.single => _rowTypeFromAlgebraic(rt),
      ViewReturnType.unknown => null,
    };
  }

  int? getViewTypeRef(ViewSchema view) {
    final pattern = getViewReturnPattern(view);
    final rt = view.returnType;
    if (rt == null) return null;

    return switch (pattern) {
      ViewReturnType.array =>
        rt is ArrayType && rt.element is RefType
            ? (rt.element as RefType).index
            : null,
      ViewReturnType.option => _refFromOption(rt),
      ViewReturnType.query => _refFromQuery(rt),
      ViewReturnType.single => rt is RefType ? rt.index : null,
      ViewReturnType.unknown => null,
    };
  }

  String? _rowTypeFromAlgebraic(AlgebraicType? type) {
    if (type is! RefType) return null;
    final entry = schema.typeSpace.types[type.index];
    if (entry.product == null) return null;
    for (final table in schema.tables) {
      if (table.productTypeRef == type.index) {
        return _toPascalCase(table.name);
      }
    }
    return 'Type${type.index}';
  }

  String? _rowTypeFromOption(AlgebraicType rt) {
    if (rt is! IrSumType) return null;
    for (final variant in rt.variants) {
      if (variant.name == 'some') {
        return _rowTypeFromAlgebraic(variant.type);
      }
    }
    return null;
  }

  String? _rowTypeFromQuery(AlgebraicType rt) {
    if (rt is! IrProductType || rt.elements.isEmpty) return null;
    return _rowTypeFromAlgebraic(rt.elements[0].type);
  }

  int? _refFromOption(AlgebraicType rt) {
    if (rt is! IrSumType) return null;
    for (final variant in rt.variants) {
      if (variant.name == 'some' && variant.type is RefType) {
        return (variant.type as RefType).index;
      }
    }
    return null;
  }

  int? _refFromQuery(AlgebraicType rt) {
    if (rt is! IrProductType || rt.elements.isEmpty) return null;
    final inner = rt.elements[0].type;
    return inner is RefType ? inner.index : null;
  }

  String _toPascalCase(String input) {
    return input
        .split('_')
        .map((word) {
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join('');
  }
}
