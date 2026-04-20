// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:math';
import 'package:spacetimedb_sdk/codegen.dart';
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

  noteTable.lastBatch.addListener(() {
    final batch = noteTable.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableInsertEvent<Note>) {
        print("📝 New Note: ${event.row}");
      } else if (event is TableUpdateEvent<Note>) {
        print(
          '✏️  Note Updated "${event.oldRow.title}" -> "${event.newRow.title}"',
        );
      }
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

  subscriptionManager.onInitialConnection.listen((message) {
    print('✅ Initial Connection received!');
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

  subscriptionManager.onSubscribeApplied.listen((message) {
    print('✅ SubscribeApplied received!');
    print('   Request ID: ${message.requestId}');
    print('   QuerySet ID: ${message.querySetId}');
    print('   Tables: ${message.rows.tables.length}\n');

    for (final single in message.rows.tables) {
      print('   📊 Table: ${single.tableName}');
      print('      Rows: ${single.rows.rowsData.length} bytes');
    }

    if (!initialDataReceived.isCompleted) initialDataReceived.complete();
  });

  subscriptionManager.onTransactionUpdate.listen((message) {
    print('🔄 TransactionUpdate: ${message.querySets.length} querySets');
    for (final qs in message.querySets) {
      for (final tableUpdate in qs.tables) {
        print(
          '   Table ${tableUpdate.tableName}: ${tableUpdate.rows.length} row-groups',
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
