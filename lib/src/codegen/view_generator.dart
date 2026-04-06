import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';

/// View return type pattern
enum ViewReturnType { array, option, single, query, unknown }

const kQueryViewReturnTag = '__query__';

/// Helper class to analyze views and determine their row types
class ViewGenerator {
  final DatabaseSchema schema;

  ViewGenerator(this.schema);

  /// Detects the return type pattern of a view
  ViewReturnType getViewReturnPattern(ViewSchema view) {
    final returnType = view.returnType;

    // Array pattern: {"Array": {"Ref": N}}
    if (returnType.containsKey('Array')) {
      return ViewReturnType.array;
    }

    // Option pattern: {"Sum": {"variants": [{"name": {"some": "some"}, ...}, {"name": {"some": "none"}, ...}]}}
    if (returnType.containsKey('Sum')) {
      final sum = returnType['Sum'];
      if (sum is! Map<String, dynamic>) return ViewReturnType.unknown;
      if (!sum.containsKey('variants')) return ViewReturnType.unknown;

      final variantsValue = sum['variants'];
      if (variantsValue is! List) return ViewReturnType.unknown;

      final variants = variantsValue;
      if (variants.length == 2) {
        // Check if this is the Option pattern (some/none variants)
        final hasNone = variants.any((v) {
          final name = v['name'];
          return name is Map && name['some'] == 'none';
        });
        if (hasNone) {
          return ViewReturnType.option;
        }
      }
    }

    if (_isQueryProduct(returnType)) {
      return ViewReturnType.query;
    }

    // Direct type reference: {"Ref": N}
    if (returnType.containsKey('Ref')) {
      return ViewReturnType.single;
    }

    return ViewReturnType.unknown;
  }

  /// Determines the row type for a view based on its return type
  /// Returns null if the view doesn't return a table row type
  String? getViewRowType(ViewSchema view) {
    final returnType = view.returnType;
    final pattern = getViewReturnPattern(view);

    switch (pattern) {
      case ViewReturnType.array:
        // Array pattern: {"Array": {"Ref": N}}
        final innerType = returnType['Array'];
        return _determineRowType(innerType);

      case ViewReturnType.option:
        // Option pattern - find the 'some' variant
        final sum = returnType['Sum'];
        if (sum is! Map<String, dynamic>) return null;

        final variantsValue = sum['variants'];
        if (variantsValue is! List) return null;

        for (final variant in variantsValue) {
          final name = variant['name'];
          if (name is Map && name['some'] == 'some') {
            return _determineRowType(variant['algebraic_type']);
          }
        }
        return null;

      case ViewReturnType.query:
        return _determineRowType(_queryProductInnerType(returnType));

      case ViewReturnType.single:
        return _determineRowType(returnType);

      case ViewReturnType.unknown:
        return null;
    }
  }

  /// Gets the type reference from the view's return type
  /// Returns null if not a type reference
  int? getViewTypeRef(ViewSchema view) {
    final returnType = view.returnType;
    final pattern = getViewReturnPattern(view);

    switch (pattern) {
      case ViewReturnType.array:
        // Array pattern: {"Array": {"Ref": N}}
        final innerType = returnType['Array'];
        if (innerType is! Map<String, dynamic>) return null;
        if (!innerType.containsKey('Ref')) return null;

        final refValue = innerType['Ref'];
        if (refValue is! int) return null;

        return refValue;

      case ViewReturnType.option:
        // Option pattern - find the 'some' variant
        final sum = returnType['Sum'];
        if (sum is! Map<String, dynamic>) return null;

        final variantsValue = sum['variants'];
        if (variantsValue is! List) return null;

        for (final variant in variantsValue) {
          final name = variant['name'];
          if (name is Map && name['some'] == 'some') {
            final algebraicType = variant['algebraic_type'];
            if (algebraicType is! Map<String, dynamic>) continue;
            if (!algebraicType.containsKey('Ref')) continue;

            final refValue = algebraicType['Ref'];
            if (refValue is! int) continue;

            return refValue;
          }
        }
        return null;

      case ViewReturnType.query:
        final inner = _queryProductInnerType(returnType);
        if (inner == null) return null;
        final refValue = inner['Ref'];
        return refValue is int ? refValue : null;

      case ViewReturnType.single:
        if (!returnType.containsKey('Ref')) return null;

        final refValue = returnType['Ref'];
        if (refValue is! int) return null;

        return refValue;

      case ViewReturnType.unknown:
        return null;
    }
  }

  String? _determineRowType(dynamic typeInfo) {
    if (typeInfo is! Map<String, dynamic>) return null;

    // Check if it's a type reference
    if (typeInfo.containsKey('Ref')) {
      final typeRefValue = typeInfo['Ref'];
      if (typeRefValue is! int) return null;
      final typeRef = typeRefValue;
      // Look up the type in the type space
      final algebraicType = schema.typeSpace.types[typeRef];
      if (algebraicType.product != null) {
        // This is a table type - find which table uses this type
        for (final table in schema.tables) {
          if (table.productTypeRef == typeRef) {
            return _toPascalCase(table.name);
          }
        }
        // If no table found, use generic name
        return 'Type$typeRef';
      }
    }

    return null;
  }

  bool _isQueryProduct(Map<String, dynamic> returnType) {
    final product = returnType['Product'];
    if (product is! Map<String, dynamic>) return false;
    final elements = product['elements'];
    if (elements is! List || elements.length != 1) return false;
    final element = elements[0];
    if (element is! Map<String, dynamic>) return false;
    final name = element['name'];
    return name is Map && name['some'] == kQueryViewReturnTag;
  }

  Map<String, dynamic>? _queryProductInnerType(
    Map<String, dynamic> returnType,
  ) {
    final product = returnType['Product'];
    if (product is! Map<String, dynamic>) return null;
    final elements = product['elements'];
    if (elements is! List || elements.isEmpty) return null;
    final element = elements[0];
    if (element is! Map<String, dynamic>) return null;
    final inner = element['algebraic_type'];
    return inner is Map<String, dynamic> ? inner : null;
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
