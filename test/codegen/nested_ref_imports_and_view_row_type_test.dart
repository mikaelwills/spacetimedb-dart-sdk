import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/view_generator.dart';
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

DatabaseSchema _reducerSchema() {
  return DatabaseSchema.fromJson('seeddb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
        ]),
        _product([
          _field('path', {'String': []}),
        ]),
      ],
    },
    'tables': [_table('widget', 0)],
    'reducers': [
      {
        'name': 'seed_files',
        'params': {
          'elements': [
            _field('into_public', {'Bool': []}),
            _field('rows', {
              'Array': {'Ref': 1},
            }),
          ],
        },
      },
      {
        'name': 'maybe_seed',
        'params': {
          'elements': [
            _field('row', {
              'Sum': {
                'variants': [
                  {
                    'name': {'some': 'some'},
                    'algebraic_type': {'Ref': 1},
                  },
                  {
                    'name': {'some': 'none'},
                    'algebraic_type': _product([]),
                  },
                ],
              },
            }),
          ],
        },
      },
    ],
    'types': [_typeDef('Widget', 0), _typeDef('SeedFile', 1)],
    'views': [],
  });
}

DatabaseSchema _sharedStructViewSchema(List<String> tableOrder) {
  return DatabaseSchema.fromJson('folderdb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
          _field('name', {'String': []}),
        ]),
      ],
    },
    'tables': [for (final name in tableOrder) _table(name, 0)],
    'reducers': [],
    'types': [_typeDef('Folder', 0)],
    'views': [
      {
        'name': 'my_folders',
        'index': 0,
        'is_public': true,
        'is_anonymous': false,
        'params': {'elements': []},
        'return_type': {
          'Array': {'Ref': 0},
        },
      },
    ],
  });
}

void main() {
  group('reducer params with a ref nested in Array/Option', () {
    final files = DartGenerator(_reducerSchema()).generateAll();
    final reducers =
        files.firstWhere((f) => f.filename == 'reducers.dart').content;
    final args =
        files.firstWhere((f) => f.filename == 'reducer_args.dart').content;

    test('reducers.dart imports the nested ref companion once', () {
      expect(reducers, contains('List<SeedFile>'));
      expect("import 'seed_file.dart';".allMatches(reducers).length, equals(1));
    });

    test('reducer_args.dart imports the nested ref companion once', () {
      expect(args, contains('SeedFile.decodeBsatn'));
      expect("import 'seed_file.dart';".allMatches(args).length, equals(1));
    });
  });

  group('view row type for a struct backing several tables', () {
    for (final order in [
      ['folder', 'pub_folder'],
      ['pub_folder', 'folder'],
    ]) {
      test('resolves to the struct-named table for order $order', () {
        final schema = _sharedStructViewSchema(order);
        final view = schema.views.single;
        expect(ViewGenerator(schema).getViewRowType(view), equals('Folder'));
      });
    }

    for (final order in [
      ['pub_b', 'pub_a'],
      ['pub_a', 'pub_b'],
    ]) {
      test('falls back to the smallest table name for order $order', () {
        final schema = _sharedStructViewSchema(order);
        final view = schema.views.single;
        expect(ViewGenerator(schema).getViewRowType(view), equals('PubA'));
      });
    }
  });
}
