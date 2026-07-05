# SpacetimeDB Dart SDK

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Dart](https://img.shields.io/badge/Dart-%3E%3D3.5.4-blue.svg)](https://dart.dev)

> **Not to be confused with [`spacetimedb`](https://pub.dev/packages/spacetimedb) on pub.dev**, an early fork of this sdk that was published prematurely and this `spacetimedb_sdk` has significantly progressed since then.

[SpacetimeDB](https://spacetimedb.com) is a database that replaces your backend: you write Rust reducers instead of API endpoints, and every client gets a live, synced view of the data. This SDK makes that data feel native to Flutter: every table is a `ValueNotifier`, reducers are typed function calls, and opt-in offline storage keeps the whole cache on disk with optimistic writes that queue and sync when you reconnect.

## Compatibility

Works with SpacetimeDB 2.x servers (tested against 2.4.1). Negotiates the `v3.bsatn.spacetimedb` WebSocket subprotocol on 2.2.0+ servers and transparently falls back to `v2.bsatn.spacetimedb` on older 2.x servers. Uses client-assigned `QuerySetId` subscriptions, typed reducer return values, server-defined views, and BSATN binary wire format. If you need to connect to a v1-only server, use `spacetimedb_sdk 1.x`.

Built for collaborative editors, real-time games, multi-device sync, presence, chat.

## What you get

- **Your backend is a Rust function.** Write a reducer, call it from Dart like a typed async method. No REST layer, no GraphQL schema, no handler boilerplate. `await client.reducers.createOrder(itemId: 1)` and you're done.
- **Every table updates itself.** No fetch-then-poll, no cache invalidation logic. Listen to `client.notes.rows` and your UI re-renders when *anyone on any client* makes a change. One WebSocket handles the whole app.
- **UI that feels local, syncs like a server.** Optimistic writes apply to your cache instantly: list re-sorts, widget rebuilds, user sees it. When the server confirms, nothing happens. If it rejects, the SDK rolls back automatically.
- **Watch one row, not the whole table.** `rowNotifier(playerId)` fires only when *that* row changes. 1000 on-screen entities each watching their own row cost `O(rows_touched)` per transaction, not `O(listeners × events)`.
- **Collaborative editing primitives built in.** `event.context.isMyTransaction` tells you whether you caused a change or someone else did. `isOptimistic` tells you if it's local-only or confirmed. Skip your own echoes, merge other users' writes, no CRDT library required.
- **Reactive primitives that match intent.** `ValueNotifier` for held state (`rows`, `lastBatch`, `rowNotifier`), `Stream` for transient events (`onInsert`, `onUpdate`, `onDelete`). One catches "what's there now," the other catches "what just happened."
- **Auto-reconnect that's part of the API, not an afterthought.** The SDK reconnects on drops, re-subscribes, re-queues. `client.connection.onStateChanged` is a sealed type (`Connecting` / `Reconnecting` / `FatalError`) so your banner logic is one switch statement — and `client.subscriptions.subscriptionsReady` tells you when the re-subscribe has actually landed, so your "connected" indicator never lies.
- **Offline-first when you want it.** Flip on `JsonFileStorage` and cached reads work airplane-mode, writes queue locally, replay on reconnect. No separate offline SDK, no conflict resolution; the optimistic model handles it.
- **One catch block for every SDK error.** `on SpacetimeDbException catch (e)` covers reducer failures, connection drops, timeouts, protocol errors, everything. Narrow to specific subtypes only when you need to.
- **Types flow through the whole stack.** Rust `struct` becomes a Dart class. Rust `enum` becomes a sealed class with exhaustive `switch`. Rust `Vec<u64>` becomes `List<Int64>`. Refactor a column in Rust, Dart compiler points at every call site.

## Quick Start

### 1. Install SpacetimeDB CLI

```bash
curl --proto '=https' --tlsv1.2 -sSf https://install.spacetimedb.com | sh
```

### 2. Add the dependency

```yaml
dependencies:
  spacetimedb_sdk: ^2.2.0
```

### 3. Generate client code from your module

```bash
# From a running server
dart run spacetimedb_sdk:generate -s http://localhost:3000 -d your_database -o lib/generated

# Or from a local Rust project
dart run spacetimedb_sdk:generate -p path/to/module -o lib/generated
```

### 4. Connect

```dart
import 'package:your_app/generated/client.dart';

final client = await SpacetimeDbClient.create(
  host: 'localhost:3000',
  database: 'your_database',
  ssl: false,
  authStorage: InMemoryTokenStore(),
);

await client.connect(initialSubscriptions: ['SELECT * FROM users']);
```

That's it. `client.users.rows.value` is now a live list that updates on every server transaction.

## Concepts

Before the API reference, a short tour of the pieces that matter.

### Client lifecycle: create, then connect

`SpacetimeDbClient.create()` is synchronous-ish: it loads your offline cache from disk (if configured), wires up listeners, and returns immediately. **No network happens here.**

`client.connect()` opens the WebSocket, authenticates, and requests your initial subscriptions. It can throw. Offline-first apps call `create`, render cached data, then call `connect` inside a try/catch and show an offline indicator on failure.

```dart
final client = await SpacetimeDbClient.create(host: '...', database: '...');
// cache is already loaded; you can read right now
print(client.notes.count());

try {
  await client.connect(initialSubscriptions: ['SELECT * FROM note']);
} catch (e) {
  // offline-only mode; writes queue for later
}
```

### Tables and the cache

Every table in your generated client is a `TableCache<T>`. The cache holds the current rows locally, fires events on every change, and is the home for all the reactive primitives: `rows`, `lastBatch`, `rowNotifier(pk)`, `onInsert`, `onUpdate`, `onDelete`.

You never construct a `TableCache` yourself; codegen does it. You just read: `client.note`, `client.user`, `client.entity`.

### The primitive rule: ValueNotifier vs Stream

The SDK exposes reactive data in two shapes, and they're not interchangeable:

- **`ValueNotifier<T>`** for *held state*. Has a current value you can read anytime (`rows.value`, `lastBatch.value`, `rowNotifier(pk).value`). Late subscribers immediately see the current value on read. Use this to render "what's there right now."
- **`Stream<Event>`** for *transient events*. No current value, only the moment something happened (`onInsert`, `onUpdate`, `onDelete`). Late subscribers miss past events. Use this to react to changes ("ding on new message", "animate a delete").

If you're asking "what are the current rows?", that's state, use the notifier. If you're asking "react once when this happens", that's an event, use the stream.

### Transactions and EventContext

Every change to a table happens inside a transaction. A reducer that touches 10 rows produces one transaction with 10 events, and every `TableCache` fires `lastBatch` exactly once with the 10 events.

The `EventContext` attached to every event tells you who caused it:

- `context.isMyTransaction`: this client initiated the change.
- `context.isOptimistic`: this is a local optimistic change, not yet server-confirmed.
- `context.event`: the `ReducerEvent` with caller identity, reducer name, timestamp, and status (only populated on the caller side under v2).

Collaborative editors use this to skip their own local echoes and only react to confirmed external changes.

### Offline and optimistic updates

Two opt-in systems work together to make a Flutter app with SpacetimeDB feel local while being collaborative:

- **Offline storage** persists table snapshots and queues reducer calls while disconnected. See [Offline storage](#offline-storage).
- **Optimistic updates** apply a reducer's intended row writes to the local cache *before* the server confirms, so the UI updates instantly. See [Optimistic updates](#optimistic-updates).

You can use either alone. Offline storage without optimism gives you cached reads plus queued writes. Optimism without offline storage gives you instant UI feedback online.

## Tables

```dart
// Iterate the current rows
for (final user in client.users.iter()) {
  print(user.name);
}

// Size
print(client.users.count());

// Look up by primary key
final user = client.users.find(userId);
```

### Reactive row list

`rows` is a `ValueNotifier<List<T>>` that fires on every transaction touching the table. Use it when a UI renders the whole list (or a sorted/filtered view of it).

```dart
client.users.rows.addListener(() {
  print('Users changed: ${client.users.rows.value.length} rows');
});
```

### Transaction batches

`lastBatch` is a `ValueNotifier<TransactionBatch<T>?>` carrying every event from the most recent transaction. Useful when you need to know what changed, not just the current state.

```dart
client.users.lastBatch.addListener(() {
  final batch = client.users.lastBatch.value;
  if (batch == null) return;
  for (final event in batch.events) {
    switch (event) {
      case TableInsertEvent(:final row, :final context):
        if (context.isMyTransaction) showToast('Created ${row.name}');
      case TableUpdateEvent(:final oldRow, :final newRow):
        print('${oldRow.name} -> ${newRow.name}');
      case TableDeleteEvent(:final row):
        print('Removed: ${row.name}');
    }
  }
});
```

### Watching individual rows

For UIs that follow a single row (a chat message, player entity, selected item), use `rowNotifier(primaryKey)`. It only fires when that specific row's value changes. 1000 entity-watchers at game scale drops from `O(listeners * rows_touched)` to `O(rows_touched)` per transaction.

```dart
final entity = client.entity.rowNotifier(entityId);

entity.addListener(() {
  if (entity.value == null) print('deleted');
  else print('hp: ${entity.value!.health}');
});
```

**Semantics:**
- Fires when the row's value changes per `==`. A server touch that doesn't change any field is de-duplicated.
- `value` is `null` when the row is absent (never inserted, or deleted).
- Cached per primary key: repeated calls with the same key return the same instance.
- Auto-disposes when the last listener detaches; a subsequent call returns a fresh instance.
- Only valid on tables with a declared primary key.

### Delta streams

For consumers that react to one kind of change, every `TableCache<T>` exposes per-type streams. Cleaner than iterating `lastBatch.value.events` and type-checking each one.

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
- Broadcast: multiple subscribers each receive every event.
- Synchronous: fires during the transaction, before `lastBatch` fires. Inside an `onInsert` listener, `rows.value` already reflects the new state.
- No replay: late subscribers do not see past events.

### Waiting for initial data

`TableCache.subscribed` is a `Future<void>` that resolves when the server delivers the first batch for this table (including empty tables). Use it when a screen needs to wait for a specific table before rendering.

```dart
await client.notes.subscribed;
print('notes ready: ${client.notes.rows.value.length}');

await client.folders.subscribed;  // resolves even if empty
```

Completes exactly once; stays completed across reconnects. If the server rejects the subscription (invalid table name, etc.) it throws `SpacetimeDbSubscriptionException`.

## Reducers

A reducer call returns a `TransactionResult` on success and throws `SpacetimeDbReducerException` on server-side failure. Fire-and-forget is fine; ignore the result if you don't need it.

```dart
// Fire-and-forget
await client.reducers.createUser(name: 'Alice', email: 'alice@example.com');

// Use the result (server timestamp, queued/dropped status, optional retValue)
try {
  final result = await client.reducers.createUser(name: 'Alice', email: 'alice@example.com');
  print('committed at: ${result.timestamp}');
  if (result.isPending) print('queued offline, will sync on reconnect');
} on SpacetimeDbReducerException catch (e) {
  print('reducer failed: ${e.message}');
}

// Listen to your own reducer calls
client.reducers.onCreateUser((ctx, name, email) {
  // Fires on the client that initiated the call. Useful for self-confirmation
  // (e.g. show a toast after your own commit). To react to remote writes,
  // listen to the table row streams (onInsert / onUpdate / onDelete) instead.
});
```

**Result status** on success is one of:
- `Committed`: server acknowledged the mutation.
- `Pending`: offline storage is configured and the mutation is queued; it syncs when the connection is restored. The eventual server ack/reject surfaces via `client.onMutationSyncResult` (not the original future).
- `Dropped`: the call was made with `dropIfOffline: true` while offline, so it was discarded.

`Failed` (your reducer returned `Err(...)`) and `InternalError` (the host hit a fault, e.g. a panic) never reach the return value. Both throw `SpacetimeDbReducerException`. Inspect `e.result.status` to tell them apart.

### Reducer event listeners are caller-only

Generated `client.reducers.on<Reducer>(...)` listeners fire **only on the client that initiated the call**. The v2 wire protocol deliberately does not broadcast reducer-call metadata (caller identity, args, reducer name) to non-callers. To react to writes from any client, listen to the table's row streams (`client.<table>.onInsert` / `onUpdate` / `onDelete`); the row data carries the full delta and is what most code wants anyway. If you genuinely need to know which connection performed a write, model it as explicit data: a `created_by` column or a separate audit-log table the reducer writes.

## Subscriptions

Multiple queries batch into a single subscription set, delivered atomically. Each call to `subscribe()` creates one subscription set with a client-assigned `QuerySetId`.

```dart
// Subscribe to more queries after connect
await client.subscriptions.subscribe([
  'SELECT * FROM messages WHERE room_id = 123',
  'SELECT * FROM presence WHERE room_id = 123',
]);
```

The client will immediately receive the initial batch plus every subsequent transaction matching the queries. Use `await client.messages.subscribed` to wait for that initial batch.

## Views

Server-side views expose pre-computed / filtered data without a subscription query. The generated client gives you a direct accessor.

```dart
// Vec<T> view: multiple rows
for (final user in client.activeUsers.iter()) {
  print(user.name);
}

// Option<T> view: single optional row
final admin = client.currentAdmin; // User?
if (admin != null) print('Admin: ${admin.name}');

// T view: single required row (throws if empty)
final config = client.appConfig;
print(config.version);
```

Use views when the filter is fixed server-side. Use subscriptions when the filter varies per client or changes at runtime.

## Error handling

Every SDK runtime error extends the sealed `SpacetimeDbException`. One catch block covers them all:

```dart
try {
  await client.reducers.riskyOperation();
} on SpacetimeDbException catch (e) {
  print('SDK error: ${e.message}');
}
```

The subtypes let you narrow when you care:

- `SpacetimeDbReducerException`: the server rejected a reducer (`Failed` from an explicit `Err(...)` return, or `InternalError` from a host-side fault like a panic). Inspect `e.result.status` to tell them apart.
- `SpacetimeDbConnectionException`: transport failure (socket, WebSocket, handshake).
- `SpacetimeDbAuthException`: auth-related connection failure (extends `SpacetimeDbConnectionException`).
- `SpacetimeDbTimeoutException`: an SDK-imposed timeout fired.
- `SpacetimeDbSchemaException`: generated-client / server schema mismatch.
- `SpacetimeDbProtocolException`: BSATN decode or message-shape error.
- `SpacetimeDbSubscriptionException`: server rejected a subscription query.

## Recipes

Copy-paste patterns for the common things.

### Watch one row in a Flutter widget

```dart
ValueListenableBuilder<Entity?>(
  valueListenable: client.entity.rowNotifier(entityId),
  builder: (context, entity, _) {
    if (entity == null) return const SizedBox.shrink();
    return Text('HP: ${entity.health}');
  },
);
```

Only rebuilds when *that specific entity* changes. 1000 entity widgets on screen, each with its own `rowNotifier`, do O(1) work per widget per transaction.

### Bridge SDK ValueListenables to Riverpod

Riverpod providers need a small helper to subscribe to the SDK's `ValueListenable`s:

```dart
T watchListenable<T>(Ref ref, ValueListenable<T> listenable) {
  void listener() => ref.invalidateSelf();
  listenable.addListener(listener);
  ref.onDispose(() => listenable.removeListener(listener));
  return listenable.value;
}

// In a provider:
final currentUserProvider = Provider<User?>((ref) {
  return watchListenable(ref, client.currentUser);
});
```

Works with any `ValueListenable` the SDK exposes: `rows`, `lastBatch`, `rowNotifier`, views, connection state.

### Optimistic insert with a client-side temp ID

```dart
final tempId = nextOptimisticIntId();  // negative int; won't collide with server IDs

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
```

The temp row appears in `client.note.rows` immediately. When the server confirms, the SDK matches by primary key and replaces the temp row with the server row. On rejection, the temp row is removed.

**Caveat:** server-assigned auto-increment IDs don't work with optimism: the temp row and the server row end up as duplicates since they have different PKs. Pick client-side IDs (`nextOptimisticIntId()` for ints, `Uuid().v4()` for strings) or design the reducer to accept a caller-provided ID.

### React only to confirmed external changes (collaborative editor pattern)

When another user edits a document, you want to merge their change. When *you* just typed something, you don't want to clobber your own buffer.

```dart
client.note.lastBatch.addListener(() {
  final batch = client.note.lastBatch.value;
  if (batch == null) return;

  for (final event in batch.events) {
    if (event.context.isMyTransaction) continue;   // skip local echo
    if (event.context.isOptimistic) continue;      // still in-flight

    // This is a confirmed external change. Safe to merge.
    if (event is TableUpdateEvent<Note> && event.newRow.id == currentNoteId) {
      mergeRemoteContent(event.newRow.body);
    }
  }
});
```

### Graceful offline startup

```dart
final client = await SpacetimeDbClient.create(
  host: 'api.example.com',
  database: 'myapp',
  offlineStorage: JsonFileStorage(basePath: '/path/to/cache'),
);

// Cached reads work immediately; no network needed
renderFromCache(client.notes.iter().toList());

try {
  await client.connect(initialSubscriptions: ['SELECT * FROM note']);
  hideOfflineBanner();
} on SpacetimeDbException catch (_) {
  showOfflineBanner();
  // Writes still work; they queue locally and replay on reconnect.
}
```

### Wait until a specific table has loaded

```dart
await client.connect(initialSubscriptions: ['SELECT * FROM note']);
await client.notes.subscribed;  // resolves when the initial batch has landed

// Safe to render; you know the server has delivered its first response for this table.
renderNotes(client.notes.rows.value);
```

Works for empty tables too (resolves with an empty list).

### Bridge a ValueListenable to Stream for StreamBuilder / rxdart

```dart
StreamBuilder<User?>(
  stream: client.currentUser.toStream(),
  builder: (ctx, snap) => Text(snap.data?.name ?? 'loading'),
);
```

`.toStream()` is one of four reactive extensions the SDK ships. See [Reactive helpers](#reactive-helpers).

## Reactive helpers

Everything reactive in the SDK (`rows`, `lastBatch`, `rowNotifier`, views) is a `ValueListenable<T>`. Four extensions cover the common async patterns:

```dart
// Resolves with the first non-null value (current or future)
final user = await client.currentUser.firstNonNull();

// Resolves when a predicate first holds
await someListenable.firstWhere((v) => v != null && v.isValid);

// Resolves on the next change (ignores current value)
await player.positionNotifier.next;
runTween(player.positionNotifier.value);

// Bridge to Stream<T>
StreamBuilder<User?>(
  stream: client.currentUser.toStream(),
  builder: (ctx, snap) => ...,
);
```

All four clean up their listeners automatically on resolve, error, or stream cancel.

## Connection status

`client.connection.onStateChanged` is a `Stream<ConnectionState>`. The state is a sealed type, use `switch`.

```dart
client.connection.onStateChanged.listen((state) {
  switch (state) {
    case Connecting(): showSpinner();
    case Connected(): hideSpinner();
    case Reconnecting(): showBanner('Reconnecting...');
    case Disconnected(): showError();
    case AuthError(): showLogin();
    case FatalError(:final message): showRetry(message);
  }
});
```

For "resolve when connected" use `await client.connection.onStateChanged.firstWhere((s) => s is Connected)`.

### Connected is not the same as usable

`Connected` means the WebSocket is open — it does **not** mean your subscriptions have been applied and your cache is populated. On a reconnect there is a window where the socket is back but the SDK is still re-subscribing your query sets; reads are stale and reducer calls made in this window can time out because the server hasn't re-registered your subscriptions yet. This is the classic false-positive: a "connected" indicator that lies, and a send that fails while everything looks green.

`client.subscriptions.subscriptionsReady` closes that gap. It's a `ValueListenable<bool>` that is `true` only when the socket is open **and** every active query set has had its `SubscribeApplied` fully applied to the cache. It latches back to `false` the instant the socket drops or a reconnect begins re-subscribing, and returns to `true` when the re-subscribe completes.

```dart
// A connection pill that only goes green when the connection is genuinely usable.
ValueListenableBuilder<bool>(
  valueListenable: client.subscriptions.subscriptionsReady,
  builder: (context, ready, _) {
    return StreamBuilder<ConnectionState>(
      stream: client.connection.onStateChanged,
      initialData: client.connection.state,
      builder: (context, snap) {
        final connected = snap.data is Connected;
        final color = (connected && ready)
            ? Colors.blue        // socket open AND subscriptions applied — safe to send
            : connected
                ? Colors.amber   // socket open but re-subscribe still in flight
                : Colors.red;    // disconnected
        return Icon(Icons.circle, color: color);
      },
    );
  },
);
```

Gate anything that must reach the server on `subscriptionsReady`, not on `Connected`. `await client.subscriptions.subscriptionsReady.firstWhere((v) => v)` (via the [reactive helpers](#reactive-helpers)) resolves once the connection is truly ready to use.

## Authentication

```dart
final client = await SpacetimeDbClient.create(
  host: 'spacetimedb.com',
  database: 'myapp',
  ssl: true,
  authStorage: YourTokenStore(), // implements AuthTokenStore
);
await client.connect();

// Identity after connect
print(client.identity?.toHexString);   // full 32-byte hex
print(client.identity?.toAbbreviated); // "2ab4...9f1c"
print(client.address);
print(client.token);

// OAuth flow
final authUrl = client.getAuthUrl('google', redirectUri: 'myapp://callback');
// Open authUrl, handle callback:
final token = client.parseTokenFromCallback(callbackUrl);

await client.logout();
```

`YourTokenStore` is any class implementing `AuthTokenStore`. For mobile use `flutter_secure_storage`, for web use `SharedPreferences`, for tests use the built-in `InMemoryTokenStore`.

## SSL

```dart
ssl: false  // Development: ws://, http://
ssl: true   // Production: wss://, https://
```

## Offline storage

Pass an `OfflineStorage` implementation to `create()` to opt into disk-backed caching and a local mutation queue:

```dart
final client = await SpacetimeDbClient.create(
  host: '...',
  database: 'myapp',
  offlineStorage: JsonFileStorage(basePath: '/path/to/cache'),
);
```

When offline storage is configured:
- Cached table snapshots load during `create()`, so reads work without network.
- Reducer calls while disconnected return `TransactionResult.pending` and queue on disk.
- On reconnect, queued mutations replay in order. Failed mutations roll back (including their optimistic changes).

### The `OfflineStorage` interface

`OfflineStorage` is an abstract class. Implement it once for your platform's storage backend (SQLite, Hive, IndexedDB, file system, whatever) and the SDK calls into it at the right moments:

```dart
abstract class OfflineStorage {
  Future<void> initialize();
  Future<void> dispose();

  // Snapshots: one entry per registered table. Persist whole rows as JSON maps
  // so they can be rehydrated without the generated decoder.
  Future<void> saveTableSnapshot(String tableName, List<Map<String, dynamic>> rows);
  Future<List<Map<String, dynamic>>?> loadTableSnapshot(String tableName);
  Future<void> clearTableSnapshot(String tableName);

  // Mutation queue: reducer calls made while offline live here until reconnect.
  Future<void> enqueueMutation(PendingMutation mutation);
  Future<List<PendingMutation>> getPendingMutations();
  Future<void> dequeueMutation(String requestId);
  Future<void> clearMutationQueue();

  // Per-table last-sync timestamps so the SDK can skip unchanged tables on reload.
  Future<void> setLastSyncTime(String tableName, DateTime time);
  Future<DateTime?> getLastSyncTime(String tableName);

  Future<void> clearAll();
}
```

Two implementations ship in the box:

- **`JsonFileStorage(basePath: '/path/to/cache')`**: durable across restarts. Writes one JSON file per table plus one for the mutation queue. Use this for production mobile/desktop apps; pair `basePath` with `path_provider`'s `getApplicationDocumentsDirectory()`.
- **`InMemoryOfflineStorage()`**: lives for the lifetime of the process. Use this in tests and in-memory smoke runs.

Implement the interface yourself to plug in SQLite, Hive, IndexedDB (for Flutter Web), or any other backend your app already uses.

### Optimistic updates

Writes while *online* still feel instant if you pass an `optimisticChanges` list to the reducer call. The SDK applies the described row writes to the local cache immediately (your UI re-renders), then keeps them if the server confirms or rolls them back if the server rejects.

Each entry describes one row write the reducer is expected to produce. A reducer that writes to 4 tables needs 4 entries.

The typed-row helpers (`insertRow`, `updateRow`, `deleteRow`) extract the table name and serialize via the decoder. No hand-typed table names, no loose maps:

```dart
// Insert: provide the row (with a client-side temp ID if the server assigns
// the real ID; see the Recipes section)
await client.reducers.createNote(
  title: 'New Note',
  optimisticChanges: [
    OptimisticChange.insertRow(client.note, newNote),
  ],
);

// Update: provide old and new rows
await client.reducers.updateNote(
  noteId: note.id,
  title: 'Renamed',
  optimisticChanges: [
    OptimisticChange.updateRow(client.note, oldNote, newNote),
  ],
);

// Delete: provide the row being removed
await client.reducers.deleteNote(
  noteId: note.id,
  optimisticChanges: [
    OptimisticChange.deleteRow(client.note, note),
  ],
);
```

For multi-table reducers, stage one entry per table write:

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

The raw `OptimisticChange.insert(tableName, Map<String, dynamic>)` / `update` / `delete` constructors stay available for cases where the decoder can't serialize the row (e.g. you're constructing a hand-crafted map in a test).

### Sync state

```dart
print(client.syncState.pendingCount);            // mutations queued locally
client.onSyncStateChanged.listen((state) =>
    showSyncIndicator(state.hasPending));
client.onMutationSyncResult.listen((r) =>
    r.success ? null : showError(r.error));
```

Use `onSyncStateChanged` for UI indicators ("3 writes pending"). Use `onMutationSyncResult` for per-mutation ack/reject feedback, especially for reducers that returned `Pending` earlier.

## Sum types (Rust enums)

Rust enums become sealed Dart classes with exhaustiveness checking:

```dart
// Rust:
//   enum Status { Pending, Active { since: u64 }, Banned { reason: String } }

final message = switch (user.status) {
  StatusPending() => 'Waiting for approval',
  StatusActive(:final since) => 'Active since $since',
  StatusBanned(:final reason) => 'Banned: $reason',
};

// Construct
final status = StatusActive(DateTime.now().millisecondsSinceEpoch);
```

## Testing

```bash
dart test
```

See [TESTING.md](TESTING.md) for integration test setup against a local SpacetimeDB server.

## License

Apache 2.0
