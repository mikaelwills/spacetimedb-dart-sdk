import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// HTML (web) WebSocket implementation.
///
/// [pingInterval] is accepted for API symmetry with the IO
/// implementation but ignored — browsers don't expose WebSocket
/// Ping/Pong to JS, so there's no way to wire a WS-level keepalive on
/// web. App-layer `KeepAliveMonitor` covers the gap.
WebSocketChannel connectWebSocket(
  Uri uri,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers, {
  Duration connectTimeout = const Duration(seconds: 10),
  Duration? pingInterval,
}) {
  // Note: HtmlWebSocketChannel doesn't support custom headers, timeouts,
  // or WS ping/pong.
  return HtmlWebSocketChannel.connect(uri, protocols: protocols);
}
