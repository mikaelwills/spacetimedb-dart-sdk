import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class WasmLocator {
  WasmLocator._();

  static const _cargoExecutable = 'cargo';
  static const _cargoBuildArguments = [
    'build',
    '--release',
    '--target',
    'wasm32-unknown-unknown',
    '--message-format=json',
  ];
  static const _wasmExtension = '.wasm';
  static const _compilerArtifactReason = 'compiler-artifact';
  static const _reasonKey = 'reason';
  static const _filenamesKey = 'filenames';
  static final _wasmPathPattern = RegExp(r'([^\s]+\.wasm)');

  static Future<String> locate(String buildOutput, String projectPath) async {
    final printedPath = wasmPathFromBuildOutput(buildOutput, projectPath);
    if (printedPath != null) return printedPath;
    return _wasmFromCargoBuild(projectPath);
  }

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

  static String? wasmArtifactFromCargoJson(String cargoJson) {
    String? wasmPath;
    for (final line in cargoJson.split('\n')) {
      final message = _decodeMessage(line);
      if (message == null) continue;
      if (message[_reasonKey] != _compilerArtifactReason) continue;
      final filenames = message[_filenamesKey];
      if (filenames is! List) continue;
      for (final filename in filenames) {
        if (filename is String && filename.endsWith(_wasmExtension)) {
          wasmPath = filename;
        }
      }
    }
    return wasmPath;
  }

  static Map<dynamic, dynamic>? _decodeMessage(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Future<String> _wasmFromCargoBuild(String projectPath) async {
    final result = await Process.run(
      _cargoExecutable,
      _cargoBuildArguments,
      workingDirectory: projectPath,
    );
    if (result.exitCode != 0) {
      throw Exception('cargo could not build the module:\n${result.stderr}');
    }
    final output = result.stdout;
    if (output is! String) {
      throw Exception('cargo printed no build messages for the module');
    }
    final wasmPath = wasmArtifactFromCargoJson(output);
    if (wasmPath == null) {
      throw Exception('cargo built the module without a .wasm artifact');
    }
    return wasmPath;
  }
}
