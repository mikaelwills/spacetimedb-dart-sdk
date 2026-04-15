// ignore_for_file: avoid_print
import 'dart:io';
import 'package:args/args.dart';
import 'package:spacetimedb_sdk/src/codegen/schema_extractor.dart';
import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';

void main(List<String> arguments) async {
  final parser =
      ArgParser()
        // Network approach (existing)
        ..addOption(
          'database',
          abbr: 'd',
          help: 'Database name to generate from',
        )
        ..addOption('server', abbr: 's', help: 'SpacetimeDB server URL')
        // Local file approach (new)
        ..addOption(
          'project-path',
          abbr: 'p',
          help: 'Path to SpacetimeDB Rust module project',
        )
        ..addOption('bin-path', abbr: 'b', help: 'Path to compiled WASM binary')
        // Common
        ..addOption(
          'output',
          abbr: 'o',
          mandatory: true,
          help: 'Output directory for generated files',
        )
        ..addFlag(
          'help',
          abbr: 'h',
          help: 'Show usage information',
          negatable: false,
        );

  try {
    final results = parser.parse(arguments);

    if (results['help'] ?? false) {
      _printUsage(parser);
      return;
    }

    final String? database = results['database'];
    final String? server = results['server'];
    final String? projectPath = results['project-path'];
    final String? binPath = results['bin-path'];
    final String output = results['output'] ?? '';

    // Validate: must provide EITHER (server + database) OR (project-path) OR (bin-path)
    final hasNetwork = server != null && database != null;
    final hasProject = projectPath != null;
    final hasBinary = binPath != null;

    if (!hasNetwork && !hasProject && !hasBinary) {
      throw const FormatException(
        'Must specify either:\n'
        '  - Network: --server and --database\n'
        '  - Project: --project-path\n'
        '  - Binary: --bin-path',
      );
    }

    if ([hasNetwork, hasProject, hasBinary].where((x) => x).length > 1) {
      throw const FormatException(
        'Can only specify one schema source at a time',
      );
    }

    // Extract schema from appropriate source
    final schema = await () async {
      if (hasNetwork) {
        print('Fetching schema for database: $database');
        print('Using server: $server');
        return SchemaExtractor.fromNetwork(database: database, server: server);
      } else if (hasProject) {
        print('Extracting schema from project: $projectPath');
        return SchemaExtractor.fromProject(projectPath);
      } else {
        print('Extracting schema from WASM: $binPath');
        return SchemaExtractor.fromWasm(binPath!);
      }
    }();

    print('\nGenerating Dart code...');
    print('  Tables: ${schema.tables.length}');
    print('  Reducers: ${schema.reducers.length}');
    print('  Views: ${schema.views.length}');
    print('  Types: ${schema.typeSpace.types.length}');
    print('');

    final generator = DartGenerator(schema);
    await generator.writeToDirectory(output);

    print('\nFormatting generated files...');
    final formatResult = await Process.run('dart', ['format', output]);
    if (formatResult.exitCode != 0) {
      print('Warning: dart format failed (exit ${formatResult.exitCode})');
      if (formatResult.stderr.toString().isNotEmpty) {
        print(formatResult.stderr);
      }
    }

    print('\n✅ Code generation complete!');
    print('Generated files in: $output');
  } on FormatException catch (e) {
    print('Error: ${e.message}\n');
    _printUsage(parser);
    exit(1);
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('SpacetimeDB Dart Code Generator\n');
  print('Usage: dart run spacetimedb_sdk:generate [options]\n');
  print('Options:');
  print(parser.usage);
  print('\nExamples:');
  print('  # Generate from running database (network)');
  print('  dart run spacetimedb_sdk:generate \\');
  print('    --server http://localhost:3000 \\');
  print('    --database notesdb \\');
  print('    --output lib/generated');
  print('');
  print('  # Generate from local Rust module project');
  print('  dart run spacetimedb_sdk:generate \\');
  print('    --project-path ../my-spacetime-module \\');
  print('    --output lib/generated');
  print('');
  print('  # Generate from compiled WASM binary');
  print('  dart run spacetimedb_sdk:generate \\');
  print(
    '    --bin-path ../my-module/target/wasm32-unknown-unknown/release/my_module.wasm \\',
  );
  print('    --output lib/generated');
}
