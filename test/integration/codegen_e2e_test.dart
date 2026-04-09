// ignore_for_file: avoid_print
import 'dart:io';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/schema_extractor.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/dart_generator.dart';
import 'package:path/path.dart' as path;

import '../test_helpers.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('Codegen E2E', () {
    late Directory tempDir;
    late String sdkPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('spacetime_e2e_');
      sdkPath = findSdkRoot();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'Generated code functionality (Full CRUD cycle + Sum Types)',
      () async {
        print('Phase 1: Fetching Schema & Generating Code...');

        // 1. Get Real Schema from local project (no auth needed)
        final schema = await SchemaExtractor.fromProject(
          'spacetime_test_module',
        );

        // 2. Generate Code into Temp Dir
        final generator = DartGenerator(schema);
        await generator.writeToDirectory(tempDir.path);

        // 3. Create a "User App" script inside the temp dir
        // This script imports the GENERATED files, not your mocks.
        const userAppScript = """
import 'dart:io';
import 'dart:async';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'client.dart';      // Generated
import 'note.dart';        // Generated
import 'note_status.dart'; // Generated (Sum Type)

void main() async {
  try {
    print('   🚀 Connecting generated client...');
    final client = await SpacetimeDbClient.connect(
      host: 'localhost:3000',
      database: 'notesdb',
      initialSubscriptions: ['SELECT * FROM note'],
    );
    print('   ✅ Connected.');

    final uniqueTitle = 'E2E-\${DateTime.now().millisecondsSinceEpoch}';

    // =================================================================
    // 1. CREATE (Tests Serialization & Decoding)
    // =================================================================
    print('   📝 Testing CREATE...');

    // A. TRAP
    final createCompleter = Completer<Note>();
    void createListener() {
      final event = client.note.lastEvent.value;
      if (event is TableInsertEvent<Note> && event.row.title == uniqueTitle) {
        if (!createCompleter.isCompleted) createCompleter.complete(event.row);
      }
    }
    client.note.lastEvent.addListener(createListener);

    // B. TRIGGER
    client.reducers.createNote(
      title: uniqueTitle,
      content: 'Original Content'
    );

    // C. WAIT
    final createdNote = await createCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastEvent.removeListener(createListener);
    final noteId = createdNote.id; // Capture ID for next steps
    print('   ✅ CREATE Success. Got ID: \$noteId');

    if (createdNote.content != 'Original Content') throw 'Content mismatch';

    // =================================================================
    // 1.5. SUM TYPES (Tests Enum Generation & Pattern Matching)
    // =================================================================
    print('   🔍 Testing SUM TYPES (Generated Enums)...');

    // Verify the status field is strongly typed (not dynamic)
    final status = createdNote.status;
    if (status is! NoteStatus) {
      throw 'Status should be NoteStatus type, got \${status.runtimeType}';
    }

    // Test pattern matching exhaustiveness (compile-time safety)
    final statusDescription = switch (status) {
      NoteStatusDraft() => 'draft',
      NoteStatusPublished(:final value) => 'published_\$value',
      NoteStatusArchived() => 'archived',
    };

    // Verify we can construct and compare enum variants
    const testDraft = NoteStatusDraft();
    if (testDraft is! NoteStatusDraft) throw 'Enum construction failed';

    final testPublished = NoteStatusPublished(Int64(1234567890));
    if (testPublished is! NoteStatusPublished) throw 'Enum with payload failed';
    if (testPublished.value != Int64(1234567890)) throw 'Enum payload mismatch';

    print('   ✅ SUM TYPES Success. Status: \$statusDescription');

    // =================================================================
    // 2. UPDATE (Tests Primary Key Generation & Coalescing)
    // =================================================================
    print('   🔄 Testing UPDATE...');

    // A. TRAP
    final updateCompleter = Completer<TableUpdateEvent<Note>>();
    void updateListener() {
      final event = client.note.lastEvent.value;
      if (event is TableUpdateEvent<Note> && event.newRow.id == noteId) {
        if (!updateCompleter.isCompleted) updateCompleter.complete(event);
      }
    }
    client.note.lastEvent.addListener(updateListener);

    // B. TRIGGER
    client.reducers.updateNote(
      noteId: noteId,
      title: uniqueTitle,
      content: 'Updated Content'
    );

    // C. WAIT
    final updateEvent = await updateCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastEvent.removeListener(updateListener);
    print('   ✅ UPDATE Success.');

    if (updateEvent.newRow.content != 'Updated Content') throw 'Update failed';


    // =================================================================
    // 3. DELETE (Tests ID matching)
    // =================================================================
    print('   🗑️ Testing DELETE...');

    // A. TRAP
    final deleteCompleter = Completer<void>();
    void deleteListener() {
      final event = client.note.lastEvent.value;
      if (event is TableDeleteEvent<Note> && event.row.id == noteId) {
        if (!deleteCompleter.isCompleted) deleteCompleter.complete();
      }
    }
    client.note.lastEvent.addListener(deleteListener);

    // B. TRIGGER
    client.reducers.deleteNote(noteId: noteId);

    // C. WAIT
    await deleteCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastEvent.removeListener(deleteListener);
    print('   ✅ DELETE Success.');

    // Final Verification: Ensure it's gone from cache
    if (client.note.find(noteId) != null) {
        throw 'Cache mismatch: Note should be deleted but was found in find()';
    }

    print('   🎉 E2E COMPLETE: Full CRUD Cycle + Sum Types Verified.');
    exit(0);

  } catch (e, stack) {
    print('   ❌ E2E Failed: \$e');
    print(stack);
    exit(1);
  }
}
""";

        await File(
          path.join(tempDir.path, 'main.dart'),
        ).writeAsString(userAppScript);

        // 4. Create pubspec.yaml for the temp app
        await File(path.join(tempDir.path, 'pubspec.yaml')).writeAsString("""
name: e2e_temp_app
environment:
  sdk: ^3.0.0
dependencies:
  spacetimedb_dart_sdk:
    path: $sdkPath
""");

        print('Phase 2: Running "dart pub get" in temp environment...');
        final pubResult = await Process.run('dart', [
          'pub',
          'get',
        ], workingDirectory: tempDir.path);
        if (pubResult.exitCode != 0) {
          fail('Pub get failed:\n${pubResult.stderr}');
        }

        print('Phase 3: Executing Generated Client Logic...');
        final runResult = await Process.run('dart', [
          'run',
          'main.dart',
        ], workingDirectory: tempDir.path);

        print(runResult.stdout);
        if (runResult.exitCode != 0) {
          print(runResult.stderr);
          fail('Generated client execution failed.');
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    ); // Give time for pub get
  });
}
