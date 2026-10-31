import '../codegen_emitter.dart';
import '../models/table_models.dart';
import '../models/type_models.dart';

typedef RefTypeName = ({String className, String fileName});

RefTypeName? resolveRefTypeName(
  int index,
  List<TypeDef> typeDefs,
  List<TableSchema> tables,
) {
  final structName =
      typeDefs.where((td) => td.typeRef == index).firstOrNull?.name ?? '';
  final backing = tables.where((t) => t.productTypeRef == index).toList();

  if (backing.isNotEmpty) {
    final table = _pickBackingTable(backing, structName);
    return (
      className: toPascalCase(table.name),
      fileName: '${table.name}.dart',
    );
  }

  if (structName.isEmpty) return null;
  return (
    className: toTypeClassName(structName),
    fileName: '${toSnakeCase(structName)}.dart',
  );
}

TableSchema _pickBackingTable(List<TableSchema> backing, String structName) {
  if (structName.isNotEmpty) {
    final structClass = toTypeClassName(structName);
    final match = backing
        .where((t) => toPascalCase(t.name) == structClass)
        .firstOrNull;
    if (match != null) return match;
  }
  return backing.reduce(
    (a, b) => toPascalCase(a.name).compareTo(toPascalCase(b.name)) <= 0 ? a : b,
  );
}
