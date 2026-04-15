// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/codegen/schema_extractor.dart';
import 'test_helpers.dart';

void main() {
  group('CLI Output Parsing', () {
    // Test the warning filter logic that's used in fromNetwork
    String filterWarnings(String output) {
      return output
          .split('\n')
          .where((line) => !line.startsWith('WARNING:'))
          .join('\n');
    }

    test('filters out single WARNING line before JSON', () {
      const rawOutput = '''WARNING: Server version mismatch
{"entities":[],"reducers":[]}''';

      final filtered = filterWarnings(rawOutput);
      final json = jsonDecode(filtered);

      expect(json, isA<Map>());
      expect(json['entities'], isA<List>());
      expect(json['reducers'], isA<List>());
    });

    test('filters out multiple WARNING lines', () {
      const rawOutput = '''WARNING: First warning
WARNING: Second warning
WARNING: Third warning
{"entities":[],"reducers":[]}''';

      final filtered = filterWarnings(rawOutput);
      final json = jsonDecode(filtered);

      expect(json, isA<Map>());
    });

    test('handles WARNING lines interspersed with valid JSON', () {
      const rawOutput = '''WARNING: Before JSON
{
WARNING: This would break JSON if not filtered
  "entities": [],
  "reducers": []
}''';

      final filtered = filterWarnings(rawOutput);

      // Should filter WARNING even in middle of JSON
      expect(filtered, contains('"entities"'));
      expect(filtered, isNot(contains('WARNING:')));
    });

    test('preserves valid JSON when no warnings present', () {
      const rawOutput = '{"entities":[],"reducers":[]}';

      final filtered = filterWarnings(rawOutput);
      final json = jsonDecode(filtered);

      expect(json, equals({'entities': [], 'reducers': []}));
    });

    test('handles empty output', () {
      const rawOutput = '';
      final filtered = filterWarnings(rawOutput);
      expect(filtered, isEmpty);
    });

    test('handles only warnings (no JSON)', () {
      const rawOutput = '''WARNING: First
WARNING: Second''';

      final filtered = filterWarnings(rawOutput);
      // Two empty strings joined with newline = empty string
      expect(filtered, isEmpty);
    });

    test('case sensitive - does not filter "warning:" lowercase', () {
      const rawOutput = '''warning: this is lowercase
WARNING: this is uppercase
{"test": true}''';

      final filtered = filterWarnings(rawOutput);

      expect(filtered, contains('warning: this is lowercase'));
      expect(filtered, isNot(contains('WARNING:')));
    });

    test('filters "WARNING:" prefix only at line start', () {
      const rawOutput = '''Some text WARNING: not at start
WARNING: at start
{"test": true}''';

      final filtered = filterWarnings(rawOutput);

      expect(filtered, contains('Some text WARNING: not at start'));
      expect(filtered, isNot(contains('WARNING: at start')));
    });
  });

  group('SchemaExtractor', () {
    test('fromProject - fetch schema from local project', () async {
      final sdkRoot = findSdkRoot();
      final schema = await SchemaExtractor.fromProject(
        '$sdkRoot/spacetime_test_module',
      );

      expect(schema.tables.isNotEmpty, true);
      expect(schema.tables.map((t) => t.name), contains('note'));
      expect(schema.tables.map((t) => t.name), contains('folder'));
      expect(schema.reducers.isNotEmpty, true);
    }, tags: ['integration']);

    test('fromWasm - successfully extracts schema from WASM file', () async {
      final sdkRoot = findSdkRoot();
      final wasmPath = '$sdkRoot/test/fixtures/spacetime_test_module.wasm';

      // Guard against environment issues (don't fail if fixture is missing)
      if (!File(wasmPath).existsSync()) {
        print('⚠️  Skipping WASM test: Fixture not found at $wasmPath');
        markTestSkipped(
          'Fixture missing - run: cp spacetime_test_module/target/wasm32-unknown-unknown/release/spacetime_test_module.wasm test/fixtures/',
        );
        return;
      }

      final schema = await SchemaExtractor.fromWasm(wasmPath);

      // Verify structure (object was created)
      expect(schema, isNotNull);

      // Verify content (parser actually worked and found data)
      expect(
        schema.tables,
        isNotEmpty,
        reason: 'Schema should contain tables from test module',
      );

      // Verify specific known table from our test fixture
      expect(
        schema.tables.map((t) => t.name),
        contains('note'),
        reason: 'Test module should have "note" table',
      );
    });

    test('fromWasm - handles nonexistent WASM file', () async {
      await expectLater(
        SchemaExtractor.fromWasm('/nonexistent/module.wasm'),
        // Verify the error type and message to ensure it failed for the right reason
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'error message',
            contains('Failed to extract schema'),
          ),
        ),
      );
    });

    test('fromProject - successfully builds and extracts schema', () async {
      final sdkRoot = findSdkRoot();
      final projectPath = '$sdkRoot/spacetime_test_module';

      // Guard against environment issues (don't fail if project is missing)
      if (!Directory(projectPath).existsSync()) {
        print(
          '⚠️  Skipping project build test: Project not found at $projectPath',
        );
        markTestSkipped('Test project missing');
        return;
      }

      final schema = await SchemaExtractor.fromProject(projectPath);

      // Verify structure (object was created)
      expect(schema, isNotNull);

      // Verify content (build and parser actually worked)
      expect(
        schema.tables,
        isNotEmpty,
        reason: 'Schema should contain tables from built module',
      );

      // Verify specific known table from our test module
      expect(
        schema.tables.map((t) => t.name),
        contains('note'),
        reason: 'Test module should have "note" table',
      );
    });

    test('fromProject - handles nonexistent project', () async {
      await expectLater(
        SchemaExtractor.fromProject('/nonexistent/project'),
        // Verify the error type and message to ensure it failed for the right reason
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'error message',
            contains('Failed to build module'),
          ),
        ),
      );
    });

    test('fromNetwork - handles missing server', () async {
      await expectLater(
        SchemaExtractor.fromNetwork(
          database: 'nonexistent',
          server: 'http://localhost:9999',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('fromProject - filters WARNING lines from output', () async {
      final sdkRoot = findSdkRoot();
      final schema = await SchemaExtractor.fromProject(
        '$sdkRoot/spacetime_test_module',
      );

      // If we got here without JSON parsing errors, warnings were filtered
      expect(schema, isNotNull);
      expect(schema.tables.isNotEmpty, true);
    }, tags: ['integration']);
  });

  group('SchemaExtractor - Integration Tests', () {
    test(
      'all three methods produce equivalent schemas',
      () async {
        final sdkRoot = findSdkRoot();

        // Use spacetime_test_module from the project root, or override with env var
        final testProjectPath =
            Platform.environment['SPACETIME_TEST_PROJECT'] ??
            '$sdkRoot/spacetime_test_module';

        // Extract from project (builds WASM)
        final schemaFromProject = await SchemaExtractor.fromProject(
          testProjectPath,
        );

        // Find the built WASM
        final wasmPath =
            '$testProjectPath/target/wasm32-unknown-unknown/release';
        final wasmFiles =
            Directory(
              wasmPath,
            ).listSync().where((f) => f.path.endsWith('.wasm')).toList();

        expect(
          wasmFiles.isNotEmpty,
          true,
          reason: 'No WASM files found after build',
        );

        // Extract from WASM
        final schemaFromWasm = await SchemaExtractor.fromWasm(
          wasmFiles.first.path,
        );

        // Both should have same structure
        expect(schemaFromProject.tables.length, schemaFromWasm.tables.length);
        expect(
          schemaFromProject.reducers.length,
          schemaFromWasm.reducers.length,
        );

        // If module is deployed, compare with network too
        final dbName = Platform.environment['SPACETIME_TEST_DATABASE'];
        if (dbName != null) {
          final schemaFromNetwork = await SchemaExtractor.fromNetwork(
            database: dbName,
            server: 'http://localhost:3000',
          );

          expect(
            schemaFromNetwork.tables.length,
            schemaFromProject.tables.length,
          );
          expect(
            schemaFromNetwork.reducers.length,
            schemaFromProject.reducers.length,
          );
        }
      },
      tags: ['integration', 'full-environment'],
    );
  });
}
