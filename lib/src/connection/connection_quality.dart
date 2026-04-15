import 'package:spacetimedb_sdk/src/connection/connection_state.dart';

class ConnectionQuality {
  final ConnectionState status;
  final int reconnectAttempts;
  final Duration? timeSinceLastConnection;
  final Duration? averageLatency;
  final String? lastError;
  final DateTime? lastPingSent;
  final DateTime? lastPongReceived;

  ConnectionQuality({
    required this.status,
    this.reconnectAttempts = 0,
    this.timeSinceLastConnection,
    this.averageLatency,
    this.lastError,
    this.lastPingSent,
    this.lastPongReceived,
  });

  double get healthScore {
    if (status is Connected) {
      if (lastPongReceived != null) {
        final timeSincePong = DateTime.now().difference(lastPongReceived!);
        if (timeSincePong.inSeconds > 60) return 0.5;
      }
      return 1.0;
    }
    if (status is Reconnecting) {
      return 0.3;
    }
    return 0.0;
  }

  String get qualityDescription {
    if (healthScore >= 0.8) return 'Excellent';
    if (healthScore >= 0.5) return 'Good';
    if (healthScore >= 0.3) return 'Poor';
    return 'Disconnected';
  }

  @override
  String toString() {
    return 'ConnectionQuality(status: $status, quality: $qualityDescription, '
        'reconnectAttempts: $reconnectAttempts, healthScore: ${healthScore.toStringAsFixed(2)})';
  }
}
