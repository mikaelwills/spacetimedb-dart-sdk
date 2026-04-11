// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

class TestFailure {
  final String name;
  final String error;
  final String? stackTrace;

  TestFailure(this.name, this.error, [this.stackTrace]);
}

void main() async {
  // Map Group ID -> Group Name
  final groupNames = <int, String>{};

  // Map Test ID -> Full Test Name (Group + Test Name)
  final testNames = <int, String>{};

  // Map Test ID -> Error Buffer (Tests can emit multiple error lines)
  final testErrors = <int, StringBuffer>{};

  // Final list of failures
  final failures = <TestFailure>[];

  print('Running tests...');

  final process = await Process.start('dart', [
    'test',
    '--reporter',
    'json',
  ], mode: ProcessStartMode.normal);

  // Pipe stderr to stderr (for compiler warnings/errors)
  process.stderr.pipe(stderr);

  await for (final line in process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;

    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) continue;
      final json = decoded;
      final String type = json['type'] ?? '';

      // 1. Track Groups (to build full test names)
      if (type == 'group') {
        final Map<String, dynamic> group = json['group'] ?? const {};
        final int id = group['id'] ?? 0;
        final String name = group['name'] ?? '';
        if (name.isNotEmpty) {
          groupNames[id] = name;
        }
      }
      // 2. Track Test Starts (Build the full name)
      else if (type == 'testStart') {
        final Map<String, dynamic> test = json['test'] ?? const {};
        final int id = test['id'] ?? 0;
        final String name = test['name'] ?? '';
        final List groupIdsRaw = test['groupIDs'] ?? const [];
        final groupIds = groupIdsRaw.cast<int>();

        // Build full name: "Group Name - SubGroup - Test Name"
        final buffer = StringBuffer();
        for (final gid in groupIds) {
          if (groupNames.containsKey(gid)) {
            buffer.write('${groupNames[gid]} ➜ ');
          }
        }
        buffer.write(name);
        testNames[id] = buffer.toString();
      }
      // 3. Capture Errors
      else if (type == 'error') {
        final int testId = json['testID'] ?? 0;
        final String error = json['error'] ?? '';
        final String stackTrace = json['stackTrace'] ?? '';

        testErrors.putIfAbsent(testId, () => StringBuffer()).writeln(error);
        if (stackTrace.isNotEmpty) {
          testErrors[testId]!.writeln(stackTrace);
        }
      }
      // 4. Process Done (The Filter Logic)
      else if (type == 'testDone') {
        final int testId = json['testID'] ?? 0;
        final String result = json['result'] ?? '';
        final bool hidden = json['hidden'] ?? false;
        final bool skipped = json['skipped'] ?? false;

        // CRITICAL FIX: Ignore "hidden" tests.
        // These are usually Suites or Groups that "failed" only because a child failed.
        if (!hidden && !skipped && (result == 'error' || result == 'failure')) {
          final name = testNames[testId] ?? 'Unknown Test ($testId)';
          final errorMsg =
              testErrors[testId]?.toString().trim() ??
              'Unknown error (Exit code failure?)';

          failures.add(TestFailure(name, errorMsg));
        }

        // Cleanup memory
        testErrors.remove(testId);
        testNames.remove(testId);
      }
    } catch (e) {
      // Ignore parse errors or non-JSON output
    }
  }

  // --- Reporting ---

  if (failures.isEmpty) {
    print('\x1B[32m\n✅ All tests passed!\x1B[0m\n'); // Green
    exit(0);
  } else {
    print('\x1B[31m\n❌ ${failures.length} TESTS FAILED:\x1B[0m\n'); // Red
    print('=' * 80);

    for (final failure in failures) {
      print('\x1B[1m📍 ${failure.name}\x1B[0m'); // Bold
      print('-' * 80);

      // Clean up error message (sometimes has excessive newlines)
      final cleanError = failure.error.split('\n').take(15).join('\n');
      print(cleanError);

      if (failure.error.split('\n').length > 15) {
        print('\x1B[90m... (Stack trace truncated)\x1B[0m');
      }
      print('');
    }

    print('=' * 80);
    exit(1);
  }
}
