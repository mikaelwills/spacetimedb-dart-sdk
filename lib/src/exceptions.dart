import 'package:spacetimedb_dart_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_dart_sdk/src/reducers/transaction_result.dart';

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

class SpacetimeDbProtocolException extends SpacetimeDbException {
  SpacetimeDbProtocolException(super.message);
}
