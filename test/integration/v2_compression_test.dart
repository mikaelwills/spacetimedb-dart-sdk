// Verifies that the v2 outer-frame compression handling still works.
//
// The server decides whether to compress a `ServerMessage` based on its
// uncompressed size (`common.rs:35-45`, brotli by default). To exercise the
// compression decode path we need a single server frame large enough that
// brotli wins — achieved by bulk-inserting rows, then opening a fresh
// connection that subscribes and receives the whole rowset in one
// `SubscribeApplied` frame.
//
// We sniff the raw WS byte stream via `connection.onMessage` to inspect the
// outer compression tag (byte 0 of every frame; 0=none, 1=brotli, 2=gzip per
// `common.rs:47-54`). That way we get real evidence the compressed decode
// path fires, not just "nothing crashed."

import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'large SubscribeApplied roundtrips under v2 (compression-path smoke)',
    () async {
      // Seed: connection A publishes many rows.
      final envA = await createTestEnv();
      await envA.connection.connect();
      await envA.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );
      await envA.subManager.subscribe(['SELECT * FROM note']);

      final tableA = envA.subManager.cache.getTableByTypedName<Note>('note');
      if (tableA.count() > 0) {
        await envA.reducers.deleteAllNotes();
      }

      const rowCount = 120;
      // Each note carries a ~200-byte content; 120 * 200 ≈ 24 KB of row data,
      // which is comfortably above any plausible compression threshold.
      final filler = 'x' * 200;
      for (var i = 0; i < rowCount; i++) {
        await envA.reducers.createNote(
          title: 'CompressRow-$i',
          content: filler,
        );
      }
      expect(tableA.count(), equals(rowCount));

      envA.subManager.dispose();
      await envA.disconnect();

      // Fresh connection B — receives all rowCount rows in a single
      // SubscribeApplied frame. Decoder must handle whatever compression
      // tag the server chose.
      final envB = await createTestEnv();

      // Sniff compression tags on every raw frame before they reach the
      // decoder.
      final compressionTagsSeen = <int>{};
      int? largestFrameSize;
      int? largestFrameTag;
      final tagSub = envB.connection.onMessage.listen((bytes) {
        if (bytes.isEmpty) return;
        compressionTagsSeen.add(bytes[0]);
        if (largestFrameSize == null || bytes.length > largestFrameSize!) {
          largestFrameSize = bytes.length;
          largestFrameTag = bytes[0];
        }
      });

      await envB.connection.connect();
      await envB.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      final querySetId = await envB.subManager
          .subscribe(['SELECT * FROM note'])
          .timeout(const Duration(seconds: 10));

      await tagSub.cancel();

      final tableB = envB.subManager.cache.getTableByTypedName<Note>('note');
      expect(
        tableB.count(),
        equals(rowCount),
        reason:
            'all $rowCount rows must land in the cache — if this fails with a '
            'row count mismatch, the compressed-frame decode path is broken',
      );

      // The largest frame we saw should be the SubscribeApplied carrying all
      // 120 rows. Given ~200B content per row plus row framing, the payload
      // is well over any plausible compression threshold, so the outer tag
      // must be 1 (brotli) or 2 (gzip) — never 0 (none).
      expect(
        largestFrameTag,
        anyOf(equals(1), equals(2)),
        reason:
            'largest frame ($largestFrameSize bytes) was tag $largestFrameTag; '
            'expected brotli(1) or gzip(2). If it is 0 (none), the server '
            'compression threshold was not hit — bump rowCount/filler size. '
            'If decode succeeded with tag 0 the compression DECODE path '
            'is NOT being exercised by this test. Tags seen: $compressionTagsSeen',
      );

      // Spot-check a couple of rows to make sure the bytes decoded properly.
      final rows = tableB.iter().toList();
      expect(
        rows.where((n) => n.title.startsWith('CompressRow-')).length,
        equals(rowCount),
      );
      expect(
        rows.first.content.length,
        equals(200),
        reason: 'row bodies must decode without truncation',
      );

      // Cleanup so the next test doesn't see these.
      await envB.reducers.deleteAllNotes();
      envB.subManager.unsubscribe(querySetId);

      envB.subManager.dispose();
      await envB.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
