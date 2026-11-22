import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

class WasmLocator {
  WasmLocator._();

  static const _wasmExtension = '.wasm';
  static const _wasmTargetTriple = 'wasm32-unknown-unknown';
  static const _releaseProfile = 'release';
  static const _cargoExecutable = 'cargo';
  static const _projectTargetFolder = 'target';
  static const _targetDirectoryKey = 'target_directory';
  static const _cargoMetadataArguments = [
    'metadata',
    '--no-deps',
    '--format-version',
    '1',
  ];
  static final _wasmPathPattern = RegExp(r'([^\s]+\.wasm)');

  static Future<String> locate(String buildOutput, String projectPath) async {
    final printedPath = wasmPathFromBuildOutput(buildOutput, projectPath);
    if (printedPath != null) return printedPath;

    final releaseDirectory = await _releaseWasmDirectory(projectPath);
    final builtPath = firstWasmIn(releaseDirectory);
    if (builtPath != null) return builtPath;

    throw Exception(
      'Could not find compiled WASM file.\n'
      'Build output:\n$buildOutput',
    );
  }

  @visibleForTesting
  static String? wasmPathFromBuildOutput(
    String buildOutput,
    String projectPath,
  ) {
    for (final line in buildOutput.split('\n')) {
      if (!line.contains(_wasmExtension)) continue;
      final wasmPath = _wasmPathPattern.firstMatch(line)?.group(1);
      if (wasmPath == null) continue;
      return path.isAbsolute(wasmPath)
          ? wasmPath
          : path.join(projectPath, wasmPath);
    }
    return null;
  }

  @visibleForTesting
  static String? firstWasmIn(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity.path.endsWith(_wasmExtension)) return entity.path;
    }
    return null;
  }

  static Future<String> _releaseWasmDirectory(String projectPath) async {
    final targetDirectory = await _cargoTargetDirectory(projectPath);
    return path.join(targetDirectory, _wasmTargetTriple, _releaseProfile);
  }

  static Future<String> _cargoTargetDirectory(String projectPath) async {
    final defaultDirectory = path.join(projectPath, _projectTargetFolder);
    try {
      final result = await Process.run(
        _cargoExecutable,
        _cargoMetadataArguments,
        workingDirectory: projectPath,
      );
      final output = result.stdout;
      if (result.exitCode != 0 || output is! String) return defaultDirectory;
      final metadata = jsonDecode(output);
      final reported = metadata is Map ? metadata[_targetDirectoryKey] : null;
      return reported is String ? reported : defaultDirectory;
    } on ProcessException {
      return defaultDirectory;
    } on FormatException {
      return defaultDirectory;
    }
  }
}
