import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// HTML (web) WebSocket implementation
WebSocketChannel connectWebSocket(
  Uri uri,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers, {
  Duration connectTimeout = const Duration(seconds: 10),
}) {
  // Note: HtmlWebSocketChannel doesn't support custom headers or timeout
  // Authentication must be done via query parameters or after connection
  return HtmlWebSocketChannel.connect(uri, protocols: protocols);
}
