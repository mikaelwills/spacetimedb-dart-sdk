import 'dart:io';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/schema_extractor.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/dart_generator.dart';
import 'test_helpers.dart';

void main() {
  group('Code Generation Integration', () {
    late Directory tempDir;

    setUp(() async {
      // Create temporary directory for generated files
      tempDir = await Directory.systemTemp.createTemp('codegen_test_');
    });

    tearDown(() async {
      // Clean up temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('generates valid Dart code from notesdb schema', () async {
      // Extract schema from local project
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      // Verify schema was fetched correctly
      expect(schema.tables.length, greaterThan(0));
      expect(schema.reducers.length, greaterThan(0));

      // Generate code
      final generator = DartGenerator(schema);
      await generator.writeToDirectory(tempDir.path);

      // Verify files were created
      final noteFile = File('${tempDir.path}/note.dart');
      final reducersFile = File('${tempDir.path}/reducers.dart');
      final clientFile = File('${tempDir.path}/client.dart');

      expect(await noteFile.exists(), isTrue);
      expect(await reducersFile.exists(), isTrue);
      expect(await clientFile.exists(), isTrue);

      // Verify note.dart content
      final noteContent = await noteFile.readAsString();
      expect(noteContent, contains('class Note {'));
      expect(noteContent, contains('final int id;'));
      expect(noteContent, contains('final String title;'));
      expect(noteContent, contains('final String content;'));
      expect(noteContent, contains('final Int64 timestamp;'));
      expect(noteContent, contains('void encodeBsatn(BsatnEncoder encoder)'));
      expect(noteContent, contains('static Note decodeBsatn(BsatnDecoder decoder)'));
      expect(noteContent, contains('encoder.writeU32(id);'));
      expect(noteContent, contains('encoder.writeString(title);'));
      expect(noteContent, contains('decoder.readU32()'));
      expect(noteContent, contains('decoder.readString()'));

      // Verify reducers.dart content
      final reducersContent = await reducersFile.readAsString();
      expect(reducersContent, contains('class Reducers {'));
      expect(reducersContent, contains('Future<TransactionResult> createNote({'));
      expect(reducersContent, contains('required String title,'));
      expect(reducersContent, contains('required String content,'));
      expect(reducersContent, contains('Future<TransactionResult> init({List<OptimisticChange>? optimisticChanges, bool isEventTable = false}) async {'));
      expect(reducersContent, contains('Future<TransactionResult> updateNote({'));
      expect(reducersContent, contains('required int noteId,'));
      expect(reducersContent, contains("return await _reducerCaller.call('create_note', encoder.toBytes(), optimisticChanges: optimisticChanges, isEventTable: isEventTable)"));
      expect(reducersContent, contains("return await _reducerCaller.call('init', encoder.toBytes(), optimisticChanges: optimisticChanges, isEventTable: isEventTable)"));
      expect(reducersContent, contains("return await _reducerCaller.call('update_note', encoder.toBytes(), optimisticChanges: optimisticChanges, isEventTable: isEventTable)"));

      // Verify client.dart content
      final clientContent = await clientFile.readAsString();
      expect(clientContent, contains('class SpacetimeDbClient {'));
      expect(clientContent, contains('TableCache<Note> get note {'));
      expect(clientContent, contains('late final Reducers reducers;'));
      expect(clientContent, contains('static Future<SpacetimeDbClient> connect({'));
      expect(clientContent, contains('required String host,'));
      expect(clientContent, contains('required String database,'));
      expect(clientContent, contains('AuthTokenStore? authStorage,'));
      expect(clientContent, contains('bool ssl = false,'));
      expect(clientContent, contains('List<String>? initialSubscriptions,'));
      expect(clientContent, contains('Future<void> disconnect()'));

      // Verify all files have proper headers
      expect(noteContent, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND'));
      expect(reducersContent, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND'));
      expect(clientContent, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND'));

      // Verify all files have proper imports
      expect(noteContent, contains("import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';"));
      expect(reducersContent, contains("import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';"));
      expect(clientContent, contains("import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';"));
      expect(clientContent, contains("import 'reducers.dart';"));
      expect(clientContent, contains("import 'note.dart';"));
    });

    test('generated code has valid Dart syntax', () async {
      // Extract schema and generate code
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');
      final generator = DartGenerator(schema);
      await generator.writeToDirectory(tempDir.path);

      // Verify each file has valid Dart syntax by checking for common patterns
      final noteFile = File('${tempDir.path}/note.dart');
      final reducersFile = File('${tempDir.path}/reducers.dart');
      final clientFile = File('${tempDir.path}/client.dart');

      final noteContent = await noteFile.readAsString();
      final reducersContent = await reducersFile.readAsString();
      final clientContent = await clientFile.readAsString();

      // Check for balanced braces
      expect(_countChar(noteContent, '{'), equals(_countChar(noteContent, '}')));
      expect(_countChar(reducersContent, '{'), equals(_countChar(reducersContent, '}')));
      expect(_countChar(clientContent, '{'), equals(_countChar(clientContent, '}')));

      // Check for balanced parentheses
      expect(_countChar(noteContent, '('), equals(_countChar(noteContent, ')')));
      expect(_countChar(reducersContent, '('), equals(_countChar(reducersContent, ')')));
      expect(_countChar(clientContent, '('), equals(_countChar(clientContent, ')')));

      // Verify proper method signatures (should end with ; or { or })
      expect(noteContent, matches(r'void encodeBsatn\(BsatnEncoder encoder\) \{'));
      expect(reducersContent, matches(r'Future<TransactionResult> createNote\({'));
      expect(clientContent, matches(r'static Future<\w+Client> connect\({'));

      // Verify no obvious syntax errors
      expect(noteContent, isNot(contains('}{'))); // No immediate brace collision
      expect(reducersContent, isNot(contains('}{')));
      expect(clientContent, isNot(contains('}{' )));
    });

    test('generated code passes dart analyze', () async {
      // Create a temporary package structure
      final testPkgDir = await Directory.systemTemp.createTemp('analyze_test_');

      try {
        // Create lib directory
        final libDir = Directory('${testPkgDir.path}/lib');
        await libDir.create();

        // Extract schema and generate code
        final schema = await SchemaExtractor.fromProject('spacetime_test_module');
        final generator = DartGenerator(schema);
        await generator.writeToDirectory(libDir.path);

        final sdkPath = findSdkRoot();

        // Create pubspec.yaml with SDK dependency
        final pubspecContent = '''
name: codegen_analyze_test
description: Temporary package for testing generated code
version: 1.0.0
publish_to: none

environment:
  sdk: ^3.5.4

dependencies:
  spacetimedb_dart_sdk:
    path: $sdkPath
''';
        await File('${testPkgDir.path}/pubspec.yaml').writeAsString(pubspecContent);

        // Run dart pub get
        final pubGetResult = await Process.run(
          'dart',
          ['pub', 'get'],
          workingDirectory: testPkgDir.path,
        );

        expect(pubGetResult.exitCode, equals(0),
          reason: 'pub get should succeed:\n${pubGetResult.stdout}\n${pubGetResult.stderr}');

        // Run dart analyze
        final analyzeResult = await Process.run(
          'dart',
          ['analyze', '--fatal-infos'],
          workingDirectory: testPkgDir.path,
        );

        // Should have no analysis errors or warnings
        expect(analyzeResult.exitCode, equals(0),
          reason: 'Generated code should pass analysis:\n${analyzeResult.stdout}\n${analyzeResult.stderr}');

        // Verify no issues in output
        final output = analyzeResult.stdout.toString();
        expect(output, contains('No issues found!'));
      } finally {
        // Clean up test package
        if (await testPkgDir.exists()) {
          await testPkgDir.delete(recursive: true);
        }
      }
    });

    test('handles multiple tables correctly', () async {
      // This test will pass even with single table, but verifies the structure
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');
      final generator = DartGenerator(schema);
      final files = generator.generateAll();

      // Count sum types (enums) in the schema
      final sumTypeCount = schema.types
          .where((typeDef) => schema.typeSpace.types[typeDef.typeRef].sum != null)
          .length;

      // Should have: tables + sum_types + reducers + reducer_args + client
      final expectedFiles = schema.tables.length + sumTypeCount + 3;
      expect(files.length, equals(expectedFiles),
          reason: 'Expected ${schema.tables.length} tables + $sumTypeCount sum types + 3 system files');

      // Verify filenames
      final filenames = files.map((f) => f.filename).toList();
      expect(filenames, contains('reducers.dart'));
      expect(filenames, contains('reducer_args.dart'));
      expect(filenames, contains('client.dart'));

      for (final table in schema.tables) {
        expect(filenames, contains('${table.name}.dart'));
      }
    });
  });
}

int _countChar(String str, String char) {
  return char.allMatches(str).length;
}
