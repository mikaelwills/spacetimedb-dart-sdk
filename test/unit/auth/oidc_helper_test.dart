import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

void main() {
  group('OidcHelper', () {
    test('getAuthUrl generates correct URL', () {
      final helper = OidcHelper(
        host: 'api.game.com',
        database: 'mygame',
        ssl: true,
      );

      final url = helper.getAuthUrl('google');
      expect(url, 'https://api.game.com/database/auth/google?init');
    });

    test('getAuthUrl without SSL', () {
      final helper = OidcHelper(host: 'localhost:3000', database: 'dev');

      final url = helper.getAuthUrl('discord');
      expect(url, 'http://localhost:3000/database/auth/discord?init');
    });

    test('getAuthUrl with redirect URI', () {
      final helper = OidcHelper(host: 'localhost:3000', database: 'dev');

      final url = helper.getAuthUrl('discord', redirectUri: 'myapp://callback');
      expect(url, contains('redirect_uri=myapp%3A%2F%2Fcallback'));
      expect(url, contains('init'));
    });

    test('parseTokenFromCallback extracts query parameter', () {
      final helper = OidcHelper(host: 'localhost', database: 'test');

      final token = helper.parseTokenFromCallback(
        'myapp://callback?token=abc123&other=param',
      );

      expect(token, 'abc123');
    });

    test('parseTokenFromCallback extracts fragment', () {
      final helper = OidcHelper(host: 'localhost', database: 'test');

      final token = helper.parseTokenFromCallback(
        'myapp://callback#token=xyz789',
      );

      expect(token, 'xyz789');
    });

    test('parseTokenFromCallback returns null when missing', () {
      final helper = OidcHelper(host: 'localhost', database: 'test');

      final token = helper.parseTokenFromCallback('myapp://callback');

      expect(token, isNull);
    });

    test('parseTokenFromCallback handles complex query strings', () {
      final helper = OidcHelper(host: 'localhost', database: 'test');

      final token = helper.parseTokenFromCallback(
        'myapp://callback?state=xyz&token=abc123&foo=bar',
      );

      expect(token, 'abc123');
    });
  });
}
