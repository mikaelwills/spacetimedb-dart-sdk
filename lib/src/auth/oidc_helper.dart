/// Helper for OAuth/OIDC authentication flows with SpacetimeDB.
///
/// SpacetimeDB handles authentication via HTTP, not WebSocket:
/// 1. Client requests auth URL from this helper
/// 2. Client opens browser with that URL (using url_launcher, etc.)
/// 3. User authenticates with provider (Google, Discord, etc.)
/// 4. Server redirects to callback with token
/// 5. Client extracts token and connects
///
/// Example:
/// ```dart
/// final helper = OidcHelper(
///   host: 'api.game.com',
///   database: 'mygame',
///   ssl: true,
/// );
///
/// // Get authentication URL
/// final url = helper.getAuthUrl('google');
/// // Open in browser: await launchUrl(Uri.parse(url));
///
/// // After callback, parse token
/// final token = helper.parseTokenFromCallback('myapp://callback?token=abc123');
/// if (token != null) {
///   await authStorage.saveToken(token);
///   // Reconnect with new token
/// }
/// ```
class OidcHelper {
  final String host;
  final String database;
  final bool ssl;

  OidcHelper({required this.host, required this.database, this.ssl = false});

  /// Generate the authentication URL for a given provider.
  ///
  /// Supported providers (depends on SpacetimeDB server config):
  /// - 'google'
  /// - 'discord'
  /// - 'steam'
  /// - 'github'
  /// etc.
  ///
  /// Example:
  /// ```dart
  /// final helper = OidcHelper(host: 'api.game.com', database: 'mygame', ssl: true);
  /// final url = helper.getAuthUrl('google');
  /// // Open url in browser: await launchUrl(Uri.parse(url));
  /// ```
  String getAuthUrl(String provider, {String? redirectUri}) {
    final protocol = ssl ? 'https' : 'http';
    final baseUrl = '$protocol://$host/database/auth/$provider';

    if (redirectUri != null) {
      return '$baseUrl?init&redirect_uri=${Uri.encodeComponent(redirectUri)}';
    }

    return '$baseUrl?init';
  }

  /// Parse the token from a callback URL.
  ///
  /// After successful authentication, the server redirects to a callback URL
  /// with the token as a query parameter or fragment.
  ///
  /// Example callback URLs:
  /// - `myapp://callback?token=abc123`
  /// - `myapp://callback#token=abc123`
  ///
  /// Example:
  /// ```dart
  /// final token = helper.parseTokenFromCallback('myapp://callback?token=abc123');
  /// if (token != null) {
  ///   await authStorage.saveToken(token);
  /// }
  /// ```
  String? parseTokenFromCallback(String callbackUrl) {
    final uri = Uri.parse(callbackUrl);

    // Check query parameters
    if (uri.queryParameters.containsKey('token')) {
      return uri.queryParameters['token'];
    }

    // Check fragment (for implicit flow)
    if (uri.fragment.isNotEmpty) {
      final fragmentParams = Uri.splitQueryString(uri.fragment);
      if (fragmentParams.containsKey('token')) {
        return fragmentParams['token'];
      }
    }

    return null;
  }
}
