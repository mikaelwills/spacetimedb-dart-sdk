import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

const _viewRowFile = 'calendar_occurrence_row.dart';
const _tableRowFile = 'widget_row.dart';
const _plainFile = 'plain_note.dart';
const _normalisedName = 'T';

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

Map<String, dynamic> _widgetTable(List<int> primaryKey) => {
  'name': 'widget_row',
  'product_type_ref': 0,
  'primary_key': primaryKey,
};

DatabaseSchema _schema({List<int> widgetPrimaryKey = const []}) {
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
        _product([
          _field('note', {'String': []}),
        ]),
      ],
    },
    'tables': [_widgetTable(widgetPrimaryKey)],
    'reducers': [],
    'types': [
      _typeDef('WidgetRow', 0),
      _typeDef('CalendarOccurrenceRow', 1),
      _typeDef('PlainNote', 2),
    ],
    'views': [_arrayView('calendar_range', 1)],
  });
}

Map<String, String> _generatedContent(DatabaseSchema schema) => {
  for (final file in DartGenerator(schema).generateAll())
    file.filename: file.content,
};

String _decoderSource(String content, String className) {
  final start = content.indexOf('class ${className}Decoder ');
  expect(start, isNot(-1), reason: 'no ${className}Decoder in file');
  final end = content.indexOf('\n}\n', start);
  return content.substring(start, end + 3);
}

String _normalised(String source) => source
    .replaceAll('WidgetRow', _normalisedName)
    .replaceAll('CalendarOccurrenceRow', _normalisedName);

void main() {
  group('the row type of a view that is not a table', () {
    test('its file defines a decoder for the row type', () {
      final files = _generatedContent(_schema());

      final decoder = _decoderSource(
        files[_viewRowFile]!,
        'CalendarOccurrenceRow',
      );

      expect(
        decoder,
        startsWith(
          'class CalendarOccurrenceRowDecoder extends '
          'RowDecoder<CalendarOccurrenceRow> {',
        ),
      );
    });

    test('its decoder has the same shape as a table row decoder', () {
      final files = _generatedContent(_schema());

      final viewDecoder = _normalised(
        _decoderSource(files[_viewRowFile]!, 'CalendarOccurrenceRow'),
      );
      final tableDecoder = _normalised(
        _decoderSource(files[_tableRowFile]!, 'WidgetRow'),
      );

      expect(viewDecoder, equals(tableDecoder));
    });

    test('a type that is neither a table nor a view row gets no decoder', () {
      final files = _generatedContent(_schema());

      expect(files[_plainFile], isNot(contains('PlainNoteDecoder')));
    });
  });

  group('the row type of a table', () {
    test('keeps its data class and a decoder', () {
      final files = _generatedContent(_schema());

      expect(files[_tableRowFile], contains('class WidgetRow {'));
      expect(
        files[_tableRowFile],
        contains('class WidgetRowDecoder extends RowDecoder<WidgetRow> {'),
      );
    });

    test('a primary key still makes getPrimaryKey return that field', () {
      final files = _generatedContent(_schema(widgetPrimaryKey: [0]));

      expect(files[_tableRowFile], contains('return row.id;'));
      expect(files[_tableRowFile], isNot(contains('hasPrimaryKey')));
    });
  });
}
