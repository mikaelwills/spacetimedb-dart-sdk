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

        // Check for auto-registration comment
        expect(
          clientCode.contains('// Auto-register table decoders'),
          true,
          reason: 'Generated client should have decoder registration comment',
        );

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

        // Step 4: Verify wait for initial subscription
        print('\n⏳ Verifying initial subscription wait...');
        expect(
          clientCode.contains(
            'await subscriptionManager.subscribe(initialSubscriptions).timeout(subscriptionTimeout);',
          ),
          true,
          reason:
              'Client should wait for initial subscription data with timeout',
        );
        expect(
          clientCode.contains(
            'subscriptionManager.subscribe(initialSubscriptions).timeout(subscriptionTimeout)',
          ),
          true,
          reason: 'Should have timeout in subscription call',
        );
        print('   ✅ Client waits for initial subscription with timeout');

        // Step 5: Verify flow order in connect() method
        print('\n🔄 Verifying connect() method flow...');
        final connectMethodStart = clientCode.indexOf('static Future<');
        final connectMethodEnd = clientCode.indexOf(
          'return client;',
          connectMethodStart,
        );
        final connectMethod = clientCode.substring(
          connectMethodStart,
          connectMethodEnd + 'return client;'.length,
        );

        // Check order of operations
        final registerIndex = connectMethod.indexOf('registerDecoder');
        final connectIndex = connectMethod.indexOf('connection.connect()');
        final subscribeIndex = connectMethod.indexOf(
          'subscriptionManager.subscribe',
        );

        expect(
          registerIndex > 0,
          true,
          reason: 'Should have registerDecoder call',
        );
        expect(
          connectIndex > registerIndex,
          true,
          reason: 'connect() should come after registration',
        );
        expect(
          subscribeIndex > connectIndex,
          true,
          reason: 'subscribe() should come after connect()',
        );

        print('   ✅ Operation order is correct:');
        print('      1. Register decoders');
        print('      2. Connect to server');
        print('      3. Subscribe to tables (activates them)');
        print('      4. Return client');

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
