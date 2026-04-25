// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';
import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Test 5 of v2-pre-release-validation: live-wire byte-level decode of
/// `TransactionUpdate`.
///
/// SpaceNotes soak ran the SDK's hand-rolled decoder against real frames for a
/// week. That proves the decoder produces a usable `TransactionUpdateMessage`
/// — but not that the *byte interpretation* is correct. A symmetric tag/order
/// mistake (e.g. swapping `inserts` and `deletes`, or reading querySetId
/// before the query_sets list) would self-consistently round-trip on
/// fixtures the same hand-rolled code produced.
///
/// This test bypasses the SDK's MessageDecoder, captures a real
/// TransactionUpdate frame from the live server, and decodes it field-by-field
/// against the upstream Rust schema (`v2.rs:302-355` and
/// `common.rs:60-94`). It then cross-checks the byte-level result against
/// what the SDK's MessageDecoder produces from the same bytes — the two must
/// agree.
///
/// Same diagnostic pattern as `v2_protocol_negotiation_test.dart` (W1).
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  const host = 'localhost:3000';
  const database = 'notesdb';

  test('TransactionUpdate frame matches v2.rs byte layout exactly', () async {
    // Caller — drives the transaction via the SDK. We're not testing the
    // caller's ReducerResult here; we just need a reducer to commit so the
    // observer's TransactionUpdate fires.
    final caller = await createTestEnv();
    final callerReady = caller.subManager.onInitialConnection.first;
    await caller.connection.connect();
    await callerReady.timeout(const Duration(seconds: 10));
    await caller.subManager
        .subscribe(['SELECT * FROM note'])
        .timeout(const Duration(seconds: 10));

    // Observer — raw WebSocket. We control every byte read off this socket.
    // ?compression=None forces uncompressed frames so byte offsets are stable.
    final uri = Uri.parse(
      'ws://$host/v1/database/$database/subscribe?compression=None',
    );
    final channel = IOWebSocketChannel.connect(
      uri,
      protocols: ['v2.bsatn.spacetimedb'],
    );
    await channel.ready.timeout(const Duration(seconds: 5));
    expect(channel.protocol, 'v2.bsatn.spacetimedb');

    final pendingFrames = <Uint8List>[];
    final frameWaiters = <Completer<Uint8List>>[];
    final sub = channel.stream.listen(
      (data) {
        if (data is! List<int>) return;
        final bytes = Uint8List.fromList(data);
        if (frameWaiters.isNotEmpty) {
          frameWaiters.removeAt(0).complete(bytes);
        } else {
          pendingFrames.add(bytes);
        }
      },
      onError: (Object e) {
        for (final w in frameWaiters) {
          if (!w.isCompleted) w.completeError(e);
        }
        frameWaiters.clear();
      },
    );

    Future<Uint8List> readNextFrame({
      Duration timeout = const Duration(seconds: 5),
    }) async {
      if (pendingFrames.isNotEmpty) return pendingFrames.removeAt(0);
      final c = Completer<Uint8List>();
      frameWaiters.add(c);
      return c.future.timeout(timeout);
    }

    // Frame 1: InitialConnection (tag 0). Skip it.
    final f1 = await readNextFrame();
    expect(f1[0], 0, reason: 'compression=None');
    expect(f1[1], 0, reason: 'first server frame is InitialConnection (tag 0)');
    print('  ✓ InitialConnection received (${f1.length} bytes)');

    // Subscribe to note table on the raw socket so we'll receive
    // TransactionUpdate frames for changes. We use SubscribeMessage.encode()
    // because we're testing decode, not encode.
    final subscribeMsg = SubscribeMessage(
      ['SELECT * FROM note'],
      querySetId: 1,
      requestId: 1,
    );
    channel.sink.add(subscribeMsg.encode());

    // Frame 2: SubscribeApplied (tag 1). Skip it (table is empty so frame is small).
    final f2 = await readNextFrame();
    expect(f2[0], 0);
    expect(f2[1], 1, reason: 'SubscribeApplied tag is 1 in v2 ServerMessage');
    print('  ✓ SubscribeApplied received (${f2.length} bytes)');

    // Trigger a transaction the observer will see.
    final uniqueTitle = 'wire-test-${DateTime.now().microsecondsSinceEpoch}';
    unawaited(
      caller.reducers
          .createNote(title: uniqueTitle, content: 'wire-test body')
          .timeout(const Duration(seconds: 5)),
    );

    // Frame 3: TransactionUpdate (tag 4). This is the one we care about.
    final txFrame = await readNextFrame(timeout: const Duration(seconds: 5));
    print('  ✓ TransactionUpdate frame received (${txFrame.length} bytes)');

    // Hand-decode against v2.rs:302-306 + 308-355.
    expect(
      txFrame[0],
      0,
      reason: 'expected uncompressed (compression=None on URL)',
    );
    expect(
      txFrame[1],
      4,
      reason:
          'v2 ServerMessage tag 4 = TransactionUpdate (v2.rs:175-196). '
          'tag 0=InitialConnection, 1=SubscribeApplied, 2=UnsubscribeApplied, '
          '3=SubscriptionError, 4=TransactionUpdate, 5=OneOffQueryResult, '
          '6=ReducerResult, 7=ProcedureResult',
    );

    // Step through manually. v2.rs:304: `pub query_sets: Box<[QuerySetUpdate]>`.
    // BSATN list = u32 length + N elements.
    var off = 2;
    final querySetCount = ByteData.sublistView(
      txFrame,
      off,
      off + 4,
    ).getUint32(0, Endian.little);
    off += 4;
    print('  query_sets length: $querySetCount');
    expect(
      querySetCount,
      greaterThanOrEqualTo(1),
      reason: 'caller wrote one row → at least one QuerySetUpdate',
    );

    // QuerySetUpdate (v2.rs:308-314): { query_set_id: QuerySetId, tables: Box<[TableUpdate]> }
    // QuerySetId is a single-field newtype { id: u32 } — flattens to bare u32.
    final qsId = ByteData.sublistView(
      txFrame,
      off,
      off + 4,
    ).getUint32(0, Endian.little);
    off += 4;
    print('  query_set_id: $qsId');
    expect(qsId, 1, reason: 'we subscribed with querySetId=1');

    final tableCount = ByteData.sublistView(
      txFrame,
      off,
      off + 4,
    ).getUint32(0, Endian.little);
    off += 4;
    print('  tables length: $tableCount');
    expect(tableCount, 1, reason: 'one table affected (note)');

    // TableUpdate (v2.rs:316-321): { table_name: RawIdentifier, rows: Box<[TableUpdateRows]> }
    // RawIdentifier serializes as a length-prefixed UTF-8 string (u32 LE length).
    final nameLen = ByteData.sublistView(
      txFrame,
      off,
      off + 4,
    ).getUint32(0, Endian.little);
    off += 4;
    final tableName = utf8.decode(txFrame.sublist(off, off + nameLen));
    off += nameLen;
    print('  table_name: "$tableName"');
    expect(tableName, 'note');

    final rowsListLen = ByteData.sublistView(
      txFrame,
      off,
      off + 4,
    ).getUint32(0, Endian.little);
    off += 4;
    expect(
      rowsListLen,
      greaterThanOrEqualTo(1),
      reason: 'at least one TableUpdateRows entry',
    );

    // TableUpdateRows (v2.rs:339-342) is a sum: tag 0=PersistentTable, 1=EventTable.
    final rowsTag = txFrame[off];
    off += 1;
    print(
      '  TableUpdateRows tag: $rowsTag '
      '(0=PersistentTable, 1=EventTable)',
    );
    expect(
      rowsTag,
      0,
      reason: 'note is a persistent table → tag 0 (PersistentTable)',
    );

    // PersistentTableRows (v2.rs:346-349): { inserts: BsatnRowList, deletes: BsatnRowList }
    // BsatnRowList = RowSizeHint + u32 byte length + bytes.
    // RowSizeHint sum: tag 0=FixedSize(u16), tag 1=RowOffsets(Box<[u64]>).
    int decodeRowList(String label) {
      final hintTag = txFrame[off];
      off += 1;
      print(
        '    $label.size_hint tag: $hintTag '
        '(0=FixedSize, 1=RowOffsets)',
      );
      if (hintTag == 0) {
        final fixedSize = ByteData.sublistView(
          txFrame,
          off,
          off + 2,
        ).getUint16(0, Endian.little);
        off += 2;
        print('    $label.size_hint.fixedSize: $fixedSize');
      } else if (hintTag == 1) {
        final n = ByteData.sublistView(
          txFrame,
          off,
          off + 4,
        ).getUint32(0, Endian.little);
        off += 4;
        print('    $label.size_hint.rowOffsets count: $n');
        off += n * 8; // u64 each
      } else {
        fail('unknown RowSizeHint tag: $hintTag');
      }
      final byteLen = ByteData.sublistView(
        txFrame,
        off,
        off + 4,
      ).getUint32(0, Endian.little);
      off += 4;
      print('    $label.rows_data length: $byteLen bytes');
      off += byteLen;
      return byteLen;
    }

    final insertBytes = decodeRowList('inserts');
    final deleteBytes = decodeRowList('deletes');
    expect(
      insertBytes,
      greaterThan(0),
      reason: 'create_note inserted exactly one row, must be non-empty',
    );
    expect(deleteBytes, 0, reason: 'create_note has no deletes');

    // We should have consumed the entire frame for the single QuerySetUpdate
    // we expected. If extra bytes remain, the frame contains additional
    // QuerySetUpdates we didn't account for, OR our offsets drifted.
    // (Tolerate: there may be a second QuerySetUpdate from the caller's own
    // subscription if they share the database. Our subscribe used querySetId=1
    // so any extras would be other clients' query sets the server merges.)
    print('  consumed $off / ${txFrame.length} bytes');

    // Cross-check: feed the SAME bytes (minus compression tag + ServerMessage tag)
    // to the SDK's TransactionUpdateMessage decoder. Both should agree.
    final payload = txFrame.sublist(2);
    final decoder = BsatnDecoder(payload);
    final decoded = TransactionUpdateMessage.decode(decoder);
    expect(decoded.querySets, isNotEmpty);
    final qs0 = decoded.querySets.first;
    expect(qs0.querySetId, equals(qsId));
    expect(qs0.tables, hasLength(tableCount));
    expect(qs0.tables.first.tableName, equals(tableName));
    final rows0 = qs0.tables.first.rows.first;
    expect(rows0, isA<PersistentTableRows>());
    final persistent = rows0 as PersistentTableRows;
    expect(
      persistent.inserts.rowsData.length,
      equals(insertBytes),
      reason: 'SDK decode and hand decode must agree on inserts byte length',
    );
    expect(
      persistent.deletes.rowsData.length,
      equals(deleteBytes),
      reason: 'SDK decode and hand decode must agree on deletes byte length',
    );

    print('  ✓ SDK decoder agrees with hand-decoded byte layout');

    await sub.cancel();
    await channel.sink.close();
    caller.subManager.dispose();
    await caller.disconnect();
  });
}
