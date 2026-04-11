import 'dart:typed_data';
import 'dart:io';
import 'package:brotli/brotli.dart';
import '../codec/bsatn_decoder.dart';
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
  static ServerMessage decode(Uint8List bytes) {
    final decoder = BsatnDecoder(bytes);

    final compressionTagValue = decoder.readU8();
    final compressionTag = CompressionTag.fromValue(compressionTagValue);

    Uint8List messageBytes;
    switch (compressionTag) {
      case CompressionTag.none:
        messageBytes = decoder.readBytes(decoder.remaining);

      case CompressionTag.brotli:
        final compressedData = decoder.readBytes(decoder.remaining);
        messageBytes = Uint8List.fromList(brotli.decode(compressedData));

      case CompressionTag.gzip:
        final compressedData = decoder.readBytes(decoder.remaining);
        messageBytes = Uint8List.fromList(gzip.decode(compressedData));
    }

    return _decodeServerMessage(messageBytes);
  }

  static ServerMessage _decodeServerMessage(Uint8List bytes) {
    final decoder = BsatnDecoder(bytes);

    final tag = decoder.readU8();
    final messageType = ServerMessageType.fromTag(tag);

    return switch (messageType) {
      ServerMessageType.identityToken => IdentityTokenMessage.decode(decoder),
      ServerMessageType.initialSubscription =>
        InitialSubscriptionMessage.decode(decoder),
      ServerMessageType.transactionUpdate => TransactionUpdateMessage.decode(
        decoder,
      ),
      ServerMessageType.transactionUpdateLight =>
        TransactionUpdateLightMessage.decode(decoder),
      ServerMessageType.oneOffQueryResponse => OneOffQueryResponse.decode(
        decoder,
      ),
      ServerMessageType.subscribeApplied => SubscribeApplied.decode(decoder),
      ServerMessageType.unsubscribeApplied => UnsubscribeApplied.decode(
        decoder,
      ),
      ServerMessageType.subscriptionError => SubscriptionErrorMessage.decode(
        decoder,
      ),
      ServerMessageType.subscribeMultiApplied => SubscribeMultiApplied.decode(
        decoder,
      ),
      ServerMessageType.unsubscribeMultiApplied =>
        UnsubscribeMultiApplied.decode(decoder),
      ServerMessageType.procedureResult => ProcedureResultMessage.decode(
        decoder,
      ),
    };
  }
}
