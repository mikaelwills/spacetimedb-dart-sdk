import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:test/test.dart';

Map<String, dynamic> _pendingActiveDoneSum() => {
  'Sum': {
    'variants': [
      {
        'name': {'some': 'pending'},
        'algebraic_type': {
          'Product': {'elements': []},
        },
      },
      {
        'name': {'some': 'active'},
        'algebraic_type': {'U64': []},
      },
      {
        'name': {'some': 'done'},
        'algebraic_type': {
          'Product': {'elements': []},
        },
      },
    ],
  },
};

Map<String, dynamic> _column(String name, Map<String, dynamic> type) => {
  'name': {'some': name},
  'algebraic_type': type,
};

DatabaseSchema _schemaWithInlineSumColumn({
  required String columnName,
  Map<String, dynamic>? extraColumn,
}) {
  final elements = <Map<String, dynamic>>[
    _column('id', {'U32': []}),
    _column(columnName, _pendingActiveDoneSum()),
    if (extraColumn != null) extraColumn,
  ];

  return DatabaseSchema.fromJson('inlinedb', {
    'typespace': {
      'types': [
        {
          'Product': {'elements': elements},
        },
      ],
    },
    'tables': [
      {
        'name': 'widget',
        'product_type_ref': 0,
        'primary_key': [0],
      },
    ],
    'reducers': [],
    'types': [
      {
        'name': {'name': 'Widget', 'scope': []},
        'ty': 0,
        'custom_ordering': false,
      },
    ],
    'views': [],
  });
}

DatabaseSchema _schemaWithInlineSumReducerParam() {
  return DatabaseSchema.fromJson('inlinedb', {
    'typespace': {
      'types': [
        {
          'Product': {
            'elements': [
              {
                'name': {'some': 'id'},
                'algebraic_type': {'U32': []},
              },
            ],
          },
        },
      ],
    },
    'tables': [
      {
        'name': 'widget',
        'product_type_ref': 0,
        'primary_key': [0],
      },
    ],
    'reducers': [
      {
        'name': 'set_phase',
        'params': {
          'elements': [
            _column('id', {'U32': []}),
            _column('next_phase', _pendingActiveDoneSum()),
          ],
        },
      },
    ],
    'types': [
      {
        'name': {'name': 'Widget', 'scope': []},
        'ty': 0,
        'custom_ordering': false,
      },
    ],
    'views': [],
  });
}

void main() {
  group('inline sum synthesis', () {
    test('inline sum reducer param routes through the named companion', () {
      final schema = _schemaWithInlineSumReducerParam();
      final files = DartGenerator(schema).generateAll();

      final args =
          files.firstWhere((f) => f.filename == 'reducer_args.dart').content;
      final reducers =
          files.firstWhere((f) => f.filename == 'reducers.dart').content;

      expect(args, isNot(contains('UnknownType')));
      expect(args, isNot(contains('dynamic nextPhase')));
      expect(args, contains('final Next_phase nextPhase;'));
      expect(
        args,
        contains('final nextPhase = Next_phase.decodeBsatn(decoder);'),
      );
      expect(args, contains("import 'next_phase.dart';"));

      expect(reducers, isNot(contains('dynamic nextPhase')));
      expect(reducers, contains("import 'next_phase.dart';"));
      expect(reducers, contains('required Next_phase nextPhase'));

      expect(
        files.any((f) => f.filename == 'next_phase.dart'),
        isTrue,
        reason: 'expected a next_phase.dart companion',
      );
    });

    test('table with an inline sum column generates without throwing', () {
      final schema = _schemaWithInlineSumColumn(columnName: 'phase');
      final files = DartGenerator(schema).generateAll();
      final widget = files.firstWhere((f) => f.filename == 'widget.dart');
      expect(widget.content, contains('class Widget {'));
    });

    test('synthesizes a named companion sum type from the field name', () {
      final schema = _schemaWithInlineSumColumn(columnName: 'phase');
      final files = DartGenerator(schema).generateAll();

      final companion = files.where((f) => f.filename == 'phase.dart');
      expect(companion, isNotEmpty, reason: 'expected a phase.dart companion');
      final content = companion.first.content;
      expect(content, contains('sealed class Phase {'));
      expect(content, contains('class PhasePending extends Phase'));
      expect(content, contains('class PhaseActive extends Phase'));
      expect(content, contains('class PhaseDone extends Phase'));
    });

    test('column routes through the companion encode/decode', () {
      final schema = _schemaWithInlineSumColumn(columnName: 'phase');
      final files = DartGenerator(schema).generateAll();
      final widget =
          files.firstWhere((f) => f.filename == 'widget.dart').content;

      expect(widget, contains('final Phase phase;'));
      expect(widget, contains('phase.encodeBsatn(encoder);'));
      expect(widget, contains('phase: Phase.decodeBsatn(decoder)'));
      expect(widget, isNot(contains('IrSumType')));
    });

    test(
      'two structurally identical inline sums collapse to one companion',
      () {
        final schema = _schemaWithInlineSumColumn(
          columnName: 'phase',
          extraColumn: _column('stage', _pendingActiveDoneSum()),
        );

        final files = DartGenerator(schema).generateAll();
        final sumFiles = files.where(
          (f) =>
              f.content.contains('sealed class') && f.filename != 'client.dart',
        );
        expect(
          sumFiles.length,
          equals(1),
          reason: 'identical shapes should share a single companion',
        );

        final widget =
            files.firstWhere((f) => f.filename == 'widget.dart').content;
        final companionName = RegExp(
          r'final (\w+) phase;',
        ).firstMatch(widget)!.group(1);
        expect(widget, contains('final $companionName stage;'));
      },
    );
  });
}
