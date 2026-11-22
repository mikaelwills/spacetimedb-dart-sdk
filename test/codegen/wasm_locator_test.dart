import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:spacetimedb_sdk/src/codegen/wasm_locator.dart';
import 'package:test/test.dart';

const _buildFinishedOutput = 'Build finished successfully.';
const _printedPathOutput = 'Created module at: /out/notesdb.wasm';
const _wasmArtifactLine =
    '{"reason":"compiler-artifact","target":{"name":"notesdb"},'
    '"filenames":["/t/wasm32-unknown-unknown/release/notesdb.wasm"]}';
const _rlibArtifactLine =
    '{"reason":"compiler-artifact","target":{"name":"dep"},'
    '"filenames":["/t/release/libdep.rlib"]}';
const _buildFinishedLine = '{"reason":"build-finished","success":true}';

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

  group('wasmArtifactFromCargoJson', () {
    test('returns the wasm artifact among other cargo messages', () {
      final cargoJson = [
        'Compiling dep v1.0.0',
        _rlibArtifactLine,
        _wasmArtifactLine,
        _buildFinishedLine,
      ].join('\n');

      expect(
        WasmLocator.wasmArtifactFromCargoJson(cargoJson),
        '/t/wasm32-unknown-unknown/release/notesdb.wasm',
      );
    });

    test('returns null when cargo built no wasm artifact', () {
      final cargoJson = [_rlibArtifactLine, _buildFinishedLine].join('\n');

      expect(WasmLocator.wasmArtifactFromCargoJson(cargoJson), isNull);
    });
  });

  group('locate', () {
    test('uses the path the build prints', () async {
      expect(
        await WasmLocator.locate(_printedPathOutput, project.path),
        '/out/notesdb.wasm',
      );
    });

    test('throws when the build prints no path and cargo builds no wasm', () {
      expect(
        WasmLocator.locate(_buildFinishedOutput, project.path),
        throwsA(isA<Exception>()),
      );
    });
  });
}
