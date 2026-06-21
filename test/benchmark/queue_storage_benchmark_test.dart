// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

PendingMutation _mutation(String requestId) {
  return PendingMutation(
    requestId: requestId,
    reducerName: 'update_note',
    encodedArgs: Uint8List.fromList(List.filled(64, 7)),
    createdAt: DateTime.now(),
  );
}

void main() {
  test(
    'journal enqueue I/O grows linearly, not quadratically',
    () async {
      const n = 2000;
      final tempDir = await Directory.systemTemp.createTemp('queue_bench_');
      addTearDown(() async {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      });

      final storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();

      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        await storage.enqueueMutation(_mutation('req-$i'));
      }
      stopwatch.stop();

      final journalFile = File('${tempDir.path}/pending_mutations.jsonl');
      final journalBytesWritten = await journalFile.length();

      final recordBytes =
          utf8
              .encode(
                '${jsonEncode({'op': 'enqueue', 'mutation': _mutation('req-0').toJson()})}\n',
              )
              .length;
      final fullRewriteBytes = recordBytes * (n * (n + 1) ~/ 2);

      print(
        'journal: $n enqueues in ${stopwatch.elapsedMilliseconds}ms, '
        '$journalBytesWritten bytes written '
        '(full-rewrite equivalent would be ~$fullRewriteBytes bytes)',
      );

      expect(
        journalBytesWritten,
        lessThan(recordBytes * n * 2),
        reason: 'append-only journal writes ~one record per enqueue',
      );
      expect(
        journalBytesWritten / fullRewriteBytes,
        lessThan(0.05),
        reason:
            'journal I/O must be under 5% of the old full-rewrite I/O at '
            'this queue depth',
      );

      final reloaded = JsonFileStorage(basePath: tempDir.path);
      await reloaded.initialize();
      expect((await reloaded.getPendingMutations()).length, equals(n));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
