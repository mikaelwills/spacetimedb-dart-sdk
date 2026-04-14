// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';
import 'package:test/test.dart';

import '../test/helpers/integration_test_helper.dart';
import '../test/generated/client.dart';
import '../test/generated/entity.dart';

const _configs = [
  _BenchConfig(
    'spacenotes-baseline',
    txPerSec: 10,
    rowsPerTx: 1,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1,
  ),
  _BenchConfig(
    'mid-range',
    txPerSec: 100,
    rowsPerTx: 10,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1,
  ),
  _BenchConfig(
    'mmorpg-target',
    txPerSec: 1000,
    rowsPerTx: 10,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1,
  ),
  _BenchConfig(
    'mmorpg-multi-listener',
    txPerSec: 1000,
    rowsPerTx: 10,
    tableSize: 100000,
    durationSec: 10,
    listeners: 100,
  ),
  _BenchConfig(
    'mmorpg-per-row-notifier',
    txPerSec: 1000,
    rowsPerTx: 10,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1000,
    useRowNotifier: true,
  ),
  _BenchConfig(
    'thousands-realistic',
    txPerSec: 5000,
    rowsPerTx: 20,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1,
  ),
  _BenchConfig(
    'breaking-point',
    txPerSec: 10000,
    rowsPerTx: 50,
    tableSize: 100000,
    durationSec: 10,
    listeners: 1,
  ),
];

class _BenchConfig {
  const _BenchConfig(
    this.name, {
    required this.txPerSec,
    required this.rowsPerTx,
    required this.tableSize,
    required this.durationSec,
    required this.listeners,
    this.useRowNotifier = false,
  });
  final String name;
  final int txPerSec;
  final int rowsPerTx;
  final int tableSize;
  final int durationSec;
  final int listeners;
  final bool useRowNotifier;
}

class _BenchResult {
  final _BenchConfig config;
  final int txFired;
  final int txObserved;
  final List<int> latenciesUs;
  final List<int> fanoutUs;
  final int frameBudgetMisses;
  final bool crashed;
  final String? crashError;
  final bool serverDisconnected;
  final Duration wallTime;

  _BenchResult({
    required this.config,
    required this.txFired,
    required this.txObserved,
    required this.latenciesUs,
    required this.fanoutUs,
    required this.frameBudgetMisses,
    required this.wallTime,
    this.crashed = false,
    this.crashError,
    this.serverDisconnected = false,
  });

  int get p50 => _percentile(latenciesUs, 0.50);
  int get p95 => _percentile(latenciesUs, 0.95);
  int get p99 => _percentile(latenciesUs, 0.99);
  int get fanoutP50 => _percentile(fanoutUs, 0.50);
  int get fanoutP95 => _percentile(fanoutUs, 0.95);
  int get fanoutP99 => _percentile(fanoutUs, 0.99);

  String toMarkdown() {
    final buf = StringBuffer();
    buf.writeln('### ${config.name}');
    buf.writeln(
      '- Config: N=${config.txPerSec} tx/s, K=${config.rowsPerTx} rows/tx, table=${config.tableSize}, listeners=${config.listeners}, duration=${config.durationSec}s',
    );
    buf.writeln('- Wall time: ${wallTime.inMilliseconds}ms');
    if (crashed) {
      buf.writeln('- **CRASHED:** $crashError');
      return buf.toString();
    }
    buf.writeln(
      '- Throughput: $txFired fired, $txObserved observed (${txObserved == 0 ? 0 : (txObserved * 100 / txFired).toStringAsFixed(1)}% kept up)',
    );
    buf.writeln(
      '- Per-tx latency (onMessage → lastBatch): p50=${p50}us, p95=${p95}us, p99=${p99}us',
    );
    buf.writeln(
      '- Listener fan-out (rows callback): p50=${fanoutP50}us, p95=${fanoutP95}us, p99=${fanoutP99}us',
    );
    buf.writeln('- Frame budget misses (>16ms): $frameBudgetMisses');
    if (serverDisconnected) {
      buf.writeln('- **SERVER DISCONNECTED** client during workload');
    }
    if (txFired > 0 && txObserved < txFired * 0.5) {
      buf.writeln(
        '- **BACKPRESSURE:** client fell behind (observed < 50% of fired)',
      );
    }
    return buf.toString();
  }

  static int _percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final idx = (p * (sorted.length - 1)).round();
    return sorted[idx];
  }
}

void main() {
  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.none;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  for (final config in _configs) {
    test(
      'benchmark: ${config.name}',
      () async {
        final result = await _runConfig(config);
        print(result.toMarkdown());
        _results.add(result);
      },
      timeout: Timeout(Duration(seconds: config.durationSec + 120)),
    );
  }

  tearDownAll(() async {
    if (_results.isNotEmpty) {
      await _writeResultsFile(_results);
    }
  });
}

final _results = <_BenchResult>[];

Future<_BenchResult> _runConfig(_BenchConfig config) async {
  final wallSw = Stopwatch()..start();
  try {
    final client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(
      initialSubscriptions: ['SELECT * FROM entity'],
      subscriptionTimeout: const Duration(seconds: 60),
    );

    final existingCount = client.entity.count();
    final needed = config.tableSize - existingCount;
    if (needed > 0) {
      print(
        '  Preloading $needed entities (have $existingCount, need ${config.tableSize})...',
      );
      final preloadSw = Stopwatch()..start();
      const chunkSize = 10000;
      var remaining = needed;
      while (remaining > 0) {
        final batch = remaining > chunkSize ? chunkSize : remaining;
        final done = Completer<void>();
        void onBatch() {
          if (client.entity.count() >= config.tableSize - (remaining - batch) &&
              !done.isCompleted) {
            done.complete();
          }
        }

        client.entity.rows.addListener(onBatch);
        await client.reducers.bulkInsertEntities(count: batch);
        await done.future.timeout(const Duration(seconds: 60));
        client.entity.rows.removeListener(onBatch);
        remaining -= batch;
      }
      preloadSw.stop();
      print(
        '  Preloaded to ${client.entity.count()} entities in ${preloadSw.elapsedMilliseconds}ms',
      );
    }

    final latencies = <int>[];
    final fanouts = <int>[];
    var frameBudgetMisses = 0;
    var txObserved = 0;

    var lastMessageTime = Stopwatch();
    final msgSub = client.connection.onMessage.listen((_) {
      lastMessageTime = Stopwatch()..start();
    });

    void batchListener() {
      if (lastMessageTime.isRunning) {
        latencies.add(lastMessageTime.elapsedMicroseconds);
        lastMessageTime.stop();
      }
      txObserved++;
    }

    client.entity.lastBatch.addListener(batchListener);

    final fanoutListeners = <VoidCallback>[];
    final rowNotifiersAttached = <ValueNotifier<Entity?>>[];

    if (config.useRowNotifier) {
      final entityIds =
          client.entity.iter().map((e) => e.id).take(config.listeners).toList();
      for (final id in entityIds) {
        void listener() {
          final sw = Stopwatch()..start();
          sw.stop();
          fanouts.add(sw.elapsedMicroseconds);
          if (sw.elapsedMicroseconds > 16000) {
            frameBudgetMisses++;
          }
        }

        final n = client.entity.rowNotifier(id);
        n.addListener(listener);
        fanoutListeners.add(listener);
        rowNotifiersAttached.add(n);
      }
    } else {
      for (var i = 0; i < config.listeners; i++) {
        void listener() {
          final sw = Stopwatch()..start();
          client.entity.count();
          sw.stop();
          fanouts.add(sw.elapsedMicroseconds);
          if (sw.elapsedMicroseconds > 16000) {
            frameBudgetMisses++;
          }
        }

        client.entity.rows.addListener(listener);
        fanoutListeners.add(listener);
      }
    }

    print(
      '  Running workload: N=${config.txPerSec}, K=${config.rowsPerTx}, ${config.durationSec}s...',
    );
    final txInterval = Duration(microseconds: 1000000 ~/ config.txPerSec);
    var txFired = 0;
    var seed = Int64(42);
    var disconnected = false;

    final disconnectSub = client.connection.onStateChanged.listen((state) {
      if (state is Disconnected || state is FatalError) {
        disconnected = true;
      }
    });

    final workloadDone = Completer<void>();
    final timer = Timer.periodic(txInterval, (t) {
      if (disconnected || txFired >= config.txPerSec * config.durationSec) {
        t.cancel();
        if (!workloadDone.isCompleted) workloadDone.complete();
        return;
      }
      unawaited(
        client.reducers
            .mutateRandomEntities(
              count: config.rowsPerTx,
              seed: seed,
              dropIfOffline: true,
            )
            .catchError(
              (_) => TransactionResult.dropped(
                reducerName: 'mutate_random_entities',
              ),
            ),
      );
      seed = Int64(seed.toInt() + 1);
      txFired++;
    });

    await workloadDone.future.timeout(
      Duration(seconds: config.durationSec + 30),
      onTimeout: () {
        timer.cancel();
      },
    );

    if (!disconnected) {
      await Future.delayed(const Duration(seconds: 3));
    }
    await disconnectSub.cancel();

    await msgSub.cancel();
    client.entity.lastBatch.removeListener(batchListener);
    if (config.useRowNotifier) {
      for (var i = 0; i < rowNotifiersAttached.length; i++) {
        rowNotifiersAttached[i].removeListener(fanoutListeners[i]);
      }
    } else {
      for (final l in fanoutListeners) {
        client.entity.rows.removeListener(l);
      }
    }

    try {
      await client.connection.disconnect();
    } catch (_) {}

    latencies.sort();
    fanouts.sort();
    wallSw.stop();

    if (disconnected) {
      print(
        '  Server disconnected client after $txFired tx fired, $txObserved observed',
      );
    }

    return _BenchResult(
      config: config,
      txFired: txFired,
      txObserved: txObserved,
      latenciesUs: latencies,
      fanoutUs: fanouts,
      frameBudgetMisses: frameBudgetMisses,
      serverDisconnected: disconnected,
      wallTime: wallSw.elapsed,
    );
  } catch (e, st) {
    wallSw.stop();
    print('  CRASHED: $e\n$st');
    return _BenchResult(
      config: config,
      txFired: 0,
      txObserved: 0,
      latenciesUs: [],
      fanoutUs: [],
      frameBudgetMisses: 0,
      crashed: true,
      crashError: e.toString(),
      wallTime: wallSw.elapsed,
    );
  }
}

Future<void> _writeResultsFile(List<_BenchResult> results) async {
  final now = DateTime.now();
  final dateStr =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final file = File('benchmark/results/$dateStr-baseline.md');
  final buf = StringBuffer();
  buf.writeln('# MMORPG Scale Benchmark — Baseline');
  buf.writeln();
  buf.writeln('Date: $dateStr');
  buf.writeln('SDK commit: ${await _gitHead()}');
  buf.writeln(
    'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  buf.writeln();
  buf.writeln('## Methodology');
  buf.writeln();
  buf.writeln(
    '- Client-side measurement only (SDK reactive primitives, not server)',
  );
  buf.writeln(
    '- Per-tx latency: time from onMessage (WS frame received) to lastBatch listener fire',
  );
  buf.writeln(
    '- Fan-out: time inside rows.addListener callback (includes count() call)',
  );
  buf.writeln('- Preloaded entity table to target size before each workload');
  buf.writeln('- SdkLogger.level = none, offlineStorage = null');
  buf.writeln('- Serial execution, fresh connection per config');
  buf.writeln();
  buf.writeln('## Results');
  buf.writeln();
  for (final r in results) {
    buf.writeln(r.toMarkdown());
    buf.writeln();
  }
  await file.writeAsString(buf.toString());
  print('Results written to ${file.path}');
}

Future<String> _gitHead() async {
  try {
    final result = await Process.run('git', ['rev-parse', '--short', 'HEAD']);
    return '${result.stdout}'.trim();
  } catch (_) {
    return 'unknown';
  }
}
