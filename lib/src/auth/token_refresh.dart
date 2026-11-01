import 'dart:convert';
import 'dart:math' as math;

const double _refreshMarginFraction = 0.05;
const Duration _refreshMinMargin = Duration(seconds: 30);

bool tokenNeedsRefresh(String? token, DateTime now) {
  if (token == null || token.isEmpty) return true;
  final claims = _decodeClaims(token);
  if (claims == null) return true;
  final exp = _seconds(claims['exp']);
  if (exp == null) return true;
  final iat = _seconds(claims['iat']);
  final expiryMs = exp * 1000;
  final lifetimeMs = iat == null ? 0.0 : expiryMs - iat * 1000;
  final marginMs = math.max(
    _refreshMinMargin.inMilliseconds.toDouble(),
    lifetimeMs * _refreshMarginFraction,
  );
  return expiryMs - now.millisecondsSinceEpoch <= marginMs;
}

Map<String, dynamic>? _decodeClaims(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final claims = jsonDecode(payload);
    return claims is Map<String, dynamic> ? claims : null;
  } on FormatException {
    return null;
  }
}

double? _seconds(Object? claim) {
  if (claim is! num || !claim.isFinite) return null;
  return claim.toDouble();
}
