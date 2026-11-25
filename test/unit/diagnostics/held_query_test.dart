@Tags(['unit'])
library;

import 'package:spacetimedb_sdk/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  const runningRow = {'runId': 7, 'state': 'running', 'assignmentId': null};

  test('a query with no WHERE matches every row of its table', () {
    final held = HeldQuery.parse('SELECT * FROM command_run');
    expect(held.tableName, 'command_run');
    expect(held.matches(runningRow), isTrue);
  });

  test('an equality on a text column matches only that value', () {
    final running = HeldQuery.parse(
      "SELECT * FROM command_run WHERE state = 'running'",
    );
    final done = HeldQuery.parse(
      "SELECT * FROM command_run WHERE state = 'done'",
    );
    expect(running.matches(runningRow), isTrue);
    expect(done.matches(runningRow), isFalse);
  });

  test('a snake_case column reads the camelCase row field', () {
    final held = HeldQuery.parse('SELECT * FROM command_run WHERE run_id = 7');
    expect(held.matches(runningRow), isTrue);
    expect(held.matches({...runningRow, 'runId': 8}), isFalse);
  });

  test('AND, OR and parentheses combine comparisons', () {
    final held = HeldQuery.parse(
      "SELECT * FROM command_run WHERE (state = 'done' OR state = 'running') "
      'AND run_id >= 7',
    );
    expect(held.matches(runningRow), isTrue);
    expect(held.matches({...runningRow, 'runId': 6}), isFalse);
    expect(held.matches({...runningRow, 'state': 'failed'}), isFalse);
  });

  test('a quoted quote inside a text literal is one quote', () {
    final held = HeldQuery.parse("SELECT * FROM note WHERE title = 'it''s'");
    expect(held.matches({'title': "it's"}), isTrue);
  });

  test('a null column never matches a comparison', () {
    final held = HeldQuery.parse(
      'SELECT * FROM command_run WHERE assignment_id = 3',
    );
    expect(held.matches(runningRow), isFalse);
  });

  test('a view called with arguments is read as its table', () {
    final held = HeldQuery.parse(
      "SELECT * FROM \"calendar_range\"('2026-01-01', '2026-02-01')",
    );
    expect(held.tableName, 'calendar_range');
    expect(held.canTestRows, isTrue);
  });

  test('a join is reported as unsupported instead of guessed', () {
    final held = HeldQuery.parse(
      'SELECT note.* FROM note JOIN folder ON note.title = folder.path',
    );
    expect(held.canTestRows, isFalse);
  });

  test('a column the row lacks is refused', () {
    final held = HeldQuery.parse("SELECT * FROM note WHERE colour = 'red'");
    expect(
      () => held.matches({'title': 'a'}),
      throwsA(isA<UnsupportedPredicate>()),
    );
  });
}
