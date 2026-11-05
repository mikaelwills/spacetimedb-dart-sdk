// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class ForgetOnDisconnect {
  ForgetOnDisconnect({required this.identity});

  factory ForgetOnDisconnect.fromJson(Map<String, dynamic> json) {
    return ForgetOnDisconnect(
      identity: Identity.fromJson(json['identity'] ?? ''),
    );
  }

  final Identity identity;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeIdentity(identity);
  }

  static ForgetOnDisconnect decodeBsatn(BsatnDecoder decoder) {
    return ForgetOnDisconnect(identity: decoder.readIdentity());
  }

  Map<String, dynamic> toJson() {
    return {'identity': identity.toJson()};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ForgetOnDisconnect && identity == other.identity;
  }

  @override
  int get hashCode {
    return Object.hashAll([identity]);
  }

  @override
  String toString() {
    return 'ForgetOnDisconnect(identity: $identity)';
  }

  ForgetOnDisconnect copyWith({Identity? identity}) {
    return ForgetOnDisconnect(identity: identity ?? this.identity);
  }
}

class ForgetOnDisconnectDecoder extends RowDecoder<ForgetOnDisconnect> {
  @override
  ForgetOnDisconnect decode(BsatnDecoder decoder) {
    return ForgetOnDisconnect.decodeBsatn(decoder);
  }

  @override
  Identity? getPrimaryKey(ForgetOnDisconnect row) {
    return row.identity;
  }

  @override
  Map<String, dynamic>? toJson(ForgetOnDisconnect row) {
    return row.toJson();
  }

  @override
  ForgetOnDisconnect? fromJson(Map<String, dynamic> json) {
    return ForgetOnDisconnect.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
