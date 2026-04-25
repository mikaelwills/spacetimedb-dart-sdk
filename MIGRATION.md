# Migration Guide

Step-by-step guides for moving between major versions of `spacetimedb_sdk`.

For full release notes, see [`CHANGELOG.md`](./CHANGELOG.md).

---

## 1.x → 2.0

`spacetimedb_sdk 2.0.0` is the first release targeting the SpacetimeDB **v2** WebSocket wire protocol (server 2.x). The v1 wire protocol is dropped. The SDK no longer speaks v1 at all, there is no compatibility flag, and this is a hard cut.

### Server requirements

- **SpacetimeDB 2.x server.** v2.0.0 will not connect to a v1-only server. If you operate your own SpacetimeDB host, upgrade it before bumping the SDK.
- **Compatibility direction:** v2 servers continue to accept v1 clients, so you can keep `spacetimedb_sdk 1.x` consumers running against a 2.x server while you migrate. You cannot run a 2.0.0 client against a v1-only server.

### When you should migrate

- You want correct `Option<T>` wire-format support (already on 1.x from 1.1.0+).
- You want explicit `Failed` vs `InternalError` distinction on reducer outcomes.
- You want forward-compat for typed reducer return values (`Uint8List? retValue`).
- You want `SendDroppedRows` for clean unsubscribe-with-cleanup flows.
- You want the SDK to stop pretending v1 fields like `energyConsumed` carry meaningful data; they were never populated for v2 servers anyway.

### When you should *not* migrate yet

- You depend on `client.reducers.on<Reducer>` listeners firing for *remote* writes (writes initiated by another client). v2 deliberately strips reducer metadata from non-caller broadcasts; the SDK honours this. Move that logic to row-stream listeners (`onInsert` / `onUpdate` / `onDelete`) before you bump.
- You are pinned to a v1-only SpacetimeDB server. Upgrade the server first.

---

## Breaking changes (quick reference)

- **WebSocket subprotocol.** v1: `v1.bsatn.spacetimedb`. v2: `v2.bsatn.spacetimedb`.
- **First server message.** v1: `IdentityToken`. v2: `InitialConnection`.
- **Connection callback.** v1: `onIdentityToken`. v2: `onInitialConnection`.
- **Subscription ID.** v1: server-assigned `query_id` (u32). v2: client-assigned `QuerySetId` (u32).
- **`subscribe()` return value.** v1 returned the server-assigned `query_id`; v2 returns the client-assigned `querySetId` echoed back on `SubscribeApplied`. Type signature is the same `Future<int>` either way.
- **`unsubscribe()` parameter.** v1: `queryId`. v2: `querySetId`.
- **Remote `on<Reducer>` listener.** v1 fired on every client when any client called the reducer. v2 fires only on the client that initiated the call.
- **`EventContext.event` on remote writes.** v1: `ReducerEvent` with caller metadata. v2: `UnknownTransactionEvent`.
- **`UpdateStatus` outcomes.** v1 had `Committed`, `Failed(String)`, `OutOfEnergy(String)`. v2 has `Committed`, `Failed(Uint8List errorBytes)`, `InternalError(String)`. `OutOfEnergy` is removed.
- **`TransactionResult` removed fields.** `energyConsumed`, `executionDuration`, `isLightUpdate`, `isOutOfEnergy` are gone. None had a v2 wire source.
- **Reducer return value.** v1: none (reducers were always void on the wire). v2: `Uint8List? retValue` (forward-compat; null for unit-return reducers, which is every reducer the current Rust macro will accept).

---

## Step-by-step migration

### 1. Bump the dependency

```yaml
dependencies:
  spacetimedb_sdk: ^2.0.0
```

### 2. Regenerate your client

The codegen output for 2.0.0 differs from 1.x. `on<Reducer>` listener bodies, the connection-event callback name, and a few wire-format helpers have changed. Run:

```bash
dart run spacetimedb_sdk:generate \
  --project-path path/to/your/spacetime/module \
  --output lib/generated
```

Generated code is the source of truth for the consumer-facing API; if regen produces compile errors against your hand-written code, the steps below explain what each one means.

### 3. Rename `onIdentityToken` → `onInitialConnection`

Anywhere you wired up the connection-handshake callback under v1, rename it. Field order in the message also changed (`identity, token, connectionId` → `identity, connectionId, token`), but the SDK exposes named fields, so this only matters if you were destructuring positionally.

```dart
// before (1.x)
client.onIdentityToken.listen((msg) {
  final identity = msg.identity;
  final token = msg.token;
  final connectionId = msg.connectionId;
});

// after (2.0)
client.onInitialConnection.listen((msg) {
  final identity = msg.identity;
  final connectionId = msg.connectionId;
  final token = msg.token;
});
```

### 4. Audit your `on<Reducer>` listeners

This is the single most likely source of *silent* behavioural change. v1 fired `client.reducers.onCreateNote(...)` on every client when *any* client called `create_note`. v2 only fires it for the client that initiated the call.

What to do:

- **If you were using the listener for self-confirmation** (e.g. "show a success toast after my reducer commits"), no change. The caller-side listener still fires.
- **If you were using it to react to remote writes** (e.g. "another user added a note → flash the new row"), switch to row-stream listeners:

  ```dart
  // before (1.x) -- fires for ALL clients
  client.reducers.onCreateNote((ctx, title, content) {
    if (!ctx.isMyTransaction) {
      showToast('$title added by ${ctx.event.callerConnectionId}');
    }
  });

  // after (2.0) -- fires for ALL clients, gives you the row directly
  client.note.onInsert.listen((event) {
    if (!event.context.isMyTransaction) {
      showToast('${event.row.title} added');
    }
  });
  ```

- **If you needed the *caller identity* of a remote write** (e.g. "who added this note?"), v2 doesn't carry that on broadcast frames at all. Model it as explicit data: add a `created_by` column on the table and write the caller's identity from inside the reducer, or push events into a separate audit table the reducer maintains.

### 5. Update `isMyTransaction` expectations

The method still exists with the same signature and the same return values for the same situations. The *derivation* changed. Under v1 it byte-compared `_myConnectionId` against a wire-level `callerConnectionId`. Under v2 it relies on which message type produced the `EventContext` (caller-path `ReducerResult` constructs `ReducerEvent`, broadcast-path `TransactionUpdate` constructs `UnknownTransactionEvent`).

You should not need any consumer-side change unless you were inspecting the construction details of the `EventContext`. If you have tests that pin `isMyTransaction == true` for the caller and `isMyTransaction == false` for non-callers, those still pass.

### 6. Switch on the new `UpdateStatus` outcomes

```dart
// before (1.x)
switch (result.status) {
  case Committed _: print('ok');
  case Failed(message: final m): print('reducer error: $m');
  case OutOfEnergy(budgetInfo: final b): print('out of energy: $b');
  // 1.x switch was non-exhaustive in places; some consumers used String fallback
}

// after (2.0)
switch (result.status) {
  case Committed _: print('ok');
  case Failed(errorBytes: final bytes): print('reducer error: ${result.status.errorMessage}');
  case InternalError(message: final m): print('host error: $m');
  case Pending _: print('queued (offline)');
  case Dropped _: print('dropped (fire-and-forget while offline)');
}
```

Notes:
- `Failed.errorMessage` is a `String get` over the `errorBytes` `Uint8List`. It uses `utf8.decode(..., allowMalformed: true)`. Forward-compat for future typed errors.
- `InternalError` is not the same as `Failed`. It carries a server-generated diagnostic, currently scrubbed to the literal text `"the instance encountered a fatal error."` for any panicking reducer (see "Behaviours worth knowing about" in the CHANGELOG). If you want consumers to see a specific error message, return `Err("...")` from the reducer; that goes through `Failed(Bytes)` and round-trips verbatim.
- `OutOfEnergy` is **gone**. v2's `ReducerOutcome` has no such variant. If you had a switch arm matching it, delete that arm.

### 7. Drop references to removed `TransactionResult` fields

These four fields are gone:

- `energyConsumed`
- `executionDuration`
- `isLightUpdate`
- `isOutOfEnergy`

None had a v2 wire source. If your code reads them, the analyzer will tell you. Replace with nothing; they were always populated from v1 wire fields that don't exist under v2.

### 8. Update `unsubscribe()` calls

The parameter name is now `querySetId`. If you stored the integer that `subscribe()` returned, the value type and meaning are unchanged; just rename:

```dart
// before
final queryId = await subManager.subscribe(['SELECT * FROM note']);
await subManager.unsubscribe(queryId);

// after
final querySetId = await subManager.subscribe(['SELECT * FROM note']);
await subManager.unsubscribe(querySetId);
```

If you want the server to send the rows it's about to drop (so you can fire delete events for them):

```dart
await subManager.unsubscribe(querySetId, sendDroppedRows: true);
```

Default is `false` (preserves v1 behaviour: client clears its own view, no delete events).

### 9. Stop reading reducer-call metadata on remote writes

If you had code that pulled `reducerName`, `reducerArgs`, or `callerConnectionId` from `EventContext.event` for non-caller transactions:

```dart
// before (1.x)
client.note.onInsert.listen((event) {
  final reducer = event.context.event;
  if (reducer is ReducerEvent) {
    print('inserted by ${reducer.reducerName} from ${reducer.callerConnectionId}');
  }
});
```

Under v2, `event.context.event` for non-caller writes is `UnknownTransactionEvent`. The `if (reducer is ReducerEvent)` check now silently never matches for remote writes. If you need this metadata, see step 4: model it as explicit row data, not protocol metadata.

### 10. Run your test suite

If you have integration tests that:
- Open raw WebSockets: flip the subprotocol literal `v1.bsatn.spacetimedb` to `v2.bsatn.spacetimedb`.
- Assert wire-format byte layout: re-derive against `crates/client-api-messages/src/websocket/v2.rs`. Tag values for `ServerMessage` and `ClientMessage` are completely different.
- Assert on `OutOfEnergy` status: delete those tests; the variant is gone.

For reference, the SDK's own pre-release validation suite (`test/integration/v2_*_test.dart`) demonstrates each of these patterns.

---

## Help

If you hit a migration question that isn't covered here:

- Check `CHANGELOG.md` for the per-fix detail.
- Search the [GitHub discussions](https://github.com/mikaelwills/spacetimedb-dart-sdk/discussions).
- Open a new discussion under "Q&A". Migration questions are first-class.
