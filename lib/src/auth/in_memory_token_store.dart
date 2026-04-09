import 'auth_token_store.dart';

/// Default in-memory token storage.
///
/// Tokens are NOT persisted across app restarts.
/// Use this for:
/// - Testing
/// - CLI tools that don't need persistence
/// - Temporary anonymous sessions
///
/// For production Flutter apps, implement [AuthTokenStore] with
/// SharedPreferences or FlutterSecureStorage.
///
/// Example:
/// ```dart
/// final client = await SpacetimeDbClient.create(
///   host: 'localhost:3000',
///   database: 'mygame',
///   authStorage: InMemoryTokenStore(), // Not persistent!
/// );
/// ```
class InMemoryTokenStore implements AuthTokenStore {
  String? _token;

  @override
  Future<String?> loadToken() async => _token;

  @override
  Future<void> saveToken(String token) async {
    _token = token;
  }

  @override
  Future<void> clearToken() async {
    _token = null;
  }
}
