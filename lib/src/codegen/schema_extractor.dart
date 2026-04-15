import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

/// Extracts database schema from various sources
///
/// Supports:
/// - Network: Fetch from running SpacetimeDB instance
/// - Local project: Build and extract from Rust module
/// - WASM binary: Extract from compiled module
class SchemaExtractor {
  /// Extract schema from a running SpacetimeDB instance (network)
  ///
  /// Uses `spacetime describe --json` to fetch schema.
  static Future<DatabaseSchema> fromNetwork({
    required String database,
    String? server,
  }) async {
    final args = ['describe', '--json', database];
    if (server != null) {
      args.addAll(['--server', server]);
    }

    final result = await Process.run('spacetime', args, runInShell: true);

    if (result.exitCode != 0) {
      throw Exception('Failed to fetch schema: ${result.stderr}');
    }

    // Filter out WARNING lines
    final output = result.stdout.toString();
    final jsonStr = output
        .split('\n')
        .where((line) => !line.startsWith('WARNING:'))
        .join('\n');

    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw StateError(
        'Expected JSON object from spacetime describe, got ${decoded.runtimeType}',
      );
    }
    final json = decoded;

    return DatabaseSchema.fromJson(database, json);
  }

  /// Extract schema from a SpacetimeDB project directory
  ///
  /// This will:
  /// 1. Build the Rust module using `spacetime build`
  /// 2. Extract schema from the compiled WASM using `spacetimedb-standalone`
  /// 3. Parse the JSON schema
  ///
  /// Requires:
  /// - `spacetime` CLI installed
  /// - `spacetimedb-standalone` binary available
  static Future<DatabaseSchema> fromProject(String projectPath) async {
    SdkLogger.i('Building SpacetimeDB module at: $projectPath');

    // Build the module
    final buildResult = await Process.run('spacetime', [
      'build',
      '-p',
      projectPath,
    ], runInShell: true);

    if (buildResult.exitCode != 0) {
      throw Exception('Failed to build module:\n${buildResult.stderr}');
    }

    // Extract WASM path from build output
    final wasmPath = _parseWasmPath(buildResult.stdout.toString(), projectPath);
    SdkLogger.i('Module built: $wasmPath');

    // Extract schema from WASM
    return fromWasm(wasmPath);
  }

  /// Extract schema from a compiled WASM binary
  ///
  /// Uses `spacetimedb-standalone extract-schema` to read the schema
  /// embedded in the WASM module.
  static Future<DatabaseSchema> fromWasm(String wasmPath) async {
    SdkLogger.i('Extracting schema from WASM: $wasmPath');

    // Find spacetimedb-standalone binary
    final standalonePath = await _findStandaloneBinary();

    // Extract schema as JSON
    final result = await Process.run(standalonePath, [
      'extract-schema',
      wasmPath,
    ], runInShell: true);

    if (result.exitCode != 0) {
      throw Exception('Failed to extract schema:\n${result.stderr}');
    }

    // Parse JSON schema
    final jsonString = result.stdout.toString();
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw StateError(
        'Expected JSON object from WASM schema extraction, got ${decoded.runtimeType}',
      );
    }
    final json = decoded;

    // Extract database name from WASM filename or use placeholder
    final dbName = path.basenameWithoutExtension(wasmPath);

    // Unwrap version wrapper (e.g., {"V9": {...}}, {"V10": {...}})
    // SpacetimeDB wraps schemas in version envelopes like {"V9": schema}
    // We need to extract the actual schema from whatever version wrapper exists
    final schemaJson = _unwrapVersionEnvelope(json);

    return DatabaseSchema.fromJson(dbName, schemaJson);
  }

  /// Find the spacetimedb-standalone binary
  ///
  /// Looks in common installation locations:
  /// - ~/.local/share/spacetime/bin/current/spacetimedb-standalone
  /// - PATH
  static Future<String> _findStandaloneBinary() async {
    // Check standard installation location
    final home = Platform.environment['HOME'];
    if (home != null) {
      final standardPath = path.join(
        home,
        '.local/share/spacetime/bin/current/spacetimedb-standalone',
      );
      if (await File(standardPath).exists()) {
        return standardPath;
      }
    }

    // Try to find in PATH
    final whichResult = await Process.run('which', [
      'spacetimedb-standalone',
    ], runInShell: true);

    if (whichResult.exitCode == 0) {
      return whichResult.stdout.toString().trim();
    }

    throw Exception(
      'Could not find spacetimedb-standalone binary.\n'
      'Please ensure SpacetimeDB is installed: https://spacetimedb.com/install',
    );
  }

  /// Parse WASM path from `spacetime build` output
  ///
  /// The build output contains a line like:
  /// "Created module at: /path/to/module.wasm"
  static String _parseWasmPath(String buildOutput, String projectPath) {
    // Look for "Created module at:" or similar patterns
    final lines = buildOutput.split('\n');
    for (final line in lines) {
      if (line.contains('.wasm')) {
        // Extract path - handles various formats
        final match = RegExp(r'([^\s]+\.wasm)').firstMatch(line);
        if (match != null) {
          final wasmPath = match.group(1)!;
          // If relative path, resolve from project directory
          if (!path.isAbsolute(wasmPath)) {
            return path.join(projectPath, wasmPath);
          }
          return wasmPath;
        }
      }
    }

    // Fallback: check common build output locations
    final targetPath = path.join(
      projectPath,
      'target',
      'wasm32-unknown-unknown',
      'release',
    );
    final dir = Directory(targetPath);
    if (dir.existsSync()) {
      final wasmFiles =
          dir.listSync().where((f) => f.path.endsWith('.wasm')).toList();
      if (wasmFiles.isNotEmpty) {
        return wasmFiles.first.path;
      }
    }

    throw Exception(
      'Could not find compiled WASM file.\n'
      'Build output:\n$buildOutput',
    );
  }

  /// Unwrap version envelope from schema JSON
  ///
  /// SpacetimeDB wraps schemas in version envelopes like:
  /// {"V9": {...schema...}} or {"V10": {"sections": [...]}}
  ///
  /// V9 and earlier: flat structure with top-level keys (tables, reducers, etc.)
  /// V10+: sections-based structure that needs conversion to flat format
  static Map<String, dynamic> _unwrapVersionEnvelope(
    Map<String, dynamic> json,
  ) {
    if (json.length != 1) return json;

    final key = json.keys.first;
    if (!RegExp(r'^V\d+$').hasMatch(key)) return json;

    final value = json[key];
    if (value is! Map<String, dynamic>) {
      throw StateError(
        'Expected version envelope to contain Map, got ${value.runtimeType}',
      );
    }

    final sections = value['sections'];
    if (sections is List) {
      return _flattenSections(sections);
    }

    return _deepCast(value);
  }

  /// Convert V10+ sections array to flat schema map
  ///
  /// V10 format: {"sections": [{"Typespace": {...}}, {"Tables": [...]}, ...]}
  /// Output: {"typespace": {...}, "tables": [...], "reducers": [...], "types": [...]}
  static Map<String, dynamic> _flattenSections(List sections) {
    final result = <String, dynamic>{
      'typespace': <String, dynamic>{},
      'tables': <dynamic>[],
      'reducers': <dynamic>[],
      'types': <dynamic>[],
      'misc_exports': <dynamic>[],
      'views': <dynamic>[],
    };

    for (final rawSection in sections) {
      final section =
          rawSection is Map ? Map<String, dynamic>.from(rawSection) : null;
      if (section == null || section.length != 1) continue;

      final sectionKey = section.keys.first;
      final sectionValue = section.values.first;

      switch (sectionKey) {
        case 'Typespace':
          result['typespace'] =
              sectionValue is Map
                  ? Map<String, dynamic>.from(sectionValue)
                  : sectionValue;
        case 'Tables':
          result['tables'] = sectionValue is List ? sectionValue : [];
        case 'Reducers':
          result['reducers'] =
              sectionValue is List
                  ? _filterClientCallableReducers(sectionValue)
                  : [];
        case 'Types':
          result['types'] =
              sectionValue is List ? _convertV10Types(sectionValue) : [];
        case 'MiscExports':
          result['misc_exports'] = sectionValue is List ? sectionValue : [];
        case 'Views':
          result['views'] = sectionValue is List ? sectionValue : [];
      }
    }

    return _deepCast(result);
  }

  /// Filter reducers to only client-callable ones and normalize field names
  static List<dynamic> _filterClientCallableReducers(List<dynamic> reducers) {
    return reducers
        .whereType<Map>()
        .where((r) {
          final vis = r['visibility'];
          return vis is Map && vis.containsKey('ClientCallable');
        })
        .map((r) {
          return <String, dynamic>{
            'name': r['source_name'] ?? r['name'] ?? '',
            'params': r['params'] ?? {},
            'lifecycle': {},
          };
        })
        .toList();
  }

  /// Convert V10 type definitions to the format expected by TypeDef.fromJson
  ///
  /// V10: {"source_name": {"scope": [], "source_name": "Foo"}, "ty": 3, ...}
  /// Expected: {"name": {"scope": [], "name": "Foo"}, "ty": 3, ...}
  static List<dynamic> _convertV10Types(List<dynamic> types) {
    return types.map((t) {
      if (t is! Map) return t;
      final sourceName = t['source_name'];
      if (sourceName is Map && sourceName.containsKey('source_name')) {
        return <String, dynamic>{
          ...Map<String, dynamic>.from(t),
          'name': <String, dynamic>{
            'name': sourceName['source_name'],
            'scope': sourceName['scope'] ?? [],
          },
        };
      }
      return t;
    }).toList();
  }

  /// Recursively cast all Maps to Map<String, dynamic>
  static dynamic _deepCast(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.fromEntries(
        value.entries.map(
          (e) => MapEntry(e.key.toString(), _deepCast(e.value)),
        ),
      );
    }
    if (value is List) {
      return value.map(_deepCast).toList();
    }
    return value;
  }
}
