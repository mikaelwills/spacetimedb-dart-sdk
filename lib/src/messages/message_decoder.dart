import 'dart:typed_data';
import '../codec/bsatn_decoder.dart';
import 'decompress.dart';
import 'server_messages.dart';

/// Compression tags used by SpacetimeDB
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
  /// Async entry — strips the compression tag, decompresses with the
  /// platform-appropriate implementation (pure-Dart on VM, native
  /// DecompressionStream on web), then hands the uncompressed BSATN to the
  /// sync decoder.
  static Future<ServerMessage> decode(Uint8List bytes) async {
    final decoder = BsatnDecoder(bytes);
    final compressionTag = CompressionTag.fromValue(decoder.readU8());
    final payload = decoder.readBytes(decoder.remaining);

    final messageBytes = switch (compressionTag) {
      CompressionTag.none => payload,
      CompressionTag.brotli => await decompressBrotli(payload),
      CompressionTag.gzip => await decompressGzip(payload),
    };

    return _decodeServerMessage(messageBytes);
  }

  static ServerMessage _decodeServerMessage(Uint8List bytes) {
    final decoder = BsatnDecoder(bytes);

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
