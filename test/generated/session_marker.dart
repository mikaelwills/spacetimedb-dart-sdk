// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class SessionMarker {
  SessionMarker({
    required this.connectionId,
    required this.requestId,
    required this.label,
  });

  factory SessionMarker.fromJson(Map<String, dynamic> json) {
    return SessionMarker(
      connectionId: ConnectionId.fromJson(json['connectionId'] as String),
      requestId: Uuid.fromJson(json['requestId'] as String),
      label: json['label'] ?? '',
    );
  }

  final ConnectionId connectionId;

  final Uuid requestId;

  final String label;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeConnectionId(connectionId);
    encoder.writeUuid(requestId);
    encoder.writeString(label);
  }

  static SessionMarker decodeBsatn(BsatnDecoder decoder) {
    return SessionMarker(
      connectionId: decoder.readConnectionId(),
      requestId: decoder.readUuid(),
      label: decoder.readString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'connectionId': connectionId.toJson(),
      'requestId': requestId.toJson(),
      'label': label,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SessionMarker &&
            connectionId == other.connectionId &&
            requestId == other.requestId &&
            label == other.label;
  }

  @override
  int get hashCode {
    return Object.hashAll([connectionId, requestId, label]);
  }

  @override
  String toString() {
    return 'SessionMarker(connectionId: $connectionId, requestId: $requestId, label: $label)';
  }

  SessionMarker copyWith({
    ConnectionId? connectionId,
    Uuid? requestId,
    String? label,
  }) {
    return SessionMarker(
      connectionId: connectionId ?? this.connectionId,
      requestId: requestId ?? this.requestId,
      label: label ?? this.label,
    );
  }
}

class SessionMarkerDecoder extends RowDecoder<SessionMarker> {
  @override
  SessionMarker decode(BsatnDecoder decoder) {
    return SessionMarker.decodeBsatn(decoder);
  }

  @override
  ConnectionId? getPrimaryKey(SessionMarker row) {
    return row.connectionId;
  }

  @override
  Map<String, dynamic>? toJson(SessionMarker row) {
    return row.toJson();
  }

  @override
  SessionMarker? fromJson(Map<String, dynamic> json) {
    return SessionMarker.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
