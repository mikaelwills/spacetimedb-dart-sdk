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
  final Future<bool> Function()? _confirmServerAlive;

  // Configuration
  final Duration _idleThreshold;
  final Duration _pongTimeout;

  static const int maxDeferredPings = 3;
  static const int maxBusyDeferrals = 6;

  // State
  Timer? _idleTimer;
  Timer? _timeoutTimer;
  bool _isAwaitingPong = false;
  bool _stopped = false;
  bool _workInFlight = false;
  int _deferredPings = 0;
  int _busyDeferrals = 0;

  KeepAliveMonitor({
    required void Function() onSendPing,
    required void Function() onDisconnect,
    Future<bool> Function()? confirmServerAlive,
    this._idleThreshold = const Duration(seconds: 30),
    this._pongTimeout = const Duration(seconds: 5),
  }) : _sendPingCallback = onSendPing,
       _onTimeoutCallback = onDisconnect,
       _confirmServerAlive = confirmServerAlive {
    _armIdleTimer();
  }

  void setWorkInFlight(bool inFlight) {
    if (_stopped) return;
    _workInFlight = inFlight;
    if (!inFlight) _deferredPings = 0;
  }

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
    _deferredPings = 0;
    _busyDeferrals = 0;

    _armIdleTimer();
  }

  /// Stop all monitoring and clean up timers
  void stop() {
    _stopped = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _isAwaitingPong = false;
    _workInFlight = false;
    _deferredPings = 0;
    _busyDeferrals = 0;
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleThreshold, _triggerPing);
  }

  void _triggerPing() {
    if (_stopped) return;

    _isAwaitingPong = true;
    _sendPingCallback();

    _timeoutTimer = Timer(_pongTimeout, () {
      if (_stopped) return;

      if (_workInFlight && _deferredPings < maxDeferredPings) {
        _deferredPings++;
        _isAwaitingPong = false;
        _timeoutTimer = null;
        _armIdleTimer();
        return;
      }

      _timeoutTimer = null;
      final confirm = _confirmServerAlive;
      if (confirm == null || _busyDeferralsUsedUp) {
        _declareDead();
        return;
      }
      _checkServerBeforeDeclaringDead(confirm);
    });
  }

  bool get _busyDeferralsUsedUp => _busyDeferrals >= maxBusyDeferrals;

  Future<void> _checkServerBeforeDeclaringDead(
    Future<bool> Function() confirm,
  ) async {
    bool alive;
    try {
      alive = await confirm();
    } catch (_) {
      alive = false;
    }
    if (_stopped || !_isAwaitingPong) return;
    if (!alive) {
      _declareDead();
      return;
    }
    _busyDeferrals++;
    _isAwaitingPong = false;
    _armIdleTimer();
  }

  void _declareDead() {
    stop();
    _onTimeoutCallback();
  }
}
