# SpacetimeDB Dart SDK

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Dart](https://img.shields.io/badge/Dart-%3E%3D3.5.4-blue.svg)](https://dart.dev)

Dart SDK for SpacetimeDB with WebSocket sync, BSATN encoding, and code generation.

> ⚠️ **Pre-1.0: breaking changes expected.** This SDK is actively working toward a single, stable 1.0 release. Until then, the public API may change between commits — reducer call shapes, cache events, and the reactive primitives (`rows` / `lastBatch`) in particular are still being refined. Pin a specific commit SHA in your `pubspec.yaml` (`git: { url: ..., ref: <sha> }`) and check the CHANGELOG before upgrading.

## Features

- WebSocket connection with auto-reconnect and SSL/TLS
- Connection status monitoring and quality metrics
- BSATN binary encoding/decoding
- Client-side table cache with change streams
- Subscription management with SQL queries
- Type-safe reducer calling with results
- Code generation (tables, reducers, sum types, views)
- Authentication with OIDC and token persistence
- Transaction events with context
- Offline-first support with optimistic updates and mutation queue

## Quick Start

### 1. Install SpacetimeDB CLI

```bash
curl --proto '=https' --tlsv1.2 -sSf https://install.spacetimedb.com | sh
```

### 2. Add dependency

```yaml
dependencies:
  spacetimedb_dart_sdk:
    git: https://github.com/mikaelwills/spacetimedb_dart_sdk.git
```

### 3. Generate client code

```bash
# From running server
dart run spacetimedb_dart_sdk:generate -s http://localhost:3000 -d your_database -o lib/generated

# Or from local Rust project
dart run spacetimedb_dart_sdk:generate -p path/to/module -o lib/generated
```

### 4. Connect

```dart
import 'package:your_app/generated/client.dart';

// Create client (loads offline cache if provided, no network)
final client = await SpacetimeDbClient.create(
  host: 'localhost:3000',
  database: 'your_database',
  ssl: false,
  authStorage: InMemoryTokenStore(),
);

// Connect to server and subscribe
await client.connect(initialSubscriptions: ['SELECT * FROM users']);
```

## Tables

```dart
// Iterate
for (final user in client.users.iter()) {
  print(user.name);
}

// Count and check
print(client.users.count);
print(client.users.isEmpty);

// Reactive row list — synchronous ValueNotifier, rebuilds on any change
client.users.rows.addListener(() {
  print('Users changed: ${client.users.rows.value.length} rows');
});

// Transaction batches — every row change from one transaction, delivered once.
// A reducer that touches N rows fires lastBatch a single time with N events.
client.users.lastBatch.addListener(() {
  final batch = client.users.lastBatch.value;
  if (batch == null) return;
  for (final event in batch.events) {
    switch (event) {
      case TableInsertEvent(:final row, :final context):
        print('Added: ${row.name}');
        if (context.isMyTransaction) showToast('Created ${row.name}');
      case TableUpdateEvent(:final oldRow, :final newRow):
        print('${oldRow.name} → ${newRow.name}');
      case TableDeleteEvent(:final row):
        print('Removed: ${row.name}');
    }
  }
});
```

## Reducers

A reducer call returns a `TransactionResult` on success and throws `SpacetimeDbReducerException` on server-side failure (`Failed` / `OutOfEnergy`). Fire-and-forget is fine — ignore the result if you don't need it.

```dart
// Fire-and-forget
await client.reducers.createUser(name: 'Alice', email: 'alice@example.com');

// Use the result (energy cost, server timestamp, queued/dropped status)
try {
  final result = await client.reducers.createUser(name: 'Alice', email: 'alice@example.com');
  print('energy: ${result.energyConsumed}, duration: ${result.executionDuration}');
  if (result.isPending) print('queued offline, will sync on reconnect');
} on SpacetimeDbReducerException catch (e) {
  print('reducer failed: ${e.message}');
}

// Listen to reducer events (from any client)
client.reducers.onCreateUser((ctx, name, email) {
  print('User created: $name');
  print('By: ${ctx.callerIdentity}');
});
```

On success the result's `status` is one of:
- `Committed` — server acknowledged the mutation.
- `Pending` — offline storage is configured and the mutation is queued on disk; it will sync when the connection is restored. The eventual server ack/reject surfaces via `MutationSyncer.results` (not on this future).
- `Dropped` — the call was made with `dropIfOffline: true` while offline, so it was discarded.

`Failed` and `OutOfEnergy` never reach the return value — they are thrown as `SpacetimeDbReducerException`.

## Views

```dart
// Vec<T> view - multiple rows
for (final user in client.activeUsers.iter()) {
  print(user.name);
}

// Option<T> view - single optional row
final admin = client.currentAdmin; // User?
if (admin != null) {
  print('Admin: ${admin.name}');
}

// T view - single required row (throws if empty)
final config = client.appConfig; // Config
print(config.version);
```

## Subscriptions

```dart
// Subscribe to more queries after connect
await client.subscriptions.subscribe([
  'SELECT * FROM messages WHERE room_id = 123',
]);
```

## Sum Types (Rust Enums)

```dart
// Rust enum becomes Dart sealed class
enum Status {
    Pending,
    Active { since: u64 },
    Banned { reason: String },
}

// Pattern match with exhaustiveness checking
final message = switch (user.status) {
  StatusPending() => 'Waiting for approval',
  StatusActive(:final since) => 'Active since $since',
  StatusBanned(:final reason) => 'Banned: $reason',
};

// Construct
final status = StatusActive(DateTime.now().millisecondsSinceEpoch);
```

## Authentication

```dart
// Create with persistent storage
final client = await SpacetimeDbClient.create(
  host: 'spacetimedb.com',
  database: 'myapp',
  ssl: true,
  authStorage: YourTokenStore(), // implements AuthTokenStore
);
await client.connect();

// Access identity after connect
print(client.identity?.toHexString);  // Full 32-byte hex
print(client.identity?.toAbbreviated); // "2ab4...9f1c"
print(client.address);
print(client.token);

// OAuth flow
final authUrl = client.getAuthUrl('google', redirectUri: 'myapp://callback');
// Open authUrl in browser, then handle callback:
final token = client.parseTokenFromCallback(callbackUrl);

// Logout
await client.logout();
```

## Connection Status

```dart
client.connection.onStateChanged.listen((state) {
  switch (state) {
    case Connecting(): showSpinner();
    case Connected(): hideSpinner();
    case Reconnecting(): showBanner();
    case Disconnected(): showError();
    case AuthError(): showLogin();
    case FatalError(:final message): showRetry(message);
  }
});
```

## SSL

```dart
ssl: false  // Development: ws://, http://
ssl: true   // Production: wss://, https://
```

## Offline Support

```dart
final client = await SpacetimeDbClient.create(
  host: 'localhost:3000',
  database: 'myapp',
  offlineStorage: JsonFileStorage(basePath: '/path/to/cache'),
);
// Offline cache is already loaded — read data immediately
print('Loaded ${client.notes.count} cached notes');

// Connect when ready — errors propagate, you decide how to handle them
try {
  await client.connect(initialSubscriptions: ['SELECT * FROM note']);
} catch (e) {
  print('Offline mode: $e');
}
```

Storage options: `JsonFileStorage` (file-based), `InMemoryOfflineStorage` (testing), or implement `OfflineStorage` interface for custom backends.

### Optimistic Updates

```dart
// Insert with immediate UI update
await client.reducers.createNote(
  id: uuid.v4(), // Client-side IDs required for optimistic inserts
  title: 'New Note',
  optimisticChanges: [OptimisticChange.insert('note', note.toJson())],
);

// Update/delete
optimisticChanges: [OptimisticChange.update('note', oldRow.toJson(), newRow.toJson())]
optimisticChanges: [OptimisticChange.delete('note', row.toJson())]
```

### Sync State

```dart
print(client.syncState.pendingCount);  // Queued mutations
client.onSyncStateChanged.listen((state) => showSyncIndicator(state.hasPending));
client.onMutationSyncResult.listen((r) => r.success ? null : showError(r.error));
```

Offline behavior: cached data loads instantly, mutations queue locally, optimistic changes update UI, queued mutations replay on reconnect, failed mutations roll back.

## Testing

```bash
dart test
```

See [TESTING.md](TESTING.md) for details.

## License

Apache 2.0
