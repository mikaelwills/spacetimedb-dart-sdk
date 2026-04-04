import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

void main() {
  group('ConnectionStatus Enum Helpers', () {
    test('Display names are correct', () {
      expect(ConnectionStatus.disconnected.displayName, 'Disconnected');
      expect(ConnectionStatus.connecting.displayName, 'Connecting...');
      expect(ConnectionStatus.connected.displayName, 'Connected');
      expect(ConnectionStatus.reconnecting.displayName, 'Reconnecting...');
      expect(ConnectionStatus.fatalError.displayName, 'Connection Failed');
    });

    test('isConnected helper works correctly', () {
      expect(ConnectionStatus.connected.isConnected, true);
      expect(ConnectionStatus.connecting.isConnected, false);
      expect(ConnectionStatus.disconnected.isConnected, false);
    });

    test('canRetry helper works correctly', () {
      // We can only retry if we are fully stopped
      expect(ConnectionStatus.disconnected.canRetry, true);
      expect(ConnectionStatus.fatalError.canRetry, true);

      // We cannot retry if we are currently trying
      expect(ConnectionStatus.connected.canRetry, false);
      expect(ConnectionStatus.connecting.canRetry, false);
      expect(ConnectionStatus.reconnecting.canRetry, false);
    });
  });

  group('ConnectionQuality Health Score', () {
    test('Calculates scores correctly based on status and latency', () {
      final now = DateTime.now();

      // Excellent
      final excellent = ConnectionQuality(
        status: ConnectionStatus.connected,
        lastPongReceived: now,
      );
      expect(excellent.healthScore, 1.0);
      expect(excellent.qualityDescription, 'Excellent');

      // Poor (Reconnecting)
      final poor = ConnectionQuality(status: ConnectionStatus.reconnecting);
      expect(poor.healthScore, 0.3);
      expect(poor.qualityDescription, 'Poor');

      // Dead
      final dead = ConnectionQuality(status: ConnectionStatus.disconnected);
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

      // Subscribe to quality stream
      final qualityFuture = connection.connectionQuality.first.timeout(
        const Duration(milliseconds: 100),
      );

      // Should receive initial quality value immediately (disconnected state)
      final quality = await qualityFuture;

      expect(quality.status, ConnectionStatus.disconnected);
      expect(quality.healthScore, 0.0);
      expect(quality.reconnectAttempts, 0);

      await connection.dispose();
    });
  });
}
