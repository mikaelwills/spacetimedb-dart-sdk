import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

void main() {
  group('ConnectionState Sealed Class Helpers', () {
    test('Display names are correct', () {
      expect(const Disconnected().displayName, 'Disconnected');
      expect(const Connecting().displayName, 'Connecting...');
      expect(const Connected().displayName, 'Connected');
      expect(const Reconnecting(attempt: 1).displayName, 'Reconnecting...');
      expect(const FatalError().displayName, 'Connection Failed');
      expect(const AuthError().displayName, 'Authentication Failed');
    });

    test('isConnected helper works correctly', () {
      expect(const Connected().isConnected, true);
      expect(const Connecting().isConnected, false);
      expect(const Disconnected().isConnected, false);
    });

    test('canRetry helper works correctly', () {
      expect(const Disconnected().canRetry, true);
      expect(const FatalError().canRetry, true);
      expect(const AuthError().canRetry, true);

      expect(const Connected().canRetry, false);
      expect(const Connecting().canRetry, false);
      expect(const Reconnecting(attempt: 1).canRetry, false);
    });
  });

  group('ConnectionQuality Health Score', () {
    test('Calculates scores correctly based on status and latency', () {
      final now = DateTime.now();

      final excellent = ConnectionQuality(
        status: const Connected(),
        lastPongReceived: now,
      );
      expect(excellent.healthScore, 1.0);
      expect(excellent.qualityDescription, 'Excellent');

      final poor = ConnectionQuality(status: const Reconnecting(attempt: 1));
      expect(poor.healthScore, 0.3);
      expect(poor.qualityDescription, 'Poor');

      final dead = ConnectionQuality(status: const Disconnected());
      expect(dead.healthScore, 0.0);
    });
  });

  group('ConnectionConfig Presets', () {
    test('Presets have correct values', () {
      expect(ConnectionConfig.mobile.maxReconnectAttempts, greaterThan(10));
      expect(
        ConnectionConfig.stable.pingInterval,
        greaterThan(const Duration(seconds: 30)),
      );
      expect(ConnectionConfig.development.autoReconnect, false);
    });
  });

  group('ConnectionQuality Stream', () {
    test('Emits initial value immediately upon connection creation', () async {
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'testdb',
      );

      final qualityFuture = connection.connectionQuality.first.timeout(
        const Duration(milliseconds: 100),
      );

      final quality = await qualityFuture;

      expect(quality.status, isA<Disconnected>());
      expect(quality.healthScore, 0.0);
      expect(quality.reconnectAttempts, 0);

      await connection.dispose();
    });
  });
}
