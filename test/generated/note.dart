// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'note_status.dart';

class Note {
  final int id;
  final String title;
  final String content;
  final Int64 timestamp;
  final NoteStatus status;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.timestamp,
    required this.status,
  });

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
    encoder.writeString(title);
    encoder.writeString(content);
    encoder.writeU64(timestamp);
    status.encode(encoder);
  }

  static Note decodeBsatn(BsatnDecoder decoder) {
    return Note(
      id: decoder.readU32(),
      title: decoder.readString(),
      content: decoder.readString(),
      timestamp: decoder.readU64(),
      status: NoteStatus.decode(decoder),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'timestamp': timestamp.toInt(),
      'status': status.toJson(),
    };
  }

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      timestamp: Int64(json['timestamp'] ?? 0),
      status: NoteStatus.fromJson(
        Map<String, dynamic>.from(json['status'] ?? {}),
      ),
    );
  }
}

class NoteDecoder extends RowDecoder<Note> {
  @override
  Note decode(BsatnDecoder decoder) {
    return Note.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(Note row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(Note row) => row.toJson();

  @override
  Note? fromJson(Map<String, dynamic> json) => Note.fromJson(json);

  @override
  bool get supportsJsonSerialization => true;
}
