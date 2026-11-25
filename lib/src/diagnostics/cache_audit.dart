import 'dart:async';
import 'dart:typed_data';

import '../cache/table_cache.dart';
import '../codec/bsatn_decoder.dart';
import '../messages/server_messages.dart';
import '../subscription/subscription_manager.dart';
import 'held_query.dart';
import 'table_audit.dart';
import 'table_comparison.dart';

class CacheAudit {
  CacheAudit(this._subscriptions, {this.answerTimeout = _defaultAnswerTimeout});

  static const Duration _defaultAnswerTimeout = Duration(seconds: 10);
  static const int _firstRequestId = 200000;
  static int _nextRequestId = _firstRequestId;

  final SubscriptionManager _subscriptions;
  final Duration answerTimeout;

  Future<List<TableAudit>> auditHeldTables() async {
    final audits = <TableAudit>[];
    for (final entry in _heldQueriesByTable().entries) {
      audits.add(await _auditTable(entry.key, entry.value));
    }
    return audits;
  }

  Map<String, List<HeldQuery>> _heldQueriesByTable() {
    final byTable = <String, List<HeldQuery>>{};
    for (final sql in _subscriptions.activeSubscriptionQueries) {
      final held = HeldQuery.parse(sql);
      byTable.putIfAbsent(held.tableName ?? sql, () => []).add(held);
    }
    return byTable;
  }

  Future<TableAudit> _auditTable(String tableName, List<HeldQuery> held) async {
    final queries = [for (final query in held) query.sql];
    TableAudit skipped(String reason) => TableAudit(
      tableName: tableName,
      queries: queries,
      skippedReason: reason,
    );
    final table = _subscriptions.cache.getTableByName(tableName);
    if (table == null || !table.hasPrimaryKey) {
      return skipped(_noKeyedTableReason);
    }
    try {
      final serverRows = await _serverRowsByKey(table, queries);
      return TableComparison(table, held, serverRows).audit();
    } on _ServerRefusal catch (refusal) {
      return skipped(refusal.reason);
    } on TimeoutException {
      return skipped(_serverSilentReason);
    }
  }

  Future<Map<Object, Object>> _serverRowsByKey(
    TableCache table,
    List<String> queries,
  ) async {
    final rowsByKey = <Object, Object>{};
    for (final query in queries) {
      for (final bytes in _rowBytesOf(await _answerOf(query))) {
        final Object row = table.decoder.decode(BsatnDecoder(bytes));
        final Object? key = table.decoder.getPrimaryKey(row);
        if (key != null) rowsByKey[key] = row;
      }
    }
    return rowsByKey;
  }

  Iterable<Uint8List> _rowBytesOf(OneOffQueryResult answer) {
    final rows = answer.rows;
    if (rows == null) {
      throw _ServerRefusal(answer.error ?? _serverRefusedReason);
    }
    return [for (final tableRows in rows.tables) ...tableRows.rows.getRows()];
  }

  Future<OneOffQueryResult> _answerOf(String query) {
    final requestId = _nextRequestId++;
    final answer = _subscriptions.onOneOffQueryResult
        .firstWhere((result) => result.requestId == requestId)
        .timeout(answerTimeout);
    _subscriptions.oneOffQuery(query, requestId: requestId);
    return answer;
  }
}

class _ServerRefusal implements Exception {
  _ServerRefusal(this.reason);

  final String reason;
}

const String _noKeyedTableReason = 'no cached table with a primary key';
const String _serverSilentReason = 'the server did not answer';
const String _serverRefusedReason = 'the server refused the query';
