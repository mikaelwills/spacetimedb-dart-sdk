// ignore_for_file: avoid_print
import 'dart:io';

const _testServerHost = 'localhost:3000';
const _testServerUrl = 'http://$_testServerHost';
const _markerPath = '.test_setup_done';
const _lockPath = '.test_setup_lock';

Future<bool> _isServerReachable() async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 2);
    final request = await client.getUrl(Uri.parse('$_testServerUrl/database'));
    final response = await request.close();
    client.close();
    return response.statusCode < 500;
  } catch (e) {
    return false;
  }
}

bool _isMarkerFresh() {
  final marker = File(_markerPath);
  if (!marker.existsSync()) return false;
  try {
    final timestamp = marker.readAsStringSync();
    final setupTime = DateTime.parse(timestamp);
    return DateTime.now().difference(setupTime).inMinutes < 5;
  } catch (_) {
    return false;
  }
}

Future<void> _waitForSetup() async {
  for (var i = 0; i < 120; i++) {
    await Future.delayed(const Duration(seconds: 1));
    if (_isMarkerFresh()) return;
  }
  throw Exception('Timed out waiting for test environment setup');
}

Future<void> _killExistingServer() async {
  if (Platform.isMacOS || Platform.isLinux) {
    await Process.run('pkill', ['-f', 'spacetimedb-standalone.*3000']);
    await Future.delayed(const Duration(seconds: 2));
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> args, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  return result;
}

Future<void> setupTestEnvironment() async {
  if (_isMarkerFresh() && await _isServerReachable()) {
    return;
  }

  final lockFile = File(_lockPath);
  RandomAccessFile? lock;
  try {
    lock = lockFile.openSync(mode: FileMode.write);
    lock.lockSync(FileLock.exclusive);
  } catch (_) {
    print('Another process is setting up test environment, waiting...');
    await _waitForSetup();
    return;
  }

  try {
    if (_isMarkerFresh() && await _isServerReachable()) {
      return;
    }

    try {
      final result = await _run('spacetime', ['version', 'list']);
      if (result.exitCode != 0) throw Exception('CLI check failed');
    } catch (e) {
      throw Exception(
        'SpacetimeDB CLI not found. Install from https://spacetimedb.com/install',
      );
    }

    print('Killing any existing server on port 3000...');
    await _killExistingServer();

    print('Starting fresh in-memory SpacetimeDB server...');
    Process.start('spacetime', [
      'start',
      '--in-memory',
      '--listen-addr',
      '0.0.0.0:3000',
    ], mode: ProcessStartMode.detached);

    for (var i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (await _isServerReachable()) {
        print('SpacetimeDB server started on port 3000');
        break;
      }
      if (i == 14) {
        throw Exception('SpacetimeDB server failed to start after 15s');
      }
    }

    print('Logging into local server...');
    final loginResult = await _run('spacetime', [
      'login',
      '--server-issued-login',
      _testServerUrl,
    ]);
    if (loginResult.exitCode != 0) {
      print('Warning: Login failed: ${loginResult.stderr}');
    }

    final testModuleDir = Directory('spacetime_test_module');
    if (!await testModuleDir.exists()) {
      throw Exception('Test module directory not found: ${testModuleDir.path}');
    }

    print('Building test module...');
    final buildResult = await _run('spacetime', [
      'build',
    ], workingDirectory: testModuleDir.path);
    if (buildResult.exitCode != 0) {
      throw Exception('Build failed: ${buildResult.stderr}');
    }

    print('Publishing test module to $_testServerUrl...');
    final publishResult = await _run('spacetime', [
      'publish',
      '-s',
      _testServerUrl,
      '-y',
      'notesdb',
    ], workingDirectory: testModuleDir.path);
    if (publishResult.exitCode != 0) {
      final stderr = publishResult.stderr.toString();
      if (!stderr.contains('wasm-opt')) {
        print('Publish stdout: ${publishResult.stdout}');
        print('Publish stderr: $stderr');
        throw Exception('Publish failed (exit code ${publishResult.exitCode})');
      }
    }
    print('Published notesdb');

    print('Generating test code from local project...');
    final generateResult = await _run('dart', [
      'run',
      'spacetimedb_dart_sdk:generate',
      '--project-path',
      'spacetime_test_module',
      '--output',
      'test/generated',
    ]);
    if (generateResult.exitCode != 0) {
      print('Generate stdout: ${generateResult.stdout}');
      print('Generate stderr: ${generateResult.stderr}');
      throw Exception('Code generation failed: ${generateResult.stderr}');
    }
    print('Generated test code in test/generated/');

    File(_markerPath).writeAsStringSync(DateTime.now().toIso8601String());
    print('Test environment ready\n');
  } finally {
    lock.unlockSync();
    lock.closeSync();
  }
}

Future<void> teardownTestEnvironment() async {
  print('Tearing down test environment...');

  await _run('spacetime', ['delete', 'notesdb', '-s', _testServerUrl, '--yes']);
  await _killExistingServer();

  try {
    File(_markerPath).deleteSync();
  } catch (_) {}
  try {
    File(_lockPath).deleteSync();
  } catch (_) {}

  print('Test environment torn down');
}
