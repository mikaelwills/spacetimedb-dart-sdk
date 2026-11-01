import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class CloseCodeWebSocketSink implements WebSocketSink {
  CloseCodeWebSocketSink(this._closeInbound);

  final Future<void> Function() _closeInbound;
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
    await _closeInbound();
  }
}

class CloseCodeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  CloseCodeWebSocketChannel({
    required this._closeCode,
    this._closeReason,
    List<Uint8List> frames = const [],
    bool closeAfterFrames = true,
    Future<void>? ready,
    this.protocol = 'v2.bsatn.spacetimedb',
  }) : _ready = ready ?? Future<void>.value() {
    _sink = CloseCodeWebSocketSink(close);
    frames.forEach(_inbound.add);
    if (closeAfterFrames) unawaited(close());
  }

  factory CloseCodeWebSocketChannel.sessionBusy({
    List<Uint8List> frames = const [],
    bool closeAfterFrames = true,
  }) => CloseCodeWebSocketChannel(
    closeCode: 4000,
    closeReason: 'session busy',
    frames: frames,
    closeAfterFrames: closeAfterFrames,
  );

  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  late final CloseCodeWebSocketSink _sink;
  final int? _closeCode;
  final String? _closeReason;
  final Future<void> _ready;
  bool _closed = false;

  @override
  final String? protocol;

  @override
  int? get closeCode => _closed ? _closeCode : null;

  @override
  String? get closeReason => _closed ? _closeReason : null;

  @override
  Future<void> get ready => _ready;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  CloseCodeWebSocketSink get sink => _sink;

  List<dynamic> get sent => _sink.sent;

  Future<void> close() async {
    _closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }
}
