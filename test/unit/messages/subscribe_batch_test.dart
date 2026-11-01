import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/messages/message_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/subscribe_batch.dart';

List<int> _u32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _str(String value) {
  final bytes = utf8.encode(value);
  return [..._u32(bytes.length), ...bytes];
}

const _missingTableError =
    'no such table: `nonexistent_tbl`. If the table exists, it may be marked '
    'private., executing: `SELECT * FROM nonexistent_tbl`';

void main() {
  test('SubscribeBatch encodes byte for byte as the 2.14 capture', () {
    final message = SubscribeBatchMessage(
      requestId: 7,
      sets: [
        (querySetId: 11, queries: ['SELECT * FROM note']),
        (querySetId: 12, queries: ['SELECT * FROM nonexistent_tbl']),
        (querySetId: 13, queries: ['SELECT * FROM folder']),
      ],
    );

    expect(message.encode(), [
      0x05,
      ..._u32(7),
      ..._u32(3),
      ..._u32(11),
      ..._u32(1),
      ..._str('SELECT * FROM note'),
      ..._u32(12),
      ..._u32(1),
      ..._str('SELECT * FROM nonexistent_tbl'),
      ..._u32(13),
      ..._u32(1),
      ..._str('SELECT * FROM folder'),
    ]);
    expect(_str('SELECT * FROM note').sublist(0, 4), [0x12, 0, 0, 0]);
    expect(_str('SELECT * FROM nonexistent_tbl').sublist(0, 4), [
      0x1d,
      0,
      0,
      0,
    ]);
    expect(_str('SELECT * FROM folder').sublist(0, 4), [0x14, 0, 0, 0]);
    expect(utf8.encode(_missingTableError).length, 0x7c);
  });

  test('SubscribeBatchApplied decodes Applied, Error and empty Applied in '
      'request order', () async {
    final rowsData = [..._u32(1), ..._u32(2)];
    final frame = Uint8List.fromList([
      0x00,
      0x08,
      ..._u32(7),
      ..._u32(3),
      ..._u32(11),
      0x00,
      ..._u32(1),
      ..._str('note'),
      0x00,
      0x04,
      0x00,
      ..._u32(rowsData.length),
      ...rowsData,
      ..._u32(12),
      0x01,
      ..._str(_missingTableError),
      ..._u32(13),
      0x00,
      ..._u32(0),
    ]);

    final messages = await MessageDecoder.decodeAllInternal(frame);
    final reply = messages.single as SubscribeBatchApplied;

    expect(reply.requestId, 7);
    expect(reply.results.map((r) => r.querySetId), [11, 12, 13]);
    final note = reply.results[0].outcome as SubscribeSetApplied;
    expect(note.rows.tables.single.tableName, 'note');
    expect(note.rows.tables.single.rows.getRows(), hasLength(2));
    expect(
      (reply.results[1].outcome as SubscribeSetError).error,
      _missingTableError,
    );
    expect(
      (reply.results[2].outcome as SubscribeSetApplied).rows.tables,
      isEmpty,
    );
  });

  test('an empty SubscribeBatchApplied decodes to zero results', () async {
    final messages = await MessageDecoder.decodeAllInternal(
      Uint8List.fromList([0x00, 0x08, ..._u32(7), ..._u32(0)]),
    );
    final reply = messages.single as SubscribeBatchApplied;

    expect(reply.requestId, 7);
    expect(reply.results, isEmpty);
  });
}
