import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/view_generator.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';

class ClientGenerator {
  final DatabaseSchema schema;
  late final ViewGenerator _viewGenerator;

  ClientGenerator(this.schema) {
    _viewGenerator = ViewGenerator(schema);
  }

  String generate() {
    final imports = <Directive>[
      Directive.import('dart:async'),
      Directive.import('package:spacetimedb_sdk/codegen.dart'),
      Directive.import('reducers.dart'),
    ];

    if (schema.reducers.isNotEmpty) {
      imports.add(Directive.import('reducer_args.dart'));
    }

    for (final table in schema.tables) {
      imports.add(Directive.import('${table.name}.dart'));
    }

    final lib = Library(
      (b) =>
          b
            ..directives.addAll(imports)
            ..body.add(_buildClientClass()),
    );

    return emitLibrary(
      lib,
      header:
          '// GENERATED CODE - DO NOT MODIFY BY HAND\n// ignore_for_file: avoid_print',
    );
  }

  Class _buildClientClass() {
    const clientName = 'SpacetimeDbClient';

    return Class((b) {
      b.name = clientName;

      b.fields.addAll([
        Field(
          (f) =>
              f
                ..name = 'connection'
                ..type = refer('SpacetimeDbConnection')
                ..modifier = FieldModifier.final$,
        ),
        Field(
          (f) =>
              f
                ..name = 'subscriptions'
                ..type = refer('SubscriptionManager')
                ..modifier = FieldModifier.final$,
        ),
        Field(
          (f) =>
              f
                ..name = '_authStorage'
                ..type = refer('AuthTokenStore')
                ..modifier = FieldModifier.final$,
        ),
        Field(
          (f) =>
              f
                ..name = '_ssl'
                ..type = refer('bool')
                ..modifier = FieldModifier.final$,
        ),
        Field(
          (f) =>
              f
                ..name = 'reducers'
                ..type = refer('Reducers')
                ..late = true
                ..modifier = FieldModifier.final$,
        ),
      ]);

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'reducerEmitter'
                ..type = MethodType.getter
                ..returns = refer('ReducerEmitter')
                ..body = const Code('return subscriptions.reducerEmitter;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'identity'
                ..type = MethodType.getter
                ..returns = refer('Identity?')
                ..body = const Code('return subscriptions.identity;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'address'
                ..type = MethodType.getter
                ..returns = refer('String?')
                ..body = const Code('return subscriptions.address;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'token'
                ..type = MethodType.getter
                ..returns = refer('String?')
                ..body = const Code('return connection.token;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'hasOfflineStorage'
                ..type = MethodType.getter
                ..returns = refer('bool')
                ..body = const Code('return subscriptions.hasOfflineStorage;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'syncState'
                ..type = MethodType.getter
                ..returns = refer('SyncState')
                ..body = const Code('return subscriptions.syncState;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'onSyncStateChanged'
                ..type = MethodType.getter
                ..returns = refer('Stream<SyncState>')
                ..body = const Code('return subscriptions.onSyncStateChanged;'),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'onMutationSyncResult'
                ..type = MethodType.getter
                ..returns = refer('Stream<MutationSyncResult>')
                ..body = const Code(
                  'return subscriptions.onMutationSyncResult;',
                ),
        ),
      );

      b.methods.add(
        Method(
          (m) =>
              m
                ..name = 'clearSyncErrors'
                ..returns = refer('void')
                ..body = const Code('subscriptions.clearSyncErrors();'),
        ),
      );

      _addTableGetters(b);
      _addViewGetters(b);

      b.constructors.add(_buildPrivateConstructor(clientName));
      b.methods.add(_buildCreateMethod(clientName));
      b.methods.add(_buildConnectMethod());
      b.methods.add(_buildDisconnectMethod());
      b.methods.add(_buildLogoutMethod());
      b.methods.add(_buildGetAuthUrlMethod());
      b.methods.add(_buildParseTokenMethod());
    });
  }

  void _addTableGetters(ClassBuilder b) {
    for (final table in schema.tables) {
      final tableName = toCamelCase(table.name);
      final className = toPascalCase(table.name);
      b.methods.add(
        Method(
          (m) =>
              m
                ..name = tableName
                ..type = MethodType.getter
                ..returns = refer('TableCache<$className>')
                ..body = Code(
                  "return subscriptions.cache.getTableByTypedName<$className>('${table.name}');",
                ),
        ),
      );
    }
  }

  void _addViewGetters(ClassBuilder b) {
    for (final view in schema.views) {
      final rowType = _viewGenerator.getViewRowType(view);
      if (rowType == null) continue;

      final viewName = toCamelCase(view.name);
      final pattern = _viewGenerator.getViewReturnPattern(view);

      switch (pattern) {
        case ViewReturnType.array:
        case ViewReturnType.query:
          b.methods.add(
            Method(
              (m) =>
                  m
                    ..name = viewName
                    ..type = MethodType.getter
                    ..returns = refer('TableCache<$rowType>')
                    ..body = Code(
                      "return subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');",
                    ),
            ),
          );

        case ViewReturnType.option:
          b.methods.add(
            Method(
              (m) =>
                  m
                    ..name = viewName
                    ..type = MethodType.getter
                    ..returns = refer('$rowType?')
                    ..body = Code('''
final cache = subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');
final iterator = cache.iter().iterator;
if (iterator.moveNext()) { return iterator.current; }
return null;
'''),
            ),
          );

        case ViewReturnType.single:
          b.methods.add(
            Method(
              (m) =>
                  m
                    ..name = viewName
                    ..type = MethodType.getter
                    ..returns = refer(rowType)
                    ..body = Code('''
final cache = subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');
return cache.iter().first;
'''),
            ),
          );

        case ViewReturnType.unknown:
          continue;
      }
    }
  }

  Constructor _buildPrivateConstructor(String clientName) {
    return Constructor(
      (c) =>
          c
            ..name = '_'
            ..optionalParameters.addAll([
              Parameter(
                (p) =>
                    p
                      ..name = 'connection'
                      ..named = true
                      ..required = true
                      ..toThis = true,
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'subscriptions'
                      ..named = true
                      ..required = true
                      ..toThis = true,
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'authStorage'
                      ..named = true
                      ..required = true
                      ..type = refer('AuthTokenStore'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'ssl'
                      ..named = true
                      ..required = true
                      ..type = refer('bool'),
              ),
            ])
            ..initializers.addAll([
              const Code('_authStorage = authStorage'),
              const Code('_ssl = ssl'),
            ])
            ..body = const Code(
              'reducers = Reducers(subscriptions.reducers, subscriptions.reducerEmitter);',
            ),
    );
  }

  Method _buildCreateMethod(String clientName) {
    final registerTables = StringBuffer();
    for (final table in schema.tables) {
      final className = toPascalCase(table.name);
      final eventArg = table.isEvent ? ', isEvent: true' : '';
      registerTables.writeln(
        "subscriptionManager.cache.registerDecoder<$className>('${table.name}', ${className}Decoder()$eventArg);",
      );
    }

    final registerViews = StringBuffer();
    for (final view in schema.views) {
      final rowType = _viewGenerator.getViewRowType(view);
      if (rowType != null) {
        registerViews.writeln(
          "subscriptionManager.cache.registerDecoder<$rowType>('${view.name}', ${rowType}Decoder());",
        );
      }
    }

    final registerReducers = StringBuffer();
    if (schema.reducers.isNotEmpty) {
      for (final reducer in schema.reducers) {
        final defName = '${toCamelCase(reducer.name)}Def';
        registerReducers.writeln(
          "subscriptionManager.reducerRegistry.register($defName);",
        );
      }
    }

    final body = '''
final storage = authStorage ?? InMemoryTokenStore();
final savedToken = await storage.loadToken();
final connection = SpacetimeDbConnection(
  host: host,
  database: database,
  initialToken: savedToken,
  ssl: ssl,
  config: config,
);
final subscriptionManager = SubscriptionManager(connection, offlineStorage: offlineStorage, queuePolicy: queuePolicy, retainRowsOnUnsubscribe: retainRowsOnUnsubscribe);

$registerTables
$registerViews
$registerReducers
final client = $clientName._(
  connection: connection,
  subscriptions: subscriptionManager,
  authStorage: storage,
  ssl: ssl,
);

subscriptionManager.onInitialConnection.listen((msg) async {
  await storage.saveToken(msg.token);
  connection.updateToken(msg.token);
});

if (offlineStorage != null) {
  await subscriptionManager.loadFromOfflineCache();
}

return client;
''';

    return Method(
      (m) =>
          m
            ..name = 'create'
            ..static = true
            ..modifier = MethodModifier.async
            ..returns = refer('Future<$clientName>')
            ..optionalParameters.addAll([
              Parameter(
                (p) =>
                    p
                      ..name = 'host'
                      ..named = true
                      ..required = true
                      ..type = refer('String'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'database'
                      ..named = true
                      ..required = true
                      ..type = refer('String'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'authStorage'
                      ..named = true
                      ..type = refer('AuthTokenStore?'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'offlineStorage'
                      ..named = true
                      ..type = refer('OfflineStorage?'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'queuePolicy'
                      ..named = true
                      ..defaultTo = const Code('const OfflineQueuePolicy()')
                      ..type = refer('OfflineQueuePolicy'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'retainRowsOnUnsubscribe'
                      ..named = true
                      ..defaultTo = const Code('false')
                      ..type = refer('bool'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'ssl'
                      ..named = true
                      ..defaultTo = const Code('false')
                      ..type = refer('bool'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'config'
                      ..named = true
                      ..defaultTo = const Code('const ConnectionConfig()')
                      ..type = refer('ConnectionConfig'),
              ),
            ])
            ..body = Code(body),
    );
  }

  Method _buildConnectMethod() {
    const body = '''
await connection.connect().timeout(connection.config.connectTimeout);
if (initialSubscriptions != null && initialSubscriptions.isNotEmpty) {
  await subscriptions.subscribe(initialSubscriptions).timeout(subscriptionTimeout);
}
''';

    return Method(
      (m) =>
          m
            ..name = 'connect'
            ..modifier = MethodModifier.async
            ..returns = refer('Future<void>')
            ..optionalParameters.addAll([
              Parameter(
                (p) =>
                    p
                      ..name = 'initialSubscriptions'
                      ..named = true
                      ..type = refer('List<String>?'),
              ),
              Parameter(
                (p) =>
                    p
                      ..name = 'subscriptionTimeout'
                      ..named = true
                      ..defaultTo = const Code('const Duration(seconds: 10)')
                      ..type = refer('Duration'),
              ),
            ])
            ..body = const Code(body),
    );
  }

  Method _buildDisconnectMethod() {
    return Method(
      (m) =>
          m
            ..name = 'disconnect'
            ..modifier = MethodModifier.async
            ..returns = refer('Future<void>')
            ..body = const Code('await connection.disconnect();'),
    );
  }

  Method _buildLogoutMethod() {
    return Method(
      (m) =>
          m
            ..name = 'logout'
            ..modifier = MethodModifier.async
            ..returns = refer('Future<void>')
            ..body = const Code(
              'await _authStorage.clearToken(); await connection.disconnect();',
            ),
    );
  }

  Method _buildGetAuthUrlMethod() {
    return Method(
      (m) =>
          m
            ..name = 'getAuthUrl'
            ..returns = refer('String')
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'provider'
                      ..type = refer('String'),
              ),
            )
            ..optionalParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'redirectUri'
                      ..named = true
                      ..type = refer('String?'),
              ),
            )
            ..body = const Code('''
final helper = OidcHelper(host: connection.host, database: connection.database, ssl: _ssl);
return helper.getAuthUrl(provider, redirectUri: redirectUri);
'''),
    );
  }

  Method _buildParseTokenMethod() {
    return Method(
      (m) =>
          m
            ..name = 'parseTokenFromCallback'
            ..returns = refer('String?')
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'callbackUrl'
                      ..type = refer('String'),
              ),
            )
            ..body = const Code('''
final helper = OidcHelper(host: connection.host, database: connection.database, ssl: _ssl);
return helper.parseTokenFromCallback(callbackUrl);
'''),
    );
  }
}
