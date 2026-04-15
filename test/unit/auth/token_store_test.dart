import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

void main() {
  group('InMemoryTokenStore', () {
    late InMemoryTokenStore store;

    setUp(() {
      store = InMemoryTokenStore();
    });

    test('Initially returns null', () async {
      final token = await store.loadToken();
      expect(token, isNull);
    });

    test('Saves and loads token', () async {
      await store.saveToken('test-token-123');
      final loaded = await store.loadToken();
      expect(loaded, 'test-token-123');
    });

    test('Clears token', () async {
      await store.saveToken('test-token-123');
      await store.clearToken();
      final loaded = await store.loadToken();
      expect(loaded, isNull);
    });

    test('Overwrites existing token', () async {
      await store.saveToken('token-1');
      await store.saveToken('token-2');
      final loaded = await store.loadToken();
      expect(loaded, 'token-2');
    });
  });
}
