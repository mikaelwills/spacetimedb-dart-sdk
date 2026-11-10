import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

Map<String, dynamic> _param(String name, Map<String, dynamic> type) => {
  'name': {'some': name},
  'algebraic_type': type,
};

Map<String, dynamic> _procedure(
  String name,
  List<Map<String, dynamic>> params,
  Map<String, dynamic> returnType,
) => {
  'source_name': name,
  'params': {'elements': params},
  'return_type': returnType,
  'visibility': {'ClientCallable': []},
};

Map<String, dynamic> _schemaJson({
  List<Map<String, dynamic>> procedures = const [],
  List<Map<String, dynamic>> miscExports = const [],
}) => {
  'typespace': {'types': []},
  'tables': [],
  'reducers': [],
  'types': [],
  'views': [],
  'misc_exports': miscExports,
  'procedures': procedures,
};

String _squash(String code) => code.replaceAll(RegExp(r'\s+'), '');

Map<String, String> _generate(Map<String, dynamic> json) {
  final schema = DatabaseSchema.fromJson('db', json);
  return {
    for (final file in DartGenerator(schema).generateAll())
      file.filename: _squash(file.content),
  };
}

Matcher _has(String code) => contains(_squash(code));

void main() {
  group('procedure codegen', () {
    test('emits a typed method per procedure on Procedures', () {
      final files = _generate(
        _schemaJson(
          procedures: [
            _procedure(
              'add_numbers',
              [
                _param('a', {'U32': []}),
                _param('b', {'U32': []}),
              ],
              {'U32': []},
            ),
            _procedure('return_nothing', [], {
              'Product': {'elements': []},
            }),
          ],
        ),
      );

      final procedures = files['procedures.dart']!;
      expect(
        procedures,
        _has(
          'Future<int> addNumbers({required int a, required int b, Duration? timeout',
        ),
      );
      expect(procedures, _has('encoder.writeU32(a);'));
      expect(procedures, _has('encoder.writeU32(b);'));
      expect(procedures, _has("'add_numbers'"));
      expect(procedures, _has('(decoder) => decoder.readU32()'));
      expect(procedures, _has('Future<void> returnNothing({Duration? timeout'));
      expect(procedures, _has('(_) {}'));

      final client = files['client.dart']!;
      expect(client, _has("import 'procedures.dart';"));
      expect(client, _has('late final Procedures procedures;'));
      expect(
        client,
        _has('procedures = Procedures(subscriptions.procedures);'),
      );
    });

    test('an inline sum return type becomes a generated type', () {
      final files = _generate(
        _schemaJson(
          procedures: [
            _procedure(
              'try_divide',
              [
                _param('n', {'U32': []}),
              ],
              {
                'Sum': {
                  'variants': [
                    {
                      'name': {'some': 'ok'},
                      'algebraic_type': {'U32': []},
                    },
                    {
                      'name': {'some': 'err'},
                      'algebraic_type': {'String': []},
                    },
                  ],
                },
              },
            ),
          ],
        ),
      );

      final procedures = files['procedures.dart']!;
      final returnType = RegExp(r'Future<(\w+)>tryDivide')
          .firstMatch(procedures)!
          .group(1)!;
      expect(procedures, _has('$returnType.decodeBsatn(decoder)'));
      expect(
        files.values.where((c) => c.contains('class$returnType')),
        isNotEmpty,
      );
    });

    test('reads procedures from V9 misc exports', () {
      final schema = DatabaseSchema.fromJson(
        'db',
        _schemaJson(
          miscExports: [
            {
              'Procedure': {
                'name': 'ping',
                'params': {'elements': []},
                'return_type': {'String': []},
              },
            },
          ],
        ),
      );

      expect(schema.procedures.single.name, 'ping');
    });

    test('a module without procedures gets no procedures field', () {
      final files = _generate(_schemaJson());

      expect(files.containsKey('procedures.dart'), isFalse);
      expect(files['client.dart'], isNot(contains('Procedures')));
    });
  });
}
