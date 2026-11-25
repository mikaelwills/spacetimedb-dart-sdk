import 'row_predicate.dart';

class HeldQuery {
  HeldQuery._(
    this.sql,
    this.tableName,
    this._predicate,
    this.unsupportedReason,
  );

  factory HeldQuery.parse(String sql) {
    final match = _selectPattern.firstMatch(sql.trim());
    if (match == null) {
      return HeldQuery._(sql, null, null, 'not a SELECT * FROM <table> query');
    }
    final tableName = match.namedGroup('quoted') ?? match.namedGroup('bare')!;
    final whereClause = match.namedGroup('where');
    if (whereClause == null) return HeldQuery._(sql, tableName, null, null);
    try {
      return HeldQuery._(sql, tableName, RowPredicate.parse(whereClause), null);
    } on UnsupportedPredicate catch (unsupported) {
      return HeldQuery._(sql, tableName, null, unsupported.reason);
    }
  }

  static final RegExp _selectPattern = RegExp(
    r'^SELECT\s+\*\s+FROM\s+(?:"(?<quoted>[^"]+)"|(?<bare>[A-Za-z_][A-Za-z0-9_]*))'
    r'(?<arguments>\s*\(.*?\))?(?:\s+WHERE\s+(?<where>.+))?$',
    caseSensitive: false,
    dotAll: true,
  );

  final String sql;
  final String? tableName;
  final RowPredicate? _predicate;
  final String? unsupportedReason;

  bool get canTestRows => unsupportedReason == null;

  bool matches(Map<String, dynamic> rowJson) {
    final predicate = _predicate;
    return predicate == null || predicate.matches(rowJson);
  }
}
