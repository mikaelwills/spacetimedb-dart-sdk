// ignore_for_file: avoid_print
import 'dart:io';

/// Setup SpacetimeDB test environment programmatically
Future<void> main() async {
  print('🚀 Setting up SpacetimeDB test environment...\n');

  // Check if spacetime CLI is installed
  final cliCheck = await Process.run('which', ['spacetime']);
  if (cliCheck.exitCode != 0) {
    print('❌ Error: spacetime CLI not found');
    print('Please install SpacetimeDB from https://spacetimedb.com/install');
    exit(1);
  }
  print('✅ SpacetimeDB CLI found');

  // Check if SpacetimeDB is running
  final statusCheck = await Process.run('spacetime', ['server', 'status']);
  if (statusCheck.exitCode != 0) {
    print('⚠️  SpacetimeDB not running, starting server...');
    await Process.start('spacetime', ['start']);
    await Future.delayed(const Duration(seconds: 3));
    print('✅ SpacetimeDB started');
  } else {
    print('✅ SpacetimeDB already running');
  }

  // Navigate to test module directory
  final testModuleDir = Directory('spacetime_test_module');
  if (!await testModuleDir.exists()) {
    print('❌ Error: Test module directory not found');
    exit(1);
  }

  // Build the test module
  print('🔨 Building test module...');
  final buildResult = await Process.run('spacetime', [
    'build',
  ], workingDirectory: testModuleDir.path);
  if (buildResult.exitCode != 0) {
    print('❌ Build failed: ${buildResult.stderr}');
    exit(1);
  }

  // Delete existing database if it exists (to start fresh)
  print('🗑️  Cleaning up existing test database...');
  await Process.run('spacetime', ['delete', 'notesdb']);

  // Publish the test module
  print('📦 Publishing test module to \'notesdb\'...');
  final publishResult = await Process.run('spacetime', [
    'publish',
    '--clear-database',
    'notesdb',
  ], workingDirectory: testModuleDir.path);

  if (publishResult.exitCode != 0) {
    print('❌ Publish failed: ${publishResult.stderr}');
    exit(1);
  }

  // Generate test code from notesdb schema
  print('🔧 Generating test code from notesdb schema...');
  final generateResult = await Process.run('dart', [
    'run',
    'spacetimedb_sdk:generate',
    '-d',
    'notesdb',
    '-s',
    'http://localhost:3000',
    '-o',
    'test/generated',
  ]);

  if (generateResult.exitCode != 0) {
    print('❌ Code generation failed: ${generateResult.stderr}');
    exit(1);
  }
  print('✅ Generated test code in test/generated/');

  print('\n✅ Test environment setup complete!\n');
  print('You can now run tests with:');
  print('  dart test\n');
}
