import 'package:spacetimedb_sdk/src/codegen/dart_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:test/test.dart';

Map<String, dynamic> _connectionIdType() => {
  'Product': {
    'elements': [
      {
        'name': {'some': '__connection_id__'},
        'algebraic_type': {'U128': []},
      },
    ],
  },
};

Map<String, dynamic> _uuidType() => {
  'Product': {
    'elements': [
      {
        'name': {'some': '__uuid__'},
        'algebraic_type': {'U128': []},
      },
    ],
  },
};

Map<String, dynamic> _optionOf(Map<String, dynamic> inner) => {
  'Sum': {
    'variants': [
      {
        'name': {'some': 'some'},
        'algebraic_type': inner,
      },
      {
        'name': {'some': 'none'},
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

DatabaseSchema _presenceSchema({
  required Map<String, dynamic> pkType,
  List<Map<String, dynamic>> extraColumns = const [],
}) {
  return DatabaseSchema.fromJson('presencedb', {
    'typespace': {
      'types': [
        {
          'Product': {
            'elements': [
              _column('key', pkType),
              _column('label', {'String': []}),
              ...extraColumns,
            ],
          },
        },
      ],
    },
    'tables': [
      {
        'name': 'presence',
        'product_type_ref': 0,
        'primary_key': [0],
      },
    ],
    'reducers': [],
    'types': [
      {
        'name': {'name': 'Presence', 'scope': []},
        'ty': 0,
        'custom_ordering': false,
      },
    ],
    'views': [],
  });
}

String _generatePresence(DatabaseSchema schema) {
  final files = DartGenerator(schema).generateAll();
  return files.firstWhere((f) => f.filename == 'presence.dart').content;
}

void main() {
  group('ConnectionId codegen', () {
    test('a ConnectionId column generates a typed field and codec calls', () {
      final source = _generatePresence(
        _presenceSchema(pkType: _connectionIdType()),
      );

      expect(source, contains('final ConnectionId key;'));
      expect(source, contains('encoder.writeConnectionId(key)'));
      expect(source, contains('decoder.readConnectionId()'));
    });

    test('no placeholder codec call reaches generated code', () {
      final source = _generatePresence(
        _presenceSchema(pkType: _connectionIdType()),
      );

      expect(source, isNot(contains('encoder.write(')));
      expect(source, isNot(contains('decoder.read()')));
      expect(source, isNot(contains('dynamic key')));
    });

    test('a ConnectionId column round-trips through generated JSON', () {
      final source = _generatePresence(
        _presenceSchema(pkType: _connectionIdType()),
      );

      expect(source, contains('key.toJson()'));
      expect(source, contains('ConnectionId.fromJson('));
      expect(
        source,
        isNot(contains("ConnectionId.fromJson(json['key'] ?? '')")),
      );
    });

    test('a nullable ConnectionId column generates null-safe JSON', () {
      final source = _generatePresence(
        _presenceSchema(
          pkType: _connectionIdType(),
          extraColumns: [_column('owner', _optionOf(_connectionIdType()))],
        ),
      );

      expect(source, contains('ConnectionId? owner'));
      expect(source, contains('owner?.toJson()'));
      expect(
        source,
        contains(
          "json['owner'] == null ? null : ConnectionId.fromJson("
          "json['owner'] as String)",
        ),
      );
      expect(source, isNot(contains('encoder.write(')));
      expect(source, isNot(contains('decoder.read()')));
    });

    test('the generated primary key getter is typed ConnectionId', () {
      final source = _generatePresence(
        _presenceSchema(pkType: _connectionIdType()),
      );

      expect(source, contains('ConnectionId? getPrimaryKey('));
      expect(source, isNot(contains('dynamic? getPrimaryKey(')));
    });
  });

  group('Uuid codegen', () {
    test('a Uuid column generates a typed field and codec calls', () {
      final source = _generatePresence(_presenceSchema(pkType: _uuidType()));

      expect(source, contains('final Uuid key;'));
      expect(source, contains('encoder.writeUuid(key)'));
      expect(source, contains('decoder.readUuid()'));
    });

    test('no placeholder codec call reaches generated code', () {
      final source = _generatePresence(_presenceSchema(pkType: _uuidType()));

      expect(source, isNot(contains('encoder.write(')));
      expect(source, isNot(contains('decoder.read()')));
      expect(source, isNot(contains('dynamic key')));
    });

    test('a Uuid column round-trips through generated JSON', () {
      final source = _generatePresence(_presenceSchema(pkType: _uuidType()));

      expect(source, contains('key.toJson()'));
      expect(source, contains('Uuid.fromJson('));
      expect(source, isNot(contains("Uuid.fromJson(json['key'] ?? '')")));
    });

    test('a nullable Uuid column generates null-safe JSON', () {
      final source = _generatePresence(
        _presenceSchema(
          pkType: _uuidType(),
          extraColumns: [_column('owner', _optionOf(_uuidType()))],
        ),
      );

      expect(source, contains('Uuid? owner'));
      expect(source, contains('owner?.toJson()'));
      expect(
        source,
        contains(
          "json['owner'] == null ? null : Uuid.fromJson("
          "json['owner'] as String)",
        ),
      );
      expect(source, isNot(contains('encoder.write(')));
      expect(source, isNot(contains('decoder.read()')));
    });

    test('the generated primary key getter is typed Uuid', () {
      final source = _generatePresence(_presenceSchema(pkType: _uuidType()));

      expect(source, contains('Uuid? getPrimaryKey('));
      expect(source, isNot(contains('dynamic? getPrimaryKey(')));
    });
  });

  group('both types in one schema', () {
    test('a table carrying both generates cleanly', () {
      final source = _generatePresence(
        _presenceSchema(
          pkType: _connectionIdType(),
          extraColumns: [_column('trace', _uuidType())],
        ),
      );

      expect(source, contains('final ConnectionId key;'));
      expect(source, contains('final Uuid trace;'));
      expect(source, contains('encoder.writeConnectionId(key)'));
      expect(source, contains('encoder.writeUuid(trace)'));
      expect(source, contains('decoder.readConnectionId()'));
      expect(source, contains('decoder.readUuid()'));
      expect(source, isNot(contains('encoder.write(')));
      expect(source, isNot(contains('decoder.read()')));
    });
  });
}
