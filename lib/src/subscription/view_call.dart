import 'package:spacetimedb_sdk/src/cache/table_cache.dart';
import 'package:spacetimedb_sdk/src/subscription/sql_literal.dart';
import 'package:spacetimedb_sdk/src/subscription/subscription_manager.dart';

final _identifierPattern = RegExp(r'^\w+$');

String viewCallSql(String viewName, List<Object?> arguments) =>
    'SELECT * FROM "$viewName"(${arguments.map(sqlLiteral).join(', ')})';

class ViewCall<T> {
  final String viewName;
  final List<Object?> arguments;
  final SubscriptionManager subscriptions;

  ViewCall({
    required this.viewName,
    required this.arguments,
    required this.subscriptions,
  }) {
    if (!_identifierPattern.hasMatch(viewName)) {
      throw ArgumentError.value(viewName, 'viewName', 'Not a valid identifier');
    }
  }

  String get sql => viewCallSql(viewName, arguments);

  TableCache<T> get table =>
      subscriptions.cache.getTableByTypedName<T>(viewName);

  Future<int> subscribe() => subscriptions.subscribe([sql]);
}
