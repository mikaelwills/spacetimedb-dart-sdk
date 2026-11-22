import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:spacetimedb_sdk/src/codegen/wasm_locator.dart';
import 'package:test/test.dart';

const _builtWasmName = 'notesdb.wasm';
const _wasmReleaseSegments = ['wasm32-unknown-unknown', 'release'];
const _buildFinishedOutput = 'Build finished successfully.';
const _printedPathOutput = 'Created module at: /out/notesdb.wasm';

String _writeWasmIn(String directory) {
  Directory(directory).createSync(recursive: true);
  final file = File(path.join(directory, _builtWasmName))
    ..writeAsBytesSync([0]);
  return file.path;
}

void _writeCargoPackage(String projectPath, {String? targetDirectory}) {
  File(path.join(projectPath, 'Cargo.toml')).writeAsStringSync(
    '[package]\nname = "notesdb"\nversion = "0.1.0"\nedition = "2021"\n',
  );
  Directory(path.join(projectPath, 'src')).createSync();
  File(path.join(projectPath, 'src', 'lib.rs')).writeAsStringSync('');
  if (targetDirectory == null) return;
  Directory(path.join(projectPath, '.cargo')).createSync();
  File(path.join(projectPath, '.cargo', 'config.toml')).writeAsStringSync(
    '[build]\ntarget-dir = "$targetDirectory"\n',
  );
}

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('wasm_locator_project_');
  });

  tearDown(() => project.deleteSync(recursive: true));

  group('wasmPathFromBuildOutput', () {
    test('returns an absolute path the build prints', () {
      expect(
        WasmLocator.wasmPathFromBuildOutput(_printedPathOutput, project.path),
        '/out/notesdb.wasm',
      );
    });

    test('resolves a relative path the build prints against the project', () {
      expect(
        WasmLocator.wasmPathFromBuildOutput(
          'Created module at: target/notesdb.wasm',
          project.path,
        ),
        path.join(project.path, 'target', 'notesdb.wasm'),
      );
    });

    test('returns null when the output names no wasm path', () {
      expect(
        WasmLocator.wasmPathFromBuildOutput(_buildFinishedOutput, project.path),
        isNull,
      );
    });
  });

  group('locate', () {
    test('uses the path the build prints', () async {
      expect(
        await WasmLocator.locate(_printedPathOutput, project.path),
        '/out/notesdb.wasm',
      );
    });

    test(
      'finds the built wasm in the project target folder when the build '
      'prints no path',
      () async {
        final wasm = _writeWasmIn(
          path.join(project.path, 'target', ..._wasmReleaseSegments),
        );

        expect(
          await WasmLocator.locate(_buildFinishedOutput, project.path),
          wasm,
        );
      },
    );

    test(
      'finds the built wasm in a cargo target directory set outside the '
      'project',
      () async {
        final targetRoot = Directory.systemTemp.createTempSync(
          'wasm_locator_target_',
        );
        addTearDown(() => targetRoot.deleteSync(recursive: true));
        _writeCargoPackage(project.path, targetDirectory: targetRoot.path);
        final wasm = _writeWasmIn(
          path.join(targetRoot.path, ..._wasmReleaseSegments),
        );

        final located = await WasmLocator.locate(
          _buildFinishedOutput,
          project.path,
        );

        expect(path.canonicalize(located), path.canonicalize(wasm));
      },
    );

    test('throws when neither the output nor a target folder has the wasm', () {
      expect(
        WasmLocator.locate(_buildFinishedOutput, project.path),
        throwsA(isA<Exception>()),
      );
    });
  });
}
