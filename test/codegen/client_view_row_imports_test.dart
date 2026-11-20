import 'package:spacetimedb_sdk/src/codegen/client_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

const _calendarRowImport = "import 'calendar_occurrence_row.dart';";
const _widgetImport = "import 'widget.dart';";

Map<String, dynamic> _field(String name, Map<String, dynamic> type) => {
  'name': {'some': name},
  'algebraic_type': type,
};

Map<String, dynamic> _product(List<Map<String, dynamic>> elements) => {
  'Product': {'elements': elements},
};

Map<String, dynamic> _typeDef(String name, int ty) => {
  'name': {'name': name, 'scope': []},
  'ty': ty,
  'custom_ordering': false,
};

Map<String, dynamic> _table(String name, int ref) => {
  'name': name,
  'product_type_ref': ref,
  'primary_key': [0],
};

Map<String, dynamic> _arrayView(String name, int ref) => {
  'name': name,
  'index': 0,
  'is_public': true,
  'is_anonymous': false,
  'params': {'elements': []},
  'return_type': {
    'Array': {'Ref': ref},
  },
};

DatabaseSchema _schemaWithView(Map<String, dynamic> view) {
  return DatabaseSchema.fromJson('calendardb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
        ]),
        _product([
          _field('event_id', {'U32': []}),
          _field('starts_at', {'String': []}),
        ]),
      ],
    },
    'tables': [_table('widget', 0)],
    'reducers': [],
    'types': [_typeDef('Widget', 0), _typeDef('CalendarOccurrenceRow', 1)],
    'views': [view],
  });
}

int _countOf(String needle, String haystack) =>
    needle.allMatches(haystack).length;

void main() {
  group('client.dart imports the row type of a view', () {
    test('a view row type that is not a table is imported once', () {
      final schema = _schemaWithView(_arrayView('calendar_range', 1));

      final client = ClientGenerator(schema).generate();

      expect(_countOf(_calendarRowImport, client), equals(1));
    });

    test('a view returning a table row type adds no duplicate import', () {
      final schema = _schemaWithView(_arrayView('widget_view', 0));

      final client = ClientGenerator(schema).generate();

      expect(_countOf(_widgetImport, client), equals(1));
    });

    test('two views naming the same row type import its file once', () {
      final schema = DatabaseSchema.fromJson('calendardb', {
        'typespace': {
          'types': [
            _product([
              _field('id', {'U32': []}),
            ]),
            _product([
              _field('event_id', {'U32': []}),
            ]),
          ],
        },
        'tables': [_table('widget', 0)],
        'reducers': [],
        'types': [_typeDef('Widget', 0), _typeDef('CalendarOccurrenceRow', 1)],
        'views': [
          _arrayView('calendar_range', 1),
          _arrayView('calendar_today', 1),
        ],
      });

      final client = ClientGenerator(schema).generate();

      expect(_countOf(_calendarRowImport, client), equals(1));
    });
  });
}
