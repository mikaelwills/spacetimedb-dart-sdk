import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SilentWebSocketSink implements WebSocketSink {
  SilentWebSocketSink(this._inbound);

  final StreamController<dynamic> _inbound;
  final List<dynamic> sent = <dynamic>[];
  final Completer<void> _done = Completer<void>();
  int closeCalls = 0;

  @override
  void add(dynamic data) {
    sent.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closeCalls++;
    if (!_done.isCompleted) _done.complete();
    if (!_inbound.isClosed) await _inbound.close();
  }
}

class SilentWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  SilentWebSocketChannel({this.protocol = 'v2.bsatn.spacetimedb'}) {
    _sink = SilentWebSocketSink(_inbound);
  }

  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  late final SilentWebSocketSink _sink;

  @override
  final String? protocol;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  SilentWebSocketSink get sink => _sink;

  List<dynamic> get sent => _sink.sent;

  int get closeCalls => _sink.closeCalls;

  void deliver(Uint8List data) {
    if (!_inbound.isClosed) _inbound.add(data);
  }
}
