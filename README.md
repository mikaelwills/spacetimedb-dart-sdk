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

### Watching individual rows

For UIs that follow a single row (chat message, player entity, selected item), use `rowNotifier(primaryKey)` instead of listening to `rows` and filtering. The notifier only fires when that specific row's value changes — 1000 entity-watchers at game scale drops from `O(listeners × rows_touched)` to `O(rows_touched)` per transaction.

```dart
final entity = client.entity.rowNotifier(entityId);

// Riverpod / Flutter consumers
final hp = watchListenable(ref, entity).value?.health ?? 0;

// Plain Flutter
entity.addListener(() {
  if (entity.value == null) print('deleted');
  else print('hp: ${entity.value!.health}');
});
```

**Semantics:**
- Fires when the row's value changes per `==`. A server touch that doesn't change any field is de-duplicated.
- `value` is `null` when the row is absent (never inserted, or deleted).
- The notifier is cached per primary key — repeated calls with the same key return the same instance.
- Auto-disposes when the last listener detaches; a subsequent `rowNotifier(pk)` call returns a fresh instance.
- Only valid on tables with a declared primary key.

### Delta streams

For consumers that react to one kind of change (insert OR update OR delete), every `TableCache<T>` exposes per-type streams. Cleaner than iterating `lastBatch.value.events` and type-checking each one.

```dart
client.chat.onInsert.listen((e) {
  playDingSound();
  showToast(e.row.text);
});

client.entity.onDelete.listen((e) => spawnDeathParticle(e.row.x, e.row.y));

client.player.onUpdate.where((e) => e.newRow.health < e.oldRow.health).listen(
  (e) => flashDamageOverlay(),
);
```

**Semantics:**
- Broadcast — multiple subscribers each receive every event.
- Synchronous — fires during the transaction, before `lastBatch` fires. Inside an `onInsert` listener, `rows.value` already reflects the new state.
- No replay — late subscribers don't see past events. If you need "the current state," use `rows` or `lastBatch`.

**The primitive rule:** `ValueNotifier` for held state you can read anytime (`rows`, `lastBatch`, `rowNotifier(pk)`). `Stream` for transient events with no "current" to hold (`onInsert`, `onUpdate`, `onDelete`).

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

### Waiting for initial data per table

Every `TableCache` exposes a `subscribed` Future that resolves when the server has delivered the initial batch for that table — including empty tables. Useful for showing a loading spinner until a specific table is ready.

```dart
await client.connect(initialSubscriptions: [
  'SELECT * FROM notes',
  'SELECT * FROM folders',
]);

await client.notes.subscribed;
print('notes ready: ${client.notes.rows.value.length}');

await client.folders.subscribed;  // resolves even if empty
print('folders ready: ${client.folders.rows.value.length}');
```

The future completes exactly once and stays completed across reconnects. If the server rejects the subscription (e.g. the table name is invalid), it throws `SpacetimeDbSubscriptionException`:

```dart
try {
  await client.notes.subscribed;
} on SpacetimeDbSubscriptionException catch (e) {
  print('subscription rejected: ${e.message}');
}
```

## Reactive Helpers

Everything reactive in the SDK (`rows`, `lastBatch`, views) is a `ValueListenable<T>`. Four extension methods cover the common async patterns without boilerplate:

```dart
// Resolves with the first non-null value (current or future)
final user = await client.currentUser.firstNonNull();

// Resolves when a predicate first holds
await client.connection.stateNotifier
    .firstWhere((s) => s is Connected);

// Resolves on the next change (ignores current value)
await player.positionNotifier.next;
runTween(player.positionNotifier.value);

// Bridge to Stream<T> for rxdart / StreamBuilder / bloc interop
StreamBuilder<User?>(
  stream: client.currentUser.toStream(),
  builder: (ctx, snap) => ...,
);
```

All four clean up their listeners automatically on resolve or cancel.

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

Pass a list of `OptimisticChange` entries to any reducer call. Each entry describes one row write the reducer will produce (a reducer that writes 4 tables needs 4 entries). The SDK applies them to the local cache immediately, then keeps them on server-ack or rolls them back on failure.

The typed-row helpers (`insertRow`, `updateRow`, `deleteRow`) extract the table name and serialize via the decoder — no hand-typed map, no stringly-typed table name:

```dart
final tempId = nextOptimisticIntId();  // client-side temp PK

await client.reducers.createNote(
  title: 'New Note',
  body: 'body',
  optimisticChanges: [
    OptimisticChange.insertRow(
      client.note,
      Note(id: tempId, title: 'New Note', body: 'body', createdAt: DateTime.now()),
    ),
  ],
);

// Update — supply old and new rows
optimisticChanges: [OptimisticChange.updateRow(client.note, oldNote, newNote)]

// Delete — supply the row being removed
optimisticChanges: [OptimisticChange.deleteRow(client.note, row)]
```

For multi-table reducers, stage one `OptimisticChange` per table write:

```dart
await client.reducers.createOrder(
  itemId: 1,
  optimisticChanges: [
    OptimisticChange.insertRow(client.order, placeholderOrder),
    OptimisticChange.insertRow(client.orderLine, placeholderLine),
    OptimisticChange.insertRow(client.inventoryDelta, placeholderDelta),
    OptimisticChange.insertRow(client.auditLog, placeholderAudit),
  ],
);
```

**ID generation:** optimistic inserts require a client-side temporary primary key. Use `nextOptimisticIntId()` for integer PKs or `Uuid().v4()` for string PKs. Server-assigned auto-increment IDs don't work with optimism — the temp row and the server row end up as duplicates.

The raw `OptimisticChange.insert/update/delete(tableName, Map<String, dynamic>)` constructors remain available when you need to hand-craft the row shape (e.g. the decoder doesn't implement `toJson`, or you're testing).

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
