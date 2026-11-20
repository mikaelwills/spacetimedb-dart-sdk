import 'package:spacetimedb_sdk/src/codegen/models.dart';

Set<String> refImportFiles(
  Iterable<AlgebraicType> types, {
  required String ownFileName,
  required List<TypeDef> typeDefs,
  required List<TableSchema> tables,
}) {
  return types
      .map((type) => type.refImportFile(typeDefs, tables))
      .whereType<String>()
      .toSet()
    ..remove(ownFileName);
}
