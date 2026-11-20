import 'package:spacetimedb_sdk/src/codegen/ir/ref_type_name.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';

enum ViewReturnType { array, option, single, query, unknown }

const kQueryViewReturnTag = '__query__';
const kFallbackTypeNamePrefix = 'Type';

typedef ViewRowName = ({String className, String? fileName});

class ViewGenerator {
  final DatabaseSchema schema;

  ViewGenerator(this.schema);

  ViewReturnType getViewReturnPattern(ViewSchema view) =>
      switch (view.returnType) {
        ArrayType() => ViewReturnType.array,
        OptionType() => ViewReturnType.option,
        IrSumType(variants: final variants)
            when variants.any((v) => v.name == 'none') =>
          ViewReturnType.option,
        IrProductType(elements: [ProductField(name: kQueryViewReturnTag)]) =>
          ViewReturnType.query,
        RefType() => ViewReturnType.single,
        _ => ViewReturnType.unknown,
      };

  String? getViewRowType(ViewSchema view) => _viewRowName(view)?.className;

  String? getViewRowFileName(ViewSchema view) => _viewRowName(view)?.fileName;

  Set<String> getViewRowFileNames() =>
      schema.views.map(getViewRowFileName).whereType<String>().toSet();

  ViewRowName? _viewRowName(ViewSchema view) {
    final pattern = getViewReturnPattern(view);
    final rt = view.returnType;
    if (rt == null) return null;

    return switch (pattern) {
      .array => _rowNameFromArray(rt),
      .option => _rowNameFromOption(rt),
      .query => _rowNameFromQuery(rt),
      .single => _rowNameFromAlgebraic(rt),
      .unknown => null,
    };
  }

  int? getViewTypeRef(ViewSchema view) {
    final pattern = getViewReturnPattern(view);
    final rt = view.returnType;
    if (rt == null) return null;

    return switch (pattern) {
      .array =>
        rt is ArrayType && rt.element is RefType
            ? (rt.element as RefType).index
            : null,
      .option => _refFromOption(rt),
      .query => _refFromQuery(rt),
      .single => rt is RefType ? rt.index : null,
      .unknown => null,
    };
  }

  ViewRowName? _rowNameFromAlgebraic(AlgebraicType? type) {
    if (type is! RefType) return null;
    final entry = schema.typeSpace.types[type.index];
    if (entry.product == null) return null;
    final resolved = resolveRefTypeName(
      type.index,
      schema.types,
      schema.tables,
    );
    if (resolved == null) {
      return (
        className: '$kFallbackTypeNamePrefix${type.index}',
        fileName: null,
      );
    }
    return (className: resolved.className, fileName: resolved.fileName);
  }

  ViewRowName? _rowNameFromArray(AlgebraicType rt) =>
      _rowNameFromAlgebraic(rt is ArrayType ? rt.element : null);

  ViewRowName? _rowNameFromOption(AlgebraicType rt) {
    if (rt is OptionType) {
      return _rowNameFromAlgebraic(rt.element);
    }
    if (rt is! IrSumType) return null;
    for (final variant in rt.variants) {
      if (variant.name == 'some') {
        return _rowNameFromAlgebraic(variant.type);
      }
    }
    return null;
  }

  ViewRowName? _rowNameFromQuery(AlgebraicType rt) {
    if (rt is! IrProductType || rt.elements.isEmpty) return null;
    return _rowNameFromAlgebraic(rt.elements[0].type);
  }

  int? _refFromOption(AlgebraicType rt) {
    if (rt is OptionType) {
      final inner = rt.element;
      return inner is RefType ? inner.index : null;
    }
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
}
