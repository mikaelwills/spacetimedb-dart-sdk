// ignore_for_file: avoid_print
import 'dart:async';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_sdk/src/subscription/subscription_manager.dart';
import '../generated/note.dart';

void main() async {
  print('⚡ Cache Performance Benchmark\n');

  final connection = SpacetimeDbConnection(
    host: 'localhost:3000',
    database: 'notesdb',
  );

  final subscriptionManager = SubscriptionManager(connection);

  subscriptionManager.cache.registerDecoder<Note>('note', NoteDecoder());

  print('📡 Connecting...');
  await connection.connect();
  subscriptionManager.subscribe(['SELECT * FROM note']);
  await Future.delayed(const Duration(milliseconds: 500));

  final cache = subscriptionManager.cache.getTableByTypedName<Note>('note');
  print('✅ Loaded ${cache.count()} notes\n');

  // BENCHMARK 1: Cache queries (in-memory)
  print('🚀 CACHE BENCHMARK (100,000 iterations):');
  final cacheStart = DateTime.now();

  for (int i = 0; i < 100000; i++) {
    cache.count();
    cache.find(1);
    cache.find(2);
    for (final note in cache.iter()) {
      note.id;
    }
  }

  final cacheEnd = DateTime.now();
  final cacheDuration = cacheEnd.difference(cacheStart);
  print('   Total time: ${cacheDuration.inMilliseconds}ms');
  print(
    '   Per query: ${(cacheDuration.inMicroseconds / 100000).toStringAsFixed(2)}μs\n',
  );

  // BENCHMARK 2: Network queries (actual server round-trips)
  print('🌐 NETWORK BENCHMARK (100 queries):');
  print('   Querying server 100 times...');

  final networkStart = DateTime.now();

  for (int i = 0; i < 100; i++) {
    final completer = Completer<void>();
    late StreamSubscription sub;

    sub = subscriptionManager.onInitialSubscription.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
        sub.cancel();
      }
    });

    subscriptionManager.subscribe(['SELECT * FROM note']);
    await completer.future.timeout(const Duration(seconds: 5));
  }

  final networkEnd = DateTime.now();
  final networkDuration = networkEnd.difference(networkStart);

  print('   Total time: ${networkDuration.inMilliseconds}ms');
  print(
    '   Per query: ${(networkDuration.inMilliseconds / 100).toStringAsFixed(2)}ms\n',
  );

  // COMPARISON
  final cachePerQuery = cacheDuration.inMicroseconds / 100000;
  final networkPerQuery = networkDuration.inMilliseconds / 100;
  final speedup = (networkPerQuery * 1000) / cachePerQuery;

  print('⚡ RESULTS:');
  print('   Cache: ${cachePerQuery.toStringAsFixed(2)}μs per query');
  print('   Network: ${networkPerQuery.toStringAsFixed(2)}ms per query');
  print('   Cache is ${speedup.toStringAsFixed(0)}x FASTER!\n');

  print('💡 REAL IMPACT:');
  print('   For 100,000 queries:');
  print(
    '   - Cache: ${cacheDuration.inMilliseconds}ms (${(cacheDuration.inMilliseconds / 1000).toStringAsFixed(2)}s)',
  );
  print(
    '   - Network: ${(networkPerQuery * 100000).toStringAsFixed(0)}ms (${(networkPerQuery * 100000 / 1000 / 60).toStringAsFixed(1)} minutes!)\n',
  );

  await connection.disconnect();
  print('✅ Benchmark complete!');
}
