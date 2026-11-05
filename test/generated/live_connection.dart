// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class LiveConnection {
  LiveConnection({required this.connectionId, required this.identity});

  factory LiveConnection.fromJson(Map<String, dynamic> json) {
    return LiveConnection(
      connectionId: ConnectionId.fromJson(json['connectionId'] as String),
      identity: Identity.fromJson(json['identity'] ?? ''),
    );
  }

  final ConnectionId connectionId;

  final Identity identity;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeConnectionId(connectionId);
    encoder.writeIdentity(identity);
  }

  static LiveConnection decodeBsatn(BsatnDecoder decoder) {
    return LiveConnection(
      connectionId: decoder.readConnectionId(),
      identity: decoder.readIdentity(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'connectionId': connectionId.toJson(),
      'identity': identity.toJson(),
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LiveConnection &&
            connectionId == other.connectionId &&
            identity == other.identity;
  }

  @override
  int get hashCode {
    return Object.hashAll([connectionId, identity]);
  }

  @override
  String toString() {
    return 'LiveConnection(connectionId: $connectionId, identity: $identity)';
  }

  LiveConnection copyWith({ConnectionId? connectionId, Identity? identity}) {
    return LiveConnection(
      connectionId: connectionId ?? this.connectionId,
      identity: identity ?? this.identity,
    );
  }
}

class LiveConnectionDecoder extends RowDecoder<LiveConnection> {
  @override
  LiveConnection decode(BsatnDecoder decoder) {
    return LiveConnection.decodeBsatn(decoder);
  }

  @override
  ConnectionId? getPrimaryKey(LiveConnection row) {
    return row.connectionId;
  }

  @override
  Map<String, dynamic>? toJson(LiveConnection row) {
    return row.toJson();
  }

  @override
  LiveConnection? fromJson(Map<String, dynamic> json) {
    return LiveConnection.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
