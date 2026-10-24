import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

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

Map<String, dynamic> _view(String name, int index, int ref) => {
  'name': name,
  'index': index,
  'is_public': true,
  'is_anonymous': false,
  'params': {'elements': []},
  'return_type': {
    'Array': {'Ref': ref},
  },
};

DatabaseSchema _schema({required bool reversed}) {
  List<T> order<T>(List<T> items) => reversed ? items.reversed.toList() : items;
  return DatabaseSchema.fromJson('orderdb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
        ]),
        _product([
          _field('name', {'String': []}),
        ]),
        _product([
          _field('score', {'I64': []}),
        ]),
      ],
    },
    'tables': order([
      _table('alpha', 0),
      _table('beta', 1),
      _table('gamma', 2),
    ]),
    'reducers': [],
    'types': [_typeDef('Alpha', 0), _typeDef('Beta', 1), _typeDef('Gamma', 2)],
    'views': order([_view('all_alpha', 0, 0), _view('all_gamma', 1, 2)]),
  });
}

Map<String, String> _generate(DatabaseSchema schema) => {
  for (final file in DartGenerator(schema).generateAll())
    file.filename: file.content,
};

void main() {
  test('output does not depend on the order tables and views arrive in', () {
    final forward = _generate(_schema(reversed: false));
    final backward = _generate(_schema(reversed: true));

    expect(backward.keys.toSet(), equals(forward.keys.toSet()));
    for (final name in forward.keys) {
      expect(backward[name], equals(forward[name]), reason: name);
    }
  });
}
