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
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'client.dart';
import 'note.dart';
import 'note_status.dart';

void main() {
  test('e2e', () async {
    print('   🚀 Creating generated client...');
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    print('   🔌 Connecting...');
    await client.connect(initialSubscriptions: ['SELECT * FROM note']);
    print('   ✅ Connected.');

    final uniqueTitle = 'E2E-\${DateTime.now().millisecondsSinceEpoch}';

    print('   📝 Testing CREATE...');
    final createCompleter = Completer<Note>();
    void createListener() {
      final batch = client.note.lastBatch.value;
      if (batch == null) return;
      for (final event in batch.events) {
        if (event is TableInsertEvent<Note> && event.row.title == uniqueTitle) {
          if (!createCompleter.isCompleted) createCompleter.complete(event.row);
          return;
        }
      }
    }
    client.note.lastBatch.addListener(createListener);
    client.reducers.createNote(title: uniqueTitle, content: 'Original Content');
    final createdNote = await createCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastBatch.removeListener(createListener);
    final noteId = createdNote.id;
    print('   ✅ CREATE Success. Got ID: \$noteId');
    expect(createdNote.content, equals('Original Content'));

    print('   🔍 Testing SUM TYPES...');
    final status = createdNote.status;
    expect(status, isA<NoteStatus>());
    final statusDescription = switch (status) {
      NoteStatusDraft() => 'draft',
      NoteStatusPublished(:final value) => 'published_\$value',
      NoteStatusArchived() => 'archived',
    };
    const testDraft = NoteStatusDraft();
    expect(testDraft, isA<NoteStatusDraft>());
    final testPublished = NoteStatusPublished(Int64(1234567890));
    expect(testPublished.value, equals(Int64(1234567890)));
    print('   ✅ SUM TYPES Success. Status: \$statusDescription');

    print('   🔄 Testing UPDATE...');
    final updateCompleter = Completer<TableUpdateEvent<Note>>();
    void updateListener() {
      final batch = client.note.lastBatch.value;
      if (batch == null) return;
      for (final event in batch.events) {
        if (event is TableUpdateEvent<Note> && event.newRow.id == noteId) {
          if (!updateCompleter.isCompleted) updateCompleter.complete(event);
          return;
        }
      }
    }
    client.note.lastBatch.addListener(updateListener);
    client.reducers.updateNote(noteId: noteId, title: uniqueTitle, content: 'Updated Content');
    final updateEvent = await updateCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastBatch.removeListener(updateListener);
    print('   ✅ UPDATE Success.');
    expect(updateEvent.newRow.content, equals('Updated Content'));

    print('   🗑️ Testing DELETE...');
    final deleteCompleter = Completer<void>();
    void deleteListener() {
      final batch = client.note.lastBatch.value;
      if (batch == null) return;
      for (final event in batch.events) {
        if (event is TableDeleteEvent<Note> && event.row.id == noteId) {
          if (!deleteCompleter.isCompleted) deleteCompleter.complete();
          return;
        }
      }
    }
    client.note.lastBatch.addListener(deleteListener);
    client.reducers.deleteNote(noteId: noteId);
    await deleteCompleter.future.timeout(Duration(seconds: 5));
    client.note.lastBatch.removeListener(deleteListener);
    print('   ✅ DELETE Success.');

    expect(client.note.find(noteId), isNull);
    print('   🎉 E2E COMPLETE: Full CRUD Cycle + Sum Types Verified.');
  }, timeout: Timeout(Duration(seconds: 30)));
}
""";

        await File(
          path.join(tempDir.path, 'main.dart'),
        ).writeAsString(userAppScript);

        // 4. Create pubspec.yaml for the temp app (Flutter project since SDK depends on Flutter)
        await File(path.join(tempDir.path, 'pubspec.yaml')).writeAsString("""
name: e2e_temp_app
environment:
  sdk: ^3.7.0
dependencies:
  flutter:
    sdk: flutter
  spacetimedb_dart_sdk:
    path: $sdkPath
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
""");

        print('Phase 2: Running "flutter pub get" in temp environment...');
        final pubResult = await Process.run('flutter', [
          'pub',
          'get',
        ], workingDirectory: tempDir.path);
        if (pubResult.exitCode != 0) {
          fail('Pub get failed:\n${pubResult.stderr}');
        }

        print('Phase 3: Executing Generated Client Logic...');
        final runResult = await Process.run('flutter', [
          'test',
          '--no-pub',
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
