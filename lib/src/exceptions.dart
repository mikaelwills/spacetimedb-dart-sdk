import 'package:spacetimedb_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_sdk/src/reducers/transaction_result.dart';

sealed class SpacetimeDbException implements Exception {
  final String message;

  const SpacetimeDbException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

class SpacetimeDbReducerException extends SpacetimeDbException {
  final String reducerName;
  final TransactionResult result;

  SpacetimeDbReducerException({
    required this.reducerName,
    required String message,
    required this.result,
  }) : super(message);

  @override
  String toString() => 'SpacetimeDbReducerException($reducerName): $message';
}

class SpacetimeDbConnectionException extends SpacetimeDbException {
  final ConnectionState? lastKnownState;

  SpacetimeDbConnectionException(super.message, {this.lastKnownState});
}

class SpacetimeDbAuthException extends SpacetimeDbConnectionException {
  SpacetimeDbAuthException(super.message);
}

class SpacetimeDbTimeoutException extends SpacetimeDbException {
  final Duration elapsed;

  SpacetimeDbTimeoutException(super.message, {required this.elapsed});
}

class SpacetimeDbSchemaException extends SpacetimeDbException {
  SpacetimeDbSchemaException(super.message);
}

class SpacetimeDbQueueFullException extends SpacetimeDbException {
  final int queueLength;

  SpacetimeDbQueueFullException(super.message, {required this.queueLength});
}

class SpacetimeDbProtocolException extends SpacetimeDbException {
  SpacetimeDbProtocolException(super.message);
}

class SpacetimeDbSubscriptionException extends SpacetimeDbException {
  final String? tableName;

  SpacetimeDbSubscriptionException(super.message, {this.tableName});

  @override
  String toString() {
    final suffix = tableName != null ? ' (table: $tableName)' : '';
    return 'SpacetimeDbSubscriptionException$suffix: $message';
  }
}
