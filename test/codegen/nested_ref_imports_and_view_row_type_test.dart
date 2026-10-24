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

Map<String, dynamic> _option(Map<String, dynamic> inner) => {
  'Sum': {
    'variants': [
      {
        'name': {'some': 'some'},
        'algebraic_type': inner,
      },
      {
        'name': {'some': 'none'},
        'algebraic_type': _product([]),
      },
    ],
  },
};

DatabaseSchema _mismatchedStructSchema(String structName) {
  return DatabaseSchema.fromJson('persondb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
        ]),
        _product([
          _field('id', {'U32': []}),
          _field('owner', {'Ref': 0}),
          _field('owners', {
            'Array': {'Ref': 0},
          }),
          _field('maybe', _option({'Ref': 0})),
        ]),
        _product([
          _field('row', {'Ref': 0}),
          _field('rows', {
            'Array': {'Ref': 0},
          }),
        ]),
      ],
    },
    'tables': [_table('person', 0), _table('holder', 1)],
    'reducers': [
      {
        'name': 'add',
        'params': {
          'elements': [
            _field('row', {'Ref': 0}),
            _field('rows', {
              'Array': {'Ref': 0},
            }),
            _field('maybe', _option({'Ref': 0})),
          ],
        },
      },
    ],
    'types': [
      _typeDef(structName, 0),
      _typeDef('Holder', 1),
      _typeDef('Wrapper', 2),
    ],
    'views': [],
  });
}

DatabaseSchema _nestedOnlySchema() {
  return DatabaseSchema.fromJson('persondb', {
    'typespace': {
      'types': [
        _product([
          _field('id', {'U32': []}),
        ]),
        _product([
          _field('id', {'U32': []}),
          _field('owners', {
            'Array': {'Ref': 0},
          }),
        ]),
        _product([
          _field('maybe', _option({'Ref': 0})),
        ]),
      ],
    },
    'tables': [_table('person', 0), _table('holder', 1)],
    'reducers': [],
    'types': [
      _typeDef('Person', 0),
      _typeDef('Holder', 1),
      _typeDef('Wrapper', 2),
    ],
    'views': [],
  });
}

DatabaseSchema _recursiveSchema() {
  return DatabaseSchema.fromJson('treedb', {
    'typespace': {
      'types': [
        _product([
          _field('name', {'String': []}),
          _field('children', {
            'Array': {'Ref': 0},
          }),
        ]),
        _product([
          _field('id', {'U32': []}),
          _field('kids', {
            'Array': {'Ref': 1},
          }),
          _field('parent', _option({'Ref': 1})),
        ]),
      ],
    },
    'tables': [_table('node', 1)],
    'reducers': [],
    'types': [_typeDef('TreeNode', 0), _typeDef('NodeRow', 1)],
    'views': [],
  });
}

void main() {
  group('ref to a table-backed struct named differently from its table', () {
    for (final structName in ['PersonRow', 'Person']) {
      test('struct $structName resolves to the person table class', () {
        final files =
            DartGenerator(_mismatchedStructSchema(structName)).generateAll();
        final byName = {for (final f in files) f.filename: f.content};

        for (final file in files) {
          expect(
            file.content,
            isNot(contains('PersonRow')),
            reason: file.filename,
          );
          expect(
            file.content,
            isNot(contains('person_row.dart')),
            reason: file.filename,
          );
        }

        for (final name in [
          'reducers.dart',
          'reducer_args.dart',
          'holder.dart',
          'wrapper.dart',
        ]) {
          final content = byName[name]!;
          expect(
            "import 'person.dart';".allMatches(content).length,
            equals(1),
            reason: name,
          );
          expect(content, contains('List<Person>'), reason: name);
        }

        for (final name in [
          'reducer_args.dart',
          'holder.dart',
          'wrapper.dart',
        ]) {
          expect(byName[name], contains('Person.decodeBsatn'), reason: name);
        }

        for (final name in [
          'reducers.dart',
          'reducer_args.dart',
          'holder.dart',
        ]) {
          expect(byName[name], contains('Person?'), reason: name);
        }
      });
    }

    test('Vec/Option-only refs in columns and struct fields are imported', () {
      final files = DartGenerator(_nestedOnlySchema()).generateAll();
      final byName = {for (final f in files) f.filename: f.content};

      expect(byName['holder.dart'], contains('List<Person>'));
      expect(byName['holder.dart'], contains("import 'person.dart';"));
      expect(byName['wrapper.dart'], contains('Person?'));
      expect(byName['wrapper.dart'], contains("import 'person.dart';"));
    });

    test('a recursive struct or table does not import its own file', () {
      final files = DartGenerator(_recursiveSchema()).generateAll();
      final byName = {for (final f in files) f.filename: f.content};

      expect(byName['tree_node.dart'], contains('List<TreeNode>'));
      expect(byName['tree_node.dart'], isNot(contains("'tree_node.dart'")));
      expect(byName['node.dart'], contains('List<Node>'));
      expect(byName['node.dart'], contains('Node?'));
      expect(byName['node.dart'], isNot(contains("'node.dart'")));
    });
  });

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
