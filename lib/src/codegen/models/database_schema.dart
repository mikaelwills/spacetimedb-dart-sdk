/// Main database schema model for SpacetimeDB
library;

import 'type_models.dart';
import 'table_models.dart';
import 'reducer_models.dart';
import 'view_models.dart';

class DatabaseSchema {
  final String databaseName;
  final TypeSpace typeSpace;
  final List<TableSchema> tables;
  final List<ReducerSchema> reducers;
  final List<TypeDef> types;
  final List<ViewSchema> views;

  DatabaseSchema({
    required this.databaseName,
    required this.typeSpace,
    required this.tables,
    required this.reducers,
    required this.types,
    required this.views,
  });

  factory DatabaseSchema.fromJson(String dbName, Map<String, dynamic> json) {
    final tablesJson = json['tables'];
    final reducersJson = json['reducers'];
    final typesJson = json['types'];
    final miscExportsJson = json['misc_exports'];
    final viewsJson = json['views'];

    List<ViewSchema> views = [];
    if (viewsJson is List && viewsJson.isNotEmpty) {
      for (final item in viewsJson) {
        if (item is Map<String, dynamic>) {
          views.add(ViewSchema.fromJson(item));
        }
      }
    } else if (miscExportsJson is List) {
      for (final item in miscExportsJson) {
        if (item is Map<String, dynamic> && item.containsKey('View')) {
          views.add(ViewSchema.fromJson(item['View']));
        }
      }
    }

    return DatabaseSchema(
      databaseName: dbName,
      typeSpace: TypeSpace.fromJson(json['typespace'] ?? {}),
      tables:
          tablesJson is List
              ? tablesJson.map((t) => TableSchema.fromJson(t)).toList()
              : [],
      reducers:
          reducersJson is List
              ? reducersJson.map((r) => ReducerSchema.fromJson(r)).toList()
              : [],
      types:
          typesJson is List
              ? typesJson.map((t) => TypeDef.fromJson(t)).toList()
              : [],
      views: views,
    );
  }
}
