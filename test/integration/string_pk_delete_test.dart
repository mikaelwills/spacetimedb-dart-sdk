library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_dart_sdk/src/subscription/subscription_manager.dart';
import '../generated/folder.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'String primary key delete events fire correctly',
    () async {
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );

      final subManager = SubscriptionManager(connection);

      // 1. Register Table Decoder
      subManager.cache.registerDecoder<Folder>('folder', FolderDecoder());

      // 2. Register Reducer Argument Decoders
      subManager.reducerRegistry.registerDecoder(
        'create_folder',
        CreateFolderArgsDecoder(),
      );
      subManager.reducerRegistry.registerDecoder(
        'delete_folder',
        DeleteFolderArgsDecoder(),
      );
      subManager.reducerRegistry.registerDecoder(
        'delete_all_folders',
        DeleteAllFoldersArgsDecoder(),
      );

      print('📡 Connecting...');
      await connection.connect();

      // Wait for identity token before subscribing
      await subManager.onIdentityToken.first;

      // 3. Subscribe and Wait for the "Synced" state
      subManager.subscribe(['SELECT * FROM folder']);
      await subManager.onInitialSubscription.first;

      // Table is now accessible even if empty
      final folderTable = subManager.cache.getTableByTypedName<Folder>(
        'folder',
      );
      final initialCount = folderTable.count();
      print('✅ Connected & Subscribed. Initial folder count: $initialCount');

      // =========================================================================
      // CLEAN SLATE: Delete any existing folders from previous runs
      // =========================================================================
      if (initialCount > 0) {
        print('🧹 Cleaning up $initialCount existing folders...');
        await subManager.reducers.callWith('delete_all_folders', (encoder) {});
        // Wait for delete to propagate
        await Future.delayed(const Duration(milliseconds: 500));
        print('   ✅ Clean slate established. Count: ${folderTable.count()}');
      }

      // =========================================================================
      // TEST 1: Single folder create and delete with String PK
      // =========================================================================
      print('');
      print('📁 TEST 1: Single folder with String primary key');

      final testPath = '/test/folder-${DateTime.now().millisecondsSinceEpoch}';
      const testName = 'Test Folder';

      // Set up insert listener
      final insertFuture = folderTable.insertStream.first;

      // Create folder
      await subManager.reducers.callWith('create_folder', (encoder) {
        encoder.writeString(testPath);
        encoder.writeString(testName);
      });

      final createdFolder = await insertFuture.timeout(
        const Duration(seconds: 5),
      );
      print(
        '   ✅ Created folder: ${createdFolder.path} (${createdFolder.name})',
      );

      expect(createdFolder.path, equals(testPath));
      expect(folderTable.count(), equals(1));

      // Set up delete listener BEFORE calling delete
      final deleteCompleter = Completer<Folder>();
      final deleteSubscription = folderTable.deleteStream.listen((folder) {
        print('   📡 Delete event received for: ${folder.path}');
        deleteCompleter.complete(folder);
      });

      // Delete folder
      print('   🗑️  Deleting folder: $testPath');
      await subManager.reducers.callWith('delete_folder', (encoder) {
        encoder.writeString(testPath);
      });

      // Wait for delete event
      final deletedFolder = await deleteCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
            'deleteStream did not fire for String PK delete',
          );
        },
      );

      await deleteSubscription.cancel();

      // Assertions
      expect(
        deletedFolder.path,
        equals(testPath),
        reason: 'Deleted folder path should match',
      );
      expect(
        folderTable.count(),
        equals(0),
        reason: 'Cache should be empty after delete',
      );

      print('   ✅ TEST 1 PASSED: Delete event fired correctly for String PK');

      // =========================================================================
      // TEST 2: Multi-delete with String PKs
      // =========================================================================
      print('');
      print('📁 TEST 2: Multi-delete with String primary keys');

      const foldersToCreate = 3;
      final createdFolders = <Folder>[];

      // Create multiple folders
      for (var i = 0; i < foldersToCreate; i++) {
        final path =
            '/multi/folder-${DateTime.now().millisecondsSinceEpoch}-$i';
        final name = 'Folder $i';

        final insertFuture2 = folderTable.insertStream.first;

        await subManager.reducers.callWith('create_folder', (encoder) {
          encoder.writeString(path);
          encoder.writeString(name);
        });

        final folder = await insertFuture2.timeout(const Duration(seconds: 5));
        createdFolders.add(folder);
        print('   Created: ${folder.path}');
      }

      expect(folderTable.count(), equals(foldersToCreate));

      // Set up multi-delete listener
      final deletedFolders = <Folder>[];
      final multiDeleteCompleter = Completer<void>();

      final multiDeleteSubscription = folderTable.deleteStream.listen((folder) {
        deletedFolders.add(folder);
        print('   📡 Delete event for: ${folder.path}');

        if (deletedFolders.length >= foldersToCreate) {
          multiDeleteCompleter.complete();
        }
      });

      // Delete all folders
      print('   🗑️  Deleting all folders...');
      await subManager.reducers.callWith('delete_all_folders', (encoder) {});

      // Wait for all delete events
      await multiDeleteCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print(
            '   ⏱️  Timeout! Only received ${deletedFolders.length}/$foldersToCreate delete events',
          );
        },
      );

      await multiDeleteSubscription.cancel();

      // Assertions
      expect(
        deletedFolders.length,
        equals(foldersToCreate),
        reason:
            'deleteStream should fire for each deleted folder with String PK',
      );
      expect(folderTable.count(), equals(0), reason: 'Cache should be empty');

      print('   ✅ TEST 2 PASSED: All $foldersToCreate delete events received');

      // =========================================================================
      // SUMMARY
      // =========================================================================
      print('');
      print('📊 Results Summary:');
      print('   ✅ String PK single delete: PASSED');
      print('   ✅ String PK multi-delete: PASSED');

      // Cleanup
      subManager.dispose();
      await connection.disconnect();

      print('');
      print('🎉 All String PK delete tests passed!');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
