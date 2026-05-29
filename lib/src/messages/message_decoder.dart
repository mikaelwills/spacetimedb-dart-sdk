import 'dart:typed_data';
import '../codec/bsatn_decoder.dart';
import '../exceptions.dart';
import 'decompress.dart';
import 'server_messages.dart';

enum CompressionTag {
  none(0),
  brotli(1),
  gzip(2);

  final int value;
  const CompressionTag(this.value);

  static CompressionTag fromValue(int value) {
    return CompressionTag.values.firstWhere(
      (tag) => tag.value == value,
      orElse: () => throw ArgumentError('Unknown compression tag: $value'),
    );
  }
}

class MessageDecoder {
  static Future<ServerMessage> decode(Uint8List bytes) async {
    final messages = await decodeAll(bytes);
    if (messages.length != 1) {
      throw SpacetimeDbProtocolException(
        'MessageDecoder.decode expects exactly one server message per frame; '
        'got ${messages.length}. Use decodeAll on the v3 path.',
      );
    }
    return messages.single;
  }

  static Future<List<ServerMessage>> decodeAll(Uint8List bytes) async {
    final outer = BsatnDecoder(bytes);
    final compressionTag = CompressionTag.fromValue(outer.readU8());
    final payload = outer.readBytes(outer.remaining);

    final messageBytes = switch (compressionTag) {
      CompressionTag.none => payload,
      CompressionTag.brotli => await decompressBrotli(payload),
      CompressionTag.gzip => await decompressGzip(payload),
    };

    if (messageBytes.isEmpty) {
      throw SpacetimeDbProtocolException(
        'WebSocket frame payload is empty after decompression — expected at '
        'least one server message',
      );
    }

    final cursor = BsatnDecoder(messageBytes);
    final results = <ServerMessage>[];
    while (cursor.remaining > 0) {
      results.add(_decodeServerMessage(cursor));
    }
    return results;
  }

  static ServerMessage _decodeServerMessage(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    final messageType = ServerMessageType.fromTag(tag);

    return switch (messageType) {
      ServerMessageType.initialConnection => InitialConnectionMessage.decode(
        decoder,
      ),
      ServerMessageType.subscribeApplied => SubscribeApplied.decode(decoder),
      ServerMessageType.unsubscribeApplied => UnsubscribeApplied.decode(
        decoder,
      ),
      ServerMessageType.subscriptionError => SubscriptionErrorMessage.decode(
        decoder,
      ),
      ServerMessageType.transactionUpdate => TransactionUpdateMessage.decode(
        decoder,
      ),
      ServerMessageType.oneOffQueryResult => OneOffQueryResult.decode(decoder),
      ServerMessageType.reducerResult => ReducerResultMessage.decode(decoder),
      ServerMessageType.procedureResult => ProcedureResultMessage.decode(
        decoder,
      ),
    };
  }
}
