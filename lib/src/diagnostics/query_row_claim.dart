import 'held_query.dart';
import 'row_predicate.dart';

typedef RowClaim = bool Function(Map<String, dynamic> rowJson);

RowClaim? tryBuildRowClaim(Iterable<String> queries, String tableName) {
  final testable = [
    for (final held in queries.map(HeldQuery.parse))
      if (held.tableName == tableName && held.canTestRows) held,
  ];
  if (testable.isEmpty) return null;
  return (rowJson) => testable.any((held) => _claims(held, rowJson));
}

bool _claims(HeldQuery held, Map<String, dynamic> rowJson) {
  try {
    return held.matches(rowJson);
  } on UnsupportedPredicate {
    return false;
  }
}
