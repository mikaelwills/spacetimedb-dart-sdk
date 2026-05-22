enum OutboundBatchingPolicy { opportunistic, disabled }

class ConnectionConfig {
  final int maxReconnectAttempts;
  final Duration baseReconnectDelay;
  final Duration maxReconnectDelay;
  final Duration pingInterval;
  final Duration pongTimeout;
  final bool autoReconnect;
  final Duration connectTimeout;

  /// Outbound batching policy on the v3 WebSocket transport.
  ///
  /// Ignored when the negotiated protocol is v2. On v3, [opportunistic]
  /// coalesces same-microtask `send` calls into one frame (capped at
  /// [maxV3OutboundFrameBytes]); [disabled] forces one frame per call.
  final OutboundBatchingPolicy outboundBatching;

  /// Maximum bytes per v3 outbound frame. A queue exceeding this is split
  /// across multiple frames; a single oversized message still ships solo.
  /// Matches the TypeScript SDK's 256 KiB cap.
  final int maxV3OutboundFrameBytes;

  const ConnectionConfig({
    this.maxReconnectAttempts = 10,
    this.baseReconnectDelay = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 30),
    this.pingInterval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.autoReconnect = true,
    this.connectTimeout = const Duration(seconds: 10),
    this.outboundBatching = OutboundBatchingPolicy.opportunistic,
    this.maxV3OutboundFrameBytes = 256 * 1024,
  });

  static const mobile = ConnectionConfig(
    maxReconnectAttempts: 20,
    baseReconnectDelay: Duration(milliseconds: 500),
    maxReconnectDelay: Duration(seconds: 15),
    pingInterval: Duration(seconds: 15),
    pongTimeout: Duration(seconds: 5),
    connectTimeout: Duration(seconds: 15),
  );

  static const stable = ConnectionConfig(
    maxReconnectAttempts: 5,
    baseReconnectDelay: Duration(seconds: 2),
    maxReconnectDelay: Duration(minutes: 1),
    pingInterval: Duration(minutes: 1),
    pongTimeout: Duration(seconds: 15),
    connectTimeout: Duration(seconds: 10),
  );

  static const development = ConnectionConfig(
    maxReconnectAttempts: 0,
    autoReconnect: false,
    pingInterval: Duration(seconds: 30),
    pongTimeout: Duration(seconds: 10),
    connectTimeout: Duration(seconds: 10),
  );

  @override
  String toString() {
    return 'ConnectionConfig(maxReconnectAttempts: $maxReconnectAttempts, '
        'baseReconnectDelay: $baseReconnectDelay, '
        'maxReconnectDelay: $maxReconnectDelay, '
        'pingInterval: $pingInterval, '
        'pongTimeout: $pongTimeout, '
        'autoReconnect: $autoReconnect, '
        'connectTimeout: $connectTimeout, '
        'outboundBatching: $outboundBatching, '
        'maxV3OutboundFrameBytes: $maxV3OutboundFrameBytes)';
  }
}
