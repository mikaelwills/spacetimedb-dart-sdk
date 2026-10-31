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
      .none => payload,
      .brotli => await decompressBrotli(payload),
      .gzip => await decompressGzip(payload),
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
      .initialConnection => InitialConnectionMessage.decode(
        decoder,
      ),
      .subscribeApplied => SubscribeApplied.decode(decoder),
      .unsubscribeApplied => UnsubscribeApplied.decode(
        decoder,
      ),
      .subscriptionError => SubscriptionErrorMessage.decode(
        decoder,
      ),
      .transactionUpdate => TransactionUpdateMessage.decode(
        decoder,
      ),
      .oneOffQueryResult => OneOffQueryResult.decode(decoder),
      .reducerResult => ReducerResultMessage.decode(decoder),
      .procedureResult => ProcedureResultMessage.decode(
        decoder,
      ),
    };
  }
}
