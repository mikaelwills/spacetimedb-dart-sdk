import 'dart:io';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:test/test.dart';

Uint8List _encodeEmptyQueryUpdateBody() {
  final bb = BytesBuilder();
  bb.addByte(0);
  bb.add([0, 0]);
  bb.add([0, 0, 0, 0]);
  bb.addByte(0);
  bb.add([0, 0]);
  bb.add([0, 0, 0, 0]);
  return bb.toBytes();
}

Uint8List _frameInner(int tag, List<int> compressed) {
  final bb = BytesBuilder();
  bb.addByte(tag);
  final len = compressed.length;
  bb.add([
    len & 0xff,
    (len >> 8) & 0xff,
    (len >> 16) & 0xff,
    (len >> 24) & 0xff,
  ]);
  bb.add(compressed);
  return bb.toBytes();
}

void main() {
  group('CompressableQueryUpdate', () {
    test('decodes Uncompressed variant (tag 0)', () {
      final body = _encodeEmptyQueryUpdateBody();
      final bb = BytesBuilder();
      bb.addByte(0);
      bb.add(body);

      final result = CompressableQueryUpdate.decode(BsatnDecoder(bb.toBytes()));

      expect(result.update.deletes.rowsData, isEmpty);
      expect(result.update.inserts.rowsData, isEmpty);
    });

    test('decodes Gzip variant (tag 2)', () {
      final body = _encodeEmptyQueryUpdateBody();
      final compressed = gzip.encode(body);
      final frame = _frameInner(2, compressed);

      final result = CompressableQueryUpdate.decode(BsatnDecoder(frame));

      expect(result.update.deletes.rowsData, isEmpty);
      expect(result.update.inserts.rowsData, isEmpty);
    });

    test('decodes Brotli variant (tag 1)', () {
      // Brotli-compressed bytes for a 14-byte empty QueryUpdate body
      // (two empty BsatnRowLists: [hint=0][rowSize=0][len=0] x2).
      // Generated once with: `brotli -c -q 11 <body>`. Regenerate if
      // QueryUpdate wire format changes. The Dart brotli package is
      // decode-only so encoding happens out-of-process.
      final compressed = Uint8List.fromList([
        0xa1,
        0x68,
        0x00,
        0xc0,
        0x3f,
        0x01,
        0x10,
        0x2f,
        0x04,
        0x00,
      ]);
      final frame = _frameInner(1, compressed);

      final result = CompressableQueryUpdate.decode(BsatnDecoder(frame));

      expect(result.update.deletes.rowsData, isEmpty);
      expect(result.update.inserts.rowsData, isEmpty);
    });

    test('throws on unknown compression tag', () {
      final frame = Uint8List.fromList([99]);

      expect(
        () => CompressableQueryUpdate.decode(BsatnDecoder(frame)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
