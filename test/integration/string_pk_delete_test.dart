library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import '../generated/folder.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'String primary key delete events fire correctly',
    () async {
      final env = await createTestEnv(registerFolder: true);

      print('📡 Connecting...');
      await env.connection.connect();
      await env.subManager.onIdentityToken.first;

      env.subManager.subscribe(['SELECT * FROM folder']);
      await env.subManager.onInitialSubscription.first;

      final folderTable = env.folderTable;
      final initialCount = folderTable.count();
      print('✅ Connected & Subscribed. Initial folder count: $initialCount');

      if (initialCount > 0) {
        print('🧹 Cleaning up $initialCount existing folders...');
        await env.reducers.deleteAllFolders();
        await Future.delayed(const Duration(milliseconds: 500));
        print('   ✅ Clean slate established. Count: ${folderTable.count()}');
      }

      print('');
      print('📁 TEST 1: Single folder with String primary key');

      final testPath = '/test/folder-${DateTime.now().millisecondsSinceEpoch}';
      const testName = 'Test Folder';

      final insertFuture = folderTable.insertStream.first;

      await env.reducers.createFolder(path: testPath, name: testName);

      final createdFolder = await insertFuture.timeout(
        const Duration(seconds: 5),
      );
      print(
        '   ✅ Created folder: ${createdFolder.path} (${createdFolder.name})',
      );

      expect(createdFolder.path, equals(testPath));
      expect(folderTable.count(), equals(1));

      final deleteCompleter = Completer<Folder>();
      final deleteSubscription = folderTable.deleteStream.listen((folder) {
        print('   📡 Delete event received for: ${folder.path}');
        deleteCompleter.complete(folder);
      });

      print('   🗑️  Deleting folder: $testPath');
      await env.reducers.deleteFolder(path: testPath);

      final deletedFolder = await deleteCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
            'deleteStream did not fire for String PK delete',
          );
        },
      );

      await deleteSubscription.cancel();

      expect(deletedFolder.path, equals(testPath));
      expect(folderTable.count(), equals(0));

      print('   ✅ TEST 1 PASSED: Delete event fired correctly for String PK');

      print('');
      print('📁 TEST 2: Multi-delete with String primary keys');

      const foldersToCreate = 3;
      final createdFolders = <Folder>[];

      for (var i = 0; i < foldersToCreate; i++) {
        final path =
            '/multi/folder-${DateTime.now().millisecondsSinceEpoch}-$i';
        final name = 'Folder $i';

        final insertFuture2 = folderTable.insertStream.first;

        await env.reducers.createFolder(path: path, name: name);

        final folder = await insertFuture2.timeout(const Duration(seconds: 5));
        createdFolders.add(folder);
        print('   Created: ${folder.path}');
      }

      expect(folderTable.count(), equals(foldersToCreate));

      final deletedFolders = <Folder>[];
      final multiDeleteCompleter = Completer<void>();

      final multiDeleteSubscription = folderTable.deleteStream.listen((folder) {
        deletedFolders.add(folder);
        print('   📡 Delete event for: ${folder.path}');
        if (deletedFolders.length >= foldersToCreate) {
          multiDeleteCompleter.complete();
        }
      });

      print('   🗑️  Deleting all folders...');
      await env.reducers.deleteAllFolders();

      await multiDeleteCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print(
            '   ⏱️  Timeout! Only received ${deletedFolders.length}/$foldersToCreate delete events',
          );
        },
      );

      await multiDeleteSubscription.cancel();

      expect(deletedFolders.length, equals(foldersToCreate));
      expect(folderTable.count(), equals(0));

      print('   ✅ TEST 2 PASSED: All $foldersToCreate delete events received');

      print('');
      print('📊 Results Summary:');
      print('   ✅ String PK single delete: PASSED');
      print('   ✅ String PK multi-delete: PASSED');

      env.subManager.dispose();
      await env.disconnect();

      print('');
      print('🎉 All String PK delete tests passed!');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
