import 'dart:io';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/offline/impl/atomic_file_store.dart';

void main() {
  group('AtomicFileStore.atomicWrite', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('atomic_file_store_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('creates the target directory when it does not exist', () async {
      final store = AtomicFileStore(tempDir.path);
      final file = File('${tempDir.path}/missing/nested/table_agent.json');

      await store.atomicWrite(file, '[{"id":1}]');

      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), '[{"id":1}]');
    });

    test('overwrites an existing file and keeps a backup of the old content',
        () async {
      final store = AtomicFileStore(tempDir.path);
      final file = File('${tempDir.path}/table_agent.json');
      await store.atomicWrite(file, 'old');

      await store.atomicWrite(file, 'new');

      expect(await file.readAsString(), 'new');
      expect(await File('${file.path}.bak').readAsString(), 'old');
    });
  });
}
