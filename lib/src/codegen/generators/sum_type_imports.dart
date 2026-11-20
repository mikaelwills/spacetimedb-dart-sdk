import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/ir/algebraic_type.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';

import 'ref_import_files.dart';

List<Directive> sumTypeImports({
  required SumType sumType,
  required String ownFileName,
  required List<TypeDef> typeDefs,
  required List<TableSchema> tables,
}) {
  final refFiles = refImportFiles(
    sumType.variants.expand(_payloadTypesOf),
    ownFileName: ownFileName,
    typeDefs: typeDefs,
    tables: tables,
  );
  return [
    Directive.import('package:spacetimedb_sdk/codegen.dart'),
    ...refFiles.map(Directive.import),
  ];
}

Iterable<AlgebraicType> _payloadTypesOf(SumVariant variant) {
  final product = variant.algebraicType.product;
  if (product != null) {
    return product.elements.map((element) => element.type);
  }
  return _hasPayloadType(variant) ? [variant.parsedType] : const [];
}

bool _hasPayloadType(SumVariant variant) => variant.algebraicType.sum == null;
