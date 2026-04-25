import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// IO (mobile/desktop) WebSocket implementation.
///
/// When [pingInterval] is non-null, `IOWebSocketChannel` sends WebSocket
/// protocol-level Ping frames at that cadence. If the server fails to
/// respond with a Pong within the same interval, the underlying dart:io
/// `WebSocket` closes the connection itself — the stream surfaces an
/// error, the SDK falls through to its usual reconnect path. This is
/// free (a few bytes per ping, no Dart code runs on each tick, no
/// server reducer invoked) and equivalent to the Rust SDK's
/// IDLE_TIMEOUT / WS-Ping approach.
WebSocketChannel connectWebSocket(
  Uri uri,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers, {
  Duration connectTimeout = const Duration(seconds: 10),
  Duration? pingInterval,
}) {
  return IOWebSocketChannel.connect(
    uri,
    protocols: protocols,
    headers: headers,
    connectTimeout: connectTimeout,
    pingInterval: pingInterval,
  );
}
