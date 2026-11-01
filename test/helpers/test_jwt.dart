import 'dart:convert';

String _segment(Map<String, Object?> json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

String testJwt(Map<String, Object?> claims) =>
    '${_segment({'alg': 'none', 'typ': 'JWT'})}.${_segment(claims)}.sig';

int epochSeconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

String testJwtExpiring(
  DateTime now, {
  required Duration age,
  required Duration remaining,
}) => testJwt({
  'iat': epochSeconds(now.subtract(age)),
  'exp': epochSeconds(now.add(remaining)),
});
