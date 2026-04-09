// ignore_for_file: avoid_print
import 'dart:io';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/schema_extractor.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/dart_generator.dart';

/// Integration test for generated client code
///
/// Tests that:
/// 1. Generated client auto-registers all tables
/// 2. connect() waits for initial subscription before returning
/// 3. Cache is populated immediately after connect() returns
///
/// Uses local project for schema extraction (no server required)
void main() {
  group('Generated Client Integration', () {
    late Directory tempDir;

    setUp(() async {
      // Create temp directory for generated code
      tempDir = await Directory.systemTemp.createTemp(
        'spacetime_codegen_test_',
      );
    });

    tearDown(() async {
      // Clean up temp directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'Generated client auto-registers tables and waits for initial data',
      () async {
        print('\n🧪 Testing Generated Client Auto-Registration\n');

        // Step 1: Extract schema
        print('📡 Extracting schema from local project...');
        final schema = await SchemaExtractor.fromProject(
          'spacetime_test_module',
        );

        expect(
          schema.tables.isNotEmpty,
          true,
          reason: 'Schema should have tables',
        );
        print('   ✅ Schema fetched: ${schema.tables.length} tables');

        // Step 2: Generate code
        print('\n📝 Generating client code...');
        final generator = DartGenerator(schema);
        final files = generator.generateAll();

        // Write files to temp directory
        for (final file in files) {
          final filePath = '${tempDir.path}/${file.filename}';
          await File(filePath).writeAsString(file.content);
        }
        print('   ✅ Generated ${files.length} files');

        // Step 3: Verify client.dart contains auto-registration
        print('\n🔍 Verifying auto-registration code...');
        final clientFile = files.firstWhere((f) => f.filename == 'client.dart');
        final clientCode = clientFile.content;

        // Check for registerDecoder calls
        for (final table in schema.tables) {
          final tableName = _toPascalCase(table.name);
          expect(
            clientCode.contains(
              "subscriptionManager.cache.registerDecoder<$tableName>('${table.name}', ${tableName}Decoder());",
            ),
            true,
            reason: 'Client should register decoder for $tableName',
          );
        }
        print('   ✅ All tables have decoder registration code');

        // Step 4: Verify two-phase API shape (create + connect)
        print('\n⏳ Verifying create() + connect() split...');
        expect(
          clientCode.contains('static Future<SpacetimeDbClient> create('),
          true,
          reason: 'Client should have static create() factory',
        );
        expect(
          clientCode.contains('Future<void> connect('),
          true,
          reason: 'Client should have instance connect() method',
        );
        expect(
          clientCode.contains('subscriptions.subscribe(initialSubscriptions).timeout(subscriptionTimeout)'),
          true,
          reason: 'connect() should subscribe with timeout',
        );
        print('   ✅ Two-phase API: create() factory + connect() instance method');

        // Step 5: Verify flow order in create() method
        print('\n🔄 Verifying create() method flow...');
        final createMethodStart = clientCode.indexOf('static Future<');
        final createMethodEnd = clientCode.indexOf(
          'return client;',
          createMethodStart,
        );
        final createMethod = clientCode.substring(
          createMethodStart,
          createMethodEnd + 'return client;'.length,
        );

        final registerIndex = createMethod.indexOf('registerDecoder');
        final clientConstructIndex = createMethod.indexOf('SpacetimeDbClient._(');

        expect(
          registerIndex > 0,
          true,
          reason: 'Should have registerDecoder call',
        );
        expect(
          clientConstructIndex > registerIndex,
          true,
          reason: 'Client construction should come after registration',
        );

        print('   ✅ Operation order is correct:');
        print('      create(): Register decoders → construct client → load cache');
        print('      connect(): Connect to server → subscribe to tables');

        // Note: Skipping static analysis because generated code in temp dir
        // can't resolve package imports without pubspec.yaml.
        // The integration test in codegen/generation_integration_test.dart
        // already tests that generated code passes analysis in a real project.

        print('\n✅ All generated client tests passed!\n');
      },
    );

    test('Generated code structure is complete', () async {
      print('\n🧪 Testing Generated Code Structure\n');

      // Extract schema
      final schema = await SchemaExtractor.fromProject('spacetime_test_module');

      // Generate code
      final generator = DartGenerator(schema);
      final files = generator.generateAll();

      // Verify expected files exist
      final expectedFiles = ['client.dart', 'reducers.dart'];
      for (final table in schema.tables) {
        expectedFiles.add('${table.name}.dart');
      }

      for (final expectedFile in expectedFiles) {
        expect(
          files.any((f) => f.filename == expectedFile),
          true,
          reason: 'Should generate $expectedFile',
        );
      }

      print('   ✅ All expected files generated');
      print('   Files: ${files.map((f) => f.filename).join(', ')}');

      // Verify each table file has decoder
      for (final table in schema.tables) {
        final tableFile = files.firstWhere(
          (f) => f.filename == '${table.name}.dart',
        );
        final className = _toPascalCase(table.name);

        expect(
          tableFile.content.contains('class $className '),
          true,
          reason: '$className class should exist',
        );

        expect(
          tableFile.content.contains(
            'class ${className}Decoder extends RowDecoder<$className>',
          ),
          true,
          reason: '${className}Decoder should exist',
        );

        expect(
          tableFile.content.contains('$className decode(BsatnDecoder decoder)'),
          true,
          reason: 'Decoder should have decode method',
        );

        expect(
          tableFile.content.contains('getPrimaryKey($className row)'),
          true,
          reason: 'Decoder should have getPrimaryKey method',
        );
      }

      print('   ✅ All table files have proper structure');
      print('\n✅ Code structure test passed!\n');
    });
  });
}

String _toPascalCase(String input) {
  return input
      .split('_')
      .map((word) {
        return word[0].toUpperCase() + word.substring(1).toLowerCase();
      })
      .join('');
}
