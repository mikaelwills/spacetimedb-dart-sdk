# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.1.1 - 2026-04-18

Packaging / docs patch. No runtime changes.

### Changed

- Bumped `brotli` constraint from `^0.5.0` to `^0.6.0` to pick up the latest stable. No API change — the SDK only calls `brotli.decode(bytes)`, which is unchanged.
- Pubspec description now mentions `SubscribeMulti`. New README "Compatibility" section explicitly calls out SpacetimeDB 2.x server support and the `SubscribeMulti` subscription protocol.

### Fixed

- Two dartdoc `INFO` lints where `Map<String, dynamic>` and `Vec<u8>` were written bare in comments (interpreted as HTML). Wrapped in backticks.

## 1.1.0 - 2026-04-17

### Added

- **`Option<T>` codegen support.** Rust tables, reducer args, and views that use `Option<T>` now generate clean nullable Dart fields (`T?`) with `writeOption` / `readOption` round-trips. Previously, any module using `Option<T>` failed codegen with "inline sum types are not supported." Matches the first-class Option handling in the Rust and TypeScript SDKs.
  - New `OptionType` IR variant. `AlgebraicType.fromJson` detects the canonical `[some(T), none]` sum shape (order-strict, lowercase names, `none` carries a unit payload) per upstream `SumType::as_option`.
  - Option-returning views detected as `ViewReturnType.option` via the new IR variant.
  - `copyWith` correctly emits `T?` (no more `String??` double-nullable) for Option fields.

### Fixed

- **`writeOption` / `readOption` BSATN wire format.** The previous implementation used a `bool` discriminant with reversed semantics (Some=1, None=0), but BSATN's canonical Option encoding uses sum-variant indices (Some=0, None=1) per `crates/sats/src/ser/impls.rs`. As a result, any server-sent `Option<T>` field decoded via `readOption` silently returned `null` for Some values. Now writes and reads u8 tags that match the wire spec; throws `SpacetimeDbProtocolException` on invalid tag.
- **`SubscriptionErrorMessage.decode` wire alignment.** Was structured around the broken `readOption` semantic and misread the `SubscriptionError` message: skipped `table_id` entirely and treated `error` as optional. Reordered to match the canonical layout (`u64 duration; Option<u32> request_id; Option<u32> query_id; Option<u32> table_id; String error`).
- **`OutOfEnergy` decode reads phantom payload.** `TransactionUpdateMessage.decode` was reading a phantom `readString()` after the OutOfEnergy status tag, misaligning subsequent fields. Per the wire definition (`crates/client-api-messages/src/websocket/v1.rs`), OutOfEnergy is a unit variant with no payload. Fixed.

### Changed (breaking — but phantom data only)

- `OutOfEnergy` (in `update_status.dart`) no longer has a `budgetInfo: String` field or a string constructor. The field only ever carried garbled bytes from the misaligned decoder — it was never a real value. Consumers constructing `OutOfEnergy('...')` must now use `OutOfEnergy()`. `TransactionResult.errorMessage` returns `'Out of energy'` instead of `'Out of energy: <info>'`. This is technically a breaking change but nobody could have written working code against the old field, so it's ordinarily listed under a minor bump rather than a major.

## 1.0.1 - 2026-04-15

Docs only. README's Quick Start install snippet and codegen command lines still referenced the pre-rename package name (`spacetimedb_dart_sdk`). Fixed to the published name (`spacetimedb_sdk`).

## 1.0.0 - 2026-04-15

First public release on pub.dev.

This version consolidates a multi-month pre-release development effort into the first stable, published API. Everything below was already in place before publication; the CHANGELOG entries exist as a reference for anyone who was tracking the SDK via git before 1.0.

### Reactive primitives

- `TableCache<T>.rows` — `ValueNotifier<List<T>>` that fires on every transaction touching the table.
- `TableCache<T>.lastBatch` — `ValueNotifier<TransactionBatch<T>?>` carrying every row change from the most recent transaction. Fires exactly once per transaction with a `List<TableEvent<T>>` (insert / update / delete subtypes).
- `TableCache<T>.rowNotifier(primaryKey)` — per-row auto-disposing `ValueNotifier<T?>` that fires only when that specific row's value changes. Scales to thousands of concurrent row-watchers at `O(rows_touched)` cost per transaction, not `O(listeners × events)`.
- `TableCache<T>.onInsert` / `onUpdate` / `onDelete` — broadcast `Stream<TableEvent<T>>` for consumers that react to one kind of change (no iteration or type-ladder needed). Fire synchronously in the same transaction as `lastBatch`.
- `TableCache<T>.subscribed` — `Future<void>` that resolves when the server delivers the initial batch for this table (including empty tables).

### Typed client

- Code generation from Rust module: tables, reducers, sum types (Rust enums → Dart sealed classes with exhaustive matching), views (`Vec<T>`, `Option<T>`, single-row).
- Reducers become typed async Dart methods returning `TransactionResult` (energy cost, server timestamp, queued/dropped status).
- Views exposed as direct accessors (`client.activeUsers`, `client.currentAdmin`).

### Optimistic updates

- `OptimisticChange.insertRow(tableCache, row)` / `updateRow` / `deleteRow` — typed helpers that extract the table name and serialize via the decoder.
- `nextOptimisticIntId()` — utility for client-side temporary primary keys.
- Pass `optimisticChanges: [...]` on any reducer call; the SDK applies the writes locally, keeps them on server-ack, or rolls them back on rejection.
- Multi-table reducer support: stage one `OptimisticChange` per table write.

### Offline storage

- `OfflineStorage` abstract class: `saveTableSnapshot` / `loadTableSnapshot`, mutation queue, per-table last-sync timestamps.
- `JsonFileStorage` — durable file-based implementation.
- `InMemoryOfflineStorage` — for tests.
- Cached reads work without a connection; writes queue while disconnected and replay in order on reconnect.
- `client.onSyncStateChanged` + `client.onMutationSyncResult` streams for sync-state UI.

### Exception handling

Sealed `SpacetimeDbException` root with seven typed subtypes (`Reducer`, `Connection`, `Auth`, `Timeout`, `Schema`, `Protocol`, `Subscription`). `on SpacetimeDbException catch (e)` covers every SDK runtime failure.

- `connect()` wraps raw `SocketException` / `HandshakeException` / `WebSocketException` into `SpacetimeDbConnectionException`.
- BSATN decode errors throw `SpacetimeDbProtocolException`.
- `SpacetimeDbAuthException` extends `SpacetimeDbConnectionException`.

### Connection

- Sealed `ConnectionState` (`Connecting` / `Connected` / `Reconnecting` / `Disconnected` / `AuthError` / `FatalError`) — `switch` exhaustively.
- `client.connection.onStateChanged` — `Stream<ConnectionState>`.
- Automatic reconnection with exponential backoff.

### Extensions

`ValueListenable<T>` extensions for common async patterns:
- `firstNonNull()` — resolve with first non-null value (current or future).
- `firstWhere(predicate)` — resolve when predicate first holds.
- `next` — resolve on next change, ignore current.
- `toStream()` — bridge to `Stream<T>` for `StreamBuilder` / rxdart interop.

### Migration from pre-1.0 consumers

The pre-1.0 package name was `spacetimedb_dart_sdk`. On publication to pub.dev the package is now `spacetimedb_sdk`. Consumers pinned to a git SHA must update their `pubspec.yaml`:

```yaml
dependencies:
  spacetimedb_sdk: ^1.0.0  # was: spacetimedb_dart_sdk (git)
```

And every import:

```dart
// before
import 'package:spacetimedb_dart_sdk/codegen.dart';

// after
import 'package:spacetimedb_sdk/codegen.dart';
```

Any code generated against the old package also needs regenerating via `dart run spacetimedb_sdk:generate`.
