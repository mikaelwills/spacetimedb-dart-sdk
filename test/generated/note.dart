// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';
import 'note_status.dart';

class Note {
  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.timestamp,
    required this.status,
  });

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

  final int id;

  final String title;

  final String content;

  final Int64 timestamp;

  final NoteStatus status;

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

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Note &&
            id == other.id &&
            title == other.title &&
            content == other.content &&
            timestamp == other.timestamp &&
            status == other.status;
  }

  @override
  int get hashCode {
    return Object.hash(id, title, content, timestamp, status);
  }

  @override
  String toString() {
    return 'Note(id: $id, title: $title, content: $content, timestamp: $timestamp, status: $status)';
  }

  Note copyWith({
    int? id,
    String? title,
    String? content,
    Int64? timestamp,
    NoteStatus? status,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
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
  Map<String, dynamic>? toJson(Note row) {
    return row.toJson();
  }

  @override
  Note? fromJson(Map<String, dynamic> json) {
    return Note.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
