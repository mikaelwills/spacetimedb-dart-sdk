import 'package:spacetimedb_sdk/src/auth/token_refresh.dart';
import 'package:test/test.dart';

import '../../helpers/test_jwt.dart';

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);
  final nowSeconds = epochSeconds(now);

  group('tokenNeedsRefresh', () {
    test('a missing or empty token needs refresh', () {
      expect(tokenNeedsRefresh(null, now), isTrue);
      expect(tokenNeedsRefresh('', now), isTrue);
    });

    test('an unreadable token needs refresh', () {
      expect(tokenNeedsRefresh('not-a-jwt', now), isTrue);
      expect(tokenNeedsRefresh('a.%%%.c', now), isTrue);
      expect(tokenNeedsRefresh('a.bm90LWpzb24.c', now), isTrue);
    });

    test('a token without exp needs refresh', () {
      expect(tokenNeedsRefresh(testJwt({'iat': nowSeconds}), now), isTrue);
    });

    test('a non-numeric exp counts as missing', () {
      expect(tokenNeedsRefresh(testJwt({'exp': 'soon'}), now), isTrue);
    });

    test('the margin is 5% of the lifetime when that exceeds 30 s', () {
      final token = testJwt({
        'iat': nowSeconds - 1000,
        'exp': nowSeconds + 100,
      });

      expect(tokenNeedsRefresh(token, now), isFalse);
      expect(
        tokenNeedsRefresh(token, now.add(const Duration(seconds: 44))),
        isFalse,
      );
      expect(
        tokenNeedsRefresh(token, now.add(const Duration(seconds: 45))),
        isTrue,
        reason: 'margin is 55 s, so 55 s before exp is the boundary',
      );
    });

    test('the margin is at least 30 s for a short-lived token', () {
      final token = testJwt({'iat': nowSeconds - 10, 'exp': nowSeconds + 40});

      expect(tokenNeedsRefresh(token, now), isFalse);
      expect(
        tokenNeedsRefresh(token, now.add(const Duration(seconds: 10))),
        isTrue,
      );
    });

    test('without iat the margin is 30 s', () {
      final token = testJwt({'exp': nowSeconds + 31});

      expect(tokenNeedsRefresh(token, now), isFalse);
      expect(
        tokenNeedsRefresh(token, now.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('an expired token needs refresh', () {
      final token = testJwt({'iat': nowSeconds - 3600, 'exp': nowSeconds - 1});

      expect(tokenNeedsRefresh(token, now), isTrue);
    });

    test('a long-lived token far from expiry does not need refresh', () {
      final token = testJwt({'iat': nowSeconds - 60, 'exp': nowSeconds + 3600});

      expect(tokenNeedsRefresh(token, now), isFalse);
    });
  });
}
