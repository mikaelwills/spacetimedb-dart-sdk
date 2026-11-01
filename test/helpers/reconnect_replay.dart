import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';
import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:spacetimedb_sdk/src/messages/subscribe_batch.dart';

import '../mocks/mock_connection.dart';

const subscribeTag = 0;
const subscribeBatchTag = 5;

typedef SentBatchSet = ({int querySetId, List<String> queries});

typedef SentSubscribeBatch = ({int requestId, List<SentBatchSet> sets});

SentSubscribeBatch decodeSentSubscribeBatch(Uint8List frame) {
  final decoder = BsatnDecoder(frame);
  final tag = decoder.readU8();
  if (tag != subscribeBatchTag) {
    throw StateError('expected a SubscribeBatch frame (tag 5), got tag $tag');
  }
  final requestId = decoder.readU32();
  final sets = decoder.readList<SentBatchSet>(() {
    final querySetId = decoder.readU32();
    final queries = decoder.readList(decoder.readString);
    return (querySetId: querySetId, queries: queries);
  });
  return (requestId: requestId, sets: sets);
}

List<int> batchQuerySetIds(Uint8List frame) => [
  for (final set in decodeSentSubscribeBatch(frame).sets) set.querySetId,
];

int subscribeQuerySetId(Uint8List frame) {
  final decoder = BsatnDecoder(frame);
  final tag = decoder.readU8();
  if (tag != subscribeTag) {
    throw StateError('expected a Subscribe frame (tag 0), got tag $tag');
  }
  decoder.readU32();
  return decoder.readU32();
}

List<Uint8List> sentWithTag(Iterable<Uint8List> sent, int tag) => [
  for (final frame in sent)
    if (frame.isNotEmpty && frame[0] == tag) frame,
];

QueryRows queryRowsOf(Uint8List subscribeAppliedFrame) {
  final decoder = BsatnDecoder(subscribeAppliedFrame);
  decoder.readU8();
  final tag = decoder.readU8();
  if (tag != ServerMessageType.subscribeApplied.tag) {
    throw StateError('expected a SubscribeApplied frame (tag 1), got $tag');
  }
  return SubscribeApplied.decode(decoder).rows;
}

QueryRows queryRows(Map<String, List<Uint8List>> rowsByTable) {
  final tables = <SingleTableRows>[];
  for (final MapEntry(key: table, value: rows) in rowsByTable.entries) {
    final offsets = <int>[];
    final data = BsatnEncoder();
    var offset = 0;
    for (final row in rows) {
      offsets.add(offset);
      data.writeBytes(row);
      offset += row.length;
    }
    tables.add(
      SingleTableRows(
        tableName: table,
        rows: BsatnRowList(
          sizeHint: RowSizeHint.rowOffsets(offsets),
          rowsData: data.toBytes(),
        ),
      ),
    );
  }
  return QueryRows(tables: tables);
}

void writeQueryRows(BsatnEncoder encoder, QueryRows rows) {
  encoder.writeU32(rows.tables.length);
  for (final table in rows.tables) {
    encoder.writeString(table.tableName);
    final split = table.rows.getRows();
    encoder.writeU8(1);
    encoder.writeU32(split.length);
    var offset = 0;
    for (final row in split) {
      encoder.writeU64(Int64(offset));
      offset += row.length;
    }
    encoder.writeU32(offset);
    for (final row in split) {
      encoder.writeBytes(row);
    }
  }
}

Uint8List subscribeBatchAppliedBody(
  int requestId,
  List<SubscribeSetResult> results,
) {
  final encoder = BsatnEncoder();
  encoder.writeU8(SubscribeBatchApplied.tag);
  encoder.writeU32(requestId);
  encoder.writeU32(results.length);
  for (final result in results) {
    encoder.writeU32(result.querySetId);
    switch (result.outcome) {
      case SubscribeSetApplied(:final rows):
        encoder.writeU8(0);
        writeQueryRows(encoder, rows);
      case SubscribeSetError(:final error):
        encoder.writeU8(1);
        encoder.writeString(error);
    }
  }
  return encoder.toBytes();
}

Uint8List uncompressedFrame(List<Uint8List> bodies) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  for (final body in bodies) {
    encoder.writeBytes(body);
  }
  return encoder.toBytes();
}

Uint8List subscribeBatchAppliedFrame(
  int requestId,
  List<SubscribeSetResult> results,
) => uncompressedFrame([subscribeBatchAppliedBody(requestId, results)]);

Uint8List perSetSubscribeAppliedFrame(int querySetId, QueryRows rows) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(ServerMessageType.subscribeApplied.tag);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  writeQueryRows(encoder, rows);
  return encoder.toBytes();
}

Uint8List perSetSubscriptionErrorFrame(int querySetId, String error) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(ServerMessageType.subscriptionError.tag);
  encoder.writeOption<int>(null, encoder.writeU32);
  encoder.writeU32(querySetId);
  encoder.writeString(error);
  return encoder.toBytes();
}

bool replayIsBatch(List<Uint8List> sent) {
  for (final frame in sent.reversed) {
    if (frame.isEmpty) continue;
    if (frame[0] == subscribeBatchTag) return true;
    if (frame[0] == subscribeTag) return false;
  }
  return false;
}

SubscribeSetOutcome _outcomeFor(
  int querySetId,
  Map<int, QueryRows> applied,
  Map<int, String> errors,
) {
  final error = errors[querySetId];
  if (error != null) return SubscribeSetError(error);
  return SubscribeSetApplied(applied[querySetId] ?? QueryRows(tables: []));
}

List<Uint8List> reconnectReplayFrames(
  List<Uint8List> sent, {
  Map<int, QueryRows> applied = const {},
  Map<int, String> errors = const {},
}) {
  if (replayIsBatch(sent)) {
    final batch = decodeSentSubscribeBatch(
      sentWithTag(sent, subscribeBatchTag).last,
    );
    return [
      subscribeBatchAppliedFrame(batch.requestId, [
        for (final set in batch.sets)
          (
            querySetId: set.querySetId,
            outcome: _outcomeFor(set.querySetId, applied, errors),
          ),
      ]),
    ];
  }
  return [
    for (final MapEntry(key: id, value: rows) in applied.entries)
      if (!errors.containsKey(id)) perSetSubscribeAppliedFrame(id, rows),
    for (final MapEntry(key: id, value: error) in errors.entries)
      perSetSubscriptionErrorFrame(id, error),
  ];
}

void answerReconnectReplay(
  MockConnection mock, {
  Map<int, QueryRows> applied = const {},
  Map<int, String> errors = const {},
}) {
  for (final frame in reconnectReplayFrames(
    mock.sentMessages,
    applied: applied,
    errors: errors,
  )) {
    mock.simulateIncoming(frame);
  }
}
