class TableAudit {
  const TableAudit({
    required this.tableName,
    required this.queries,
    this.cachedCount = 0,
    this.serverCount = 0,
    this.leakedKeys = const [],
    this.missingKeys = const [],
    this.staleKeys = const [],
    this.retainedForOtherQueriesCount = 0,
    this.skippedReason,
  });

  final String tableName;
  final List<String> queries;
  final int cachedCount;
  final int serverCount;
  final List<Object> leakedKeys;
  final List<Object> missingKeys;
  final List<Object> staleKeys;
  final int retainedForOtherQueriesCount;
  final String? skippedReason;

  bool get wasCompared => skippedReason == null;

  bool get isMismatch =>
      leakedKeys.isNotEmpty || missingKeys.isNotEmpty || staleKeys.isNotEmpty;

  Map<String, Object?> toJson() => {
    'table': tableName,
    'queries': queries,
    'cached': cachedCount,
    'server': serverCount,
    'leaked': leakedKeys.map(_keyText).toList(),
    'missing': missingKeys.map(_keyText).toList(),
    'stale': staleKeys.map(_keyText).toList(),
    'retainedForOtherQueries': retainedForOtherQueriesCount,
    if (skippedReason != null) 'skipped': skippedReason,
  };

  static String _keyText(Object key) => '$key';
}
