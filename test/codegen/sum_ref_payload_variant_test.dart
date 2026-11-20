import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

const _eventTypeRef = 0;
const _timingTypeRef = 1;
const _timedSpanTypeRef = 2;

Map<String, dynamic> _namedEntry(String name, Map<String, dynamic> type) => {
  'name': {'some': name},
  'algebraic_type': type,
};

Map<String, dynamic> _namedType(String name, int typeRef) => {
  'name': {'name': name, 'scope': []},
  'ty': typeRef,
  'custom_ordering': false,
};

DatabaseSchema _timingSchema() {
  return DatabaseSchema.fromJson('calendardb', {
    'typespace': {
      'types': [
        {
          'Product': {
            'elements': [
              _namedEntry('timing', {'Ref': _timingTypeRef}),
            ],
          },
        },
        {
          'Sum': {
            'variants': [
              _namedEntry('Timed', {'Ref': _timedSpanTypeRef}),
              _namedEntry('AllDay', {'String': []}),
            ],
          },
        },
        {
          'Product': {
            'elements': [
              _namedEntry('starts_at', {'U64': []}),
              _namedEntry('ends_at', {'U64': []}),
            ],
          },
        },
      ],
    },
    'tables': [],
    'reducers': [],
    'types': [
      _namedType('Event', _eventTypeRef),
      _namedType('EventTiming', _timingTypeRef),
      _namedType('TimedSpan', _timedSpanTypeRef),
    ],
    'views': [],
  });
}

const _sumIndex = 0;
const _spanIndex = 1;

DatabaseSchema _twoVariantsSharingPayloadSchema() {
  return DatabaseSchema.fromJson('calendardb', {
    'typespace': {
      'types': [
        {
          'Sum': {
            'variants': [
              _namedEntry('Timed', {'Ref': _spanIndex}),
              _namedEntry('Window', {'Ref': _spanIndex}),
            ],
          },
        },
        {
          'Product': {
            'elements': [
              _namedEntry('starts_at', {'U64': []}),
              _namedEntry('ends_at', {'U64': []}),
            ],
          },
        },
      ],
    },
    'tables': [],
    'reducers': [],
    'types': [
      _namedType('EventTiming', _sumIndex),
      _namedType('TimedSpan', _spanIndex),
    ],
    'views': [],
  });
}

DatabaseSchema _primitivePayloadSumSchema() {
  return DatabaseSchema.fromJson('calendardb', {
    'typespace': {
      'types': [
        {
          'Sum': {
            'variants': [
              _namedEntry('Label', {'String': []}),
              _namedEntry('Level', {'U8': []}),
            ],
          },
        },
      ],
    },
    'tables': [],
    'reducers': [],
    'types': [_namedType('EventTiming', _sumIndex)],
    'views': [],
  });
}

String _generatedFile(List<GeneratedFile> files, String filename) =>
    files.firstWhere((f) => f.filename == filename).content;

const _sdkImportPath = 'package:spacetimedb_sdk/codegen.dart';

Iterable<String> _importedPaths(String source) => _importPattern
    .allMatches(source)
    .map((match) => match.group(1))
    .whereType<String>();

final _importPattern = RegExp("import '([^']+)';");

void main() {
  group('sum variant with a named product payload', () {
    late String timing;

    setUp(() {
      timing = _generatedFile(
        DartGenerator(_timingSchema()).generateAll(),
        'event_timing.dart',
      );
    });

    test('the timed variant carries a field of the named product type', () {
      expect(timing, contains('final TimedSpan value;'));
      expect(timing, contains('const EventTimingTimed(this.value);'));
    });

    test('the timed variant decodes its payload with the named decoder', () {
      expect(
        timing,
        contains(
          'factory EventTimingTimed.decodeBsatn(BsatnDecoder decoder) '
          '{return EventTimingTimed(TimedSpan.decodeBsatn(decoder));}',
        ),
      );
    });

    test('the timed variant encodes its payload after the tag', () {
      expect(
        timing,
        contains('encoder.writeU8(0); value.encodeBsatn(encoder);'),
      );
    });

    test('the timed variant round-trips its payload through JSON', () {
      expect(
        timing,
        contains("return {'type': 'Timed', 'value': value.toJson()};"),
      );
      expect(
        timing,
        contains(
          "EventTimingTimed.fromJson(Map<String, dynamic> json) "
          "{return EventTimingTimed(TimedSpan.fromJson("
          "Map<String, dynamic>.from(json['value'] ?? {})));}",
        ),
      );
    });

    test('a string payload variant keeps its primitive codec', () {
      expect(timing, contains('final String value;'));
      expect(
        timing,
        contains(
          'factory EventTimingAllDay.decodeBsatn(BsatnDecoder decoder) '
          '{return EventTimingAllDay(decoder.readString());}',
        ),
      );
    });
  });

  group('sum file imports', () {
    test('a named product payload imports the file of its type', () {
      final timing = _generatedFile(
        DartGenerator(_timingSchema()).generateAll(),
        'event_timing.dart',
      );

      expect(timing, contains("import 'timed_span.dart';"));
    });

    test('a payload type shared by two variants is imported once', () {
      final timing = _generatedFile(
        DartGenerator(_twoVariantsSharingPayloadSchema()).generateAll(),
        'event_timing.dart',
      );

      expect(_importedPaths(timing), [_sdkImportPath, 'timed_span.dart']);
    });

    test('a sum of primitive payloads imports only the SDK', () {
      final timing = _generatedFile(
        DartGenerator(_primitivePayloadSumSchema()).generateAll(),
        'event_timing.dart',
      );

      expect(_importedPaths(timing), [_sdkImportPath]);
    });
  });
}
