import 'package:flutter_test/flutter_test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';

void main() {
  group('SpacetimeDbConnection.clearToken', () {
    test('drops a token supplied at construction', () {
      final connection = SpacetimeDbConnection(
        host: '127.0.0.1:3000',
        database: 'test',
        initialToken: 'stale-token-from-a-wiped-database',
      );

      expect(connection.token, 'stale-token-from-a-wiped-database');

      connection.clearToken();

      expect(
        connection.token,
        isNull,
        reason:
            'a rejected token must be removable without discarding the whole '
            'connection, otherwise a 401 retry re-sends the token the server '
            'just rejected',
      );
    });

    test('drops a token supplied by updateToken', () {
      final connection = SpacetimeDbConnection(
        host: '127.0.0.1:3000',
        database: 'test',
      );

      connection.updateToken('issued-later');
      expect(connection.token, 'issued-later');

      connection.clearToken();

      expect(connection.token, isNull);
    });

    test('is idempotent on a connection that never had a token', () {
      final connection = SpacetimeDbConnection(
        host: '127.0.0.1:3000',
        database: 'test',
      );

      connection.clearToken();
      connection.clearToken();

      expect(connection.token, isNull);
    });
  });
}
