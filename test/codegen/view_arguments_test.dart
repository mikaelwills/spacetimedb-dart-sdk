import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/subscription/view_call.dart';
import 'package:test/test.dart';

Map<String, dynamic> _field(String name, Map<String, dynamic> type) => {
  'name': {'some': name},
  'algebraic_type': type,
};

Map<String, dynamic> _view(String name, List<Map<String, dynamic>> params) => {
  'name': name,
  'index': 0,
  'is_public': true,
  'is_anonymous': false,
  'params': {'elements': params},
  'return_type': {
    'Array': {'Ref': 0},
  },
};

DatabaseSchema _schema(List<Map<String, dynamic>> views) =>
    DatabaseSchema.fromJson('vaultdb', {
      'typespace': {
        'types': [
          {
            'Product': {
              'elements': [
                _field('id', {'U32': []}),
              ],
            },
          },
        ],
      },
      'tables': [],
      'reducers': [],
      'types': [
        {
          'name': {'name': 'CalendarOccurrenceRow', 'scope': []},
          'ty': 0,
          'custom_ordering': false,
        },
      ],
      'views': views,
    });

final _whitespace = RegExp(r'\s+');
const _myRowsGetter = 'TableCache<CalendarOccurrenceRow>getmyRows';

String _clientSource(DatabaseSchema schema) =>
    DartGenerator(schema)
        .generateAll()
        .map((f) => f.content)
        .join()
        .replaceAll(_whitespace, '');

void main() {
  test('a two-parameter view generates a method with two typed parameters', () {
    final source = _clientSource(
      _schema([
        _view('calendar_range', [
          _field('from', {'String': []}),
          _field('to', {'String': []}),
        ]),
      ]),
    );

    expect(
      source,
      contains(
        'ViewCall<CalendarOccurrenceRow>calendarRange(Stringfrom,Stringto,)',
      ),
    );
    expect(source, contains("viewName:'calendar_range'"));
    expect(source, contains('arguments:[from,to]'));
  });

  test('a view row type that is not a table is named from the schema', () {
    final source = _clientSource(_schema([_view('my_rows', [])]));

    expect(source, contains(_myRowsGetter));
    expect(source, isNot(contains('Type0')));
  });

  test('a view call sends the query form the Rust SDK sends', () {
    expect(
      viewCallSql('calendar_range', ['2026-01-01', "it's"]),
      '''SELECT * FROM "calendar_range"('2026-01-01', 'it''s')''',
    );
    expect(
      viewCallSql('my_calendar_attachments', ['evt-1']),
      '''SELECT * FROM "my_calendar_attachments"('evt-1')''',
    );
    expect(
      viewCallSql('flagged', [true, 7]),
      'SELECT * FROM "flagged"(TRUE, 7)',
    );
  });

  test('a no-parameter view generates the unchanged getter', () {
    final source = _clientSource(_schema([_view('my_rows', [])]));

    expect(
      source,
      contains(
        "$_myRowsGetter{returnsubscriptions.cache"
        ".getTableByTypedName<CalendarOccurrenceRow>('my_rows');}",
      ),
    );
  });
}
