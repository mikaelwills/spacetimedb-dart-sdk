// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:math';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() async {
  await ensureTestEnvironment();
  print('🚀 Starting live SpacetimeDB integration test...\n');

  final env = await createTestEnv();
  final connection = env.connection;
  final subscriptionManager = env.subManager;

  final noteTable = subscriptionManager.cache.getTableByTypedName<Note>('note');

  noteTable.lastEvent.addListener(() {
    final event = noteTable.lastEvent.value;
    if (event is TableInsertEvent<Note>) {
      print("📝 New Note: ${event.row}");
    } else if (event is TableUpdateEvent<Note>) {
      print(
        '✏️  Note Updated "${event.oldRow.title}" -> "${event.newRow.title}"',
      );
    }
  });

  connection.onError.listen((error) {
    print('❌ Connection error: $error');
  });

  connection.onStateChanged.listen((state) {
    print('🔄 Connection state: ${state.displayName}');
  });

  var identityReceived = Completer<void>();
  var initialDataReceived = Completer<void>();

  subscriptionManager.onIdentityToken.listen((message) {
    print('✅ Identity Token received!');
    print(
      '   Identity: ${message.identity.sublist(0, 8)}... (${message.identity.length} bytes)',
    );
    print(
      '   Token: ${message.token.substring(0, min(20, message.token.length))}...',
    );
    print(
      '   Connection ID: ${message.connectionId.sublist(0, 8)}... (${message.connectionId.length} bytes)\n',
    );
    identityReceived.complete();
  });

  subscriptionManager.onInitialSubscription.listen((message) {
    print('✅ Initial Subscription received!');
    print('   Request ID: ${message.requestId}');
    print('   Execution time: ${message.totalHostExecutionDurationMicros}μs');
    print('   Tables: ${message.tableUpdates.length}\n');

    for (final tableUpdate in message.tableUpdates) {
      print('   📊 Table: ${tableUpdate.tableName}');
      print('      Table ID: ${tableUpdate.tableId}');
      print('      Num rows: ${tableUpdate.numRows}');
      print('      Updates: ${tableUpdate.updates.length}');

      for (final update in tableUpdate.updates) {
        print(
          '         - Inserts: ${update.update.inserts.rowsData.length} bytes',
        );
        print(
          '         - Deletes: ${update.update.deletes.rowsData.length} bytes',
        );
      }
      print('');
    }

    initialDataReceived.complete();
  });

  subscriptionManager.onTransactionUpdate.listen((message) {
    print('🔄 Transaction Update received!');
    print('   Timestamp: ${message.timestamp}');
    print('   Transaction offset: ${message.transactionOffset}');

    for (final tableUpdate in message.tableUpdates) {
      print('   Table ${tableUpdate.tableName} changed:');
      for (final update in tableUpdate.updates) {
        print(
          '      - Inserts: ${update.update.inserts.rowsData.length} bytes',
        );
        print(
          '      - Deletes: ${update.update.deletes.rowsData.length} bytes',
        );
      }
    }
    print('');
  });

  print('📡 Connecting to SpacetimeDB...');
  await connection.connect();
  print('✅ Connected!\n');

  print('⏳ Waiting for identity token...');
  await identityReceived.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      print('❌ Timeout waiting for identity token');
      throw TimeoutException('No identity token received');
    },
  );

  print('📝 Subscribing to Note table...');
  subscriptionManager.subscribe(['SELECT * FROM note']);
  print('✅ Subscription sent!\n');

  await Future.delayed(const Duration(milliseconds: 100));

  print('⏳ Waiting for initial data...');
  await initialDataReceived.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      print('❌ Timeout waiting for initial data');
      print(
        '   This likely means the server rejected the subscription or sent a different message type.',
      );
      throw TimeoutException('No initial data received');
    },
  );

  print('\n📚 Cached notes:');
  for (final note in noteTable.iter()) {
    print('   - $note');
  }
  print('   Total: ${noteTable.count()} notes');

  print('✅ All tests passed!');
  print('\n🎉 Integration test complete!');

  await Future.delayed(const Duration(seconds: 1));
  subscriptionManager.dispose();
  await connection.disconnect();
}
