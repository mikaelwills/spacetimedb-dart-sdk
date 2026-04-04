import 'dart:async';

/// Intelligent keep-alive monitor using debounced ping strategy
///
/// Only sends pings when the connection has been idle for a specified duration.
/// If messages are actively flowing, pings are suppressed to save bandwidth and battery.
///
/// ## How it works:
///
/// 1. **Traffic = Health**: Every incoming message proves the connection is alive
/// 2. **Debouncing**: Each message resets the idle timer, pushing the next ping further out
/// 3. **Idle Detection**: Only sends a ping if no traffic for the full idle threshold
/// 4. **Timeout Detection**: If no response to ping within timeout, triggers disconnect
///
/// ## Example:
///
/// - User in busy chat: 50 messages/sec → No pings sent (traffic proves health)
/// - Connection goes idle: After 30s → Single ping sent
/// - Ping times out: After additional 5s → Connection declared dead
///
/// ## Battery & Bandwidth Benefits:
///
/// - No unnecessary radio wake-ups during active use (saves battery on mobile)
/// - No bandwidth waste when data is actively flowing
/// - Still detects dead connections within idle_threshold + timeout (e.g., 35s max)
class KeepAliveMonitor {
  // Dependencies
  final void Function() _sendPingCallback;
  final void Function() _onTimeoutCallback;

  // Configuration
  final Duration _idleThreshold;
  final Duration _pongTimeout;

  // State
  Timer? _idleTimer;
  Timer? _timeoutTimer;
  bool _isAwaitingPong = false;
  bool _stopped = false;

  KeepAliveMonitor({
    required void Function() onSendPing,
    required void Function() onDisconnect,
    Duration idleThreshold = const Duration(seconds: 30),
    Duration pongTimeout = const Duration(seconds: 5),
  }) : _sendPingCallback = onSendPing,
       _onTimeoutCallback = onDisconnect,
       _idleThreshold = idleThreshold,
       _pongTimeout = pongTimeout;

  /// Call this EVERY time a message is received from the WebSocket
  ///
  /// This acts as the "debouncer" - each call resets the idle timer,
  /// pushing the next ping 30 seconds into the future.
  void notifyMessageReceived() {
    if (_stopped) return;

    if (_isAwaitingPong) {
      _isAwaitingPong = false;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    _idleTimer?.cancel();
    _idleTimer = Timer(_idleThreshold, _triggerPing);
  }

  void _triggerPing() {
    if (_stopped) return;

    _isAwaitingPong = true;
    _sendPingCallback();

    _timeoutTimer = Timer(_pongTimeout, () {
      if (_stopped) return;
      stop();
      _onTimeoutCallback();
    });
  }

  /// Stop all monitoring and clean up timers
  void stop() {
    _stopped = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _isAwaitingPong = false;
  }
}
