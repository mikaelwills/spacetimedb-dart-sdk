# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (Breaking)

- Unified exception hierarchy under sealed `SpacetimeDbException` root.
  Consumers can now write `on SpacetimeDbException catch (e)` once to cover
  every SDK-originated runtime failure, and `switch` over the sealed root
  for exhaustive analyzer coverage.
- Renamed exceptions:
  - `ReducerException` → `SpacetimeDbReducerException`
  - `ConnectionException` → `SpacetimeDbConnectionException`
  - `SchemaParseException` → `SpacetimeDbSchemaException`
  - SDK-imposed reducer-call timeouts now throw `SpacetimeDbTimeoutException`
    instead of `dart:async` `TimeoutException`. Note: this is a taxonomy
    change — the new type does not extend `TimeoutException`. Existing
    `on TimeoutException` catches around reducer calls must migrate.
- `SpacetimeDbAuthException` now extends `SpacetimeDbConnectionException`
  (auth failure is a connection-failure subtype).
- `connect()` now wraps raw transport errors (`SocketException`,
  `HandshakeException`, `WebSocketException`) into
  `SpacetimeDbConnectionException` instead of rethrowing. Consumers no
  longer need to import `dart:io` / `web_socket_channel` to catch
  connect-time failures.
- BSATN decoder now throws `SpacetimeDbProtocolException` for wire-protocol
  decode failures (buffer underflow, invalid bool tag) instead of
  `StateError` / `FormatException`.

## [0.1.0] - 2024-11-21

### Added

#### Core Features
- WebSocket connection management with automatic reconnection
- Connection state tracking and quality metrics
- SSL/TLS support with configurable certificates
- Brotli compression support for messages

#### BSATN Codec
- Complete BSATN binary encoding/decoding implementation
- Support for all SpacetimeDB types (integers, floats, strings, arrays, maps)
- Type-safe encoding with bounds checking

#### Table Cache
- Client-side table caching with automatic synchronization
- Row decoder system for typed table access
- Streaming updates for table changes (inserts, updates, deletes)

#### Reducers
- Type-safe reducer calling system
- Event-driven reducer responses
- Transaction support with commit tracking

#### Code Generation
- CLI tool for generating Dart client code from SpacetimeDB schemas
- Table class generation with typed fields
- Reducer method generation
- Sum type (Rust enum) support with sealed Dart classes
- View support (Vec, Option, single-row)

#### Authentication
- Identity and token management
- OIDC authentication support
- Pluggable token storage (in-memory and persistent)

#### Events
- Event stream system for real-time updates
- Transaction events with energy tracking
- Error event handling

### Infrastructure
- Comprehensive test suite (170+ tests)
- Unit and integration test separation
- Automated test environment setup

## [1.0.0] - 2026-04-09

### Breaking Changes

#### Replaced Stream API with ValueNotifier reactive primitives
- Removed all 8 `StreamController`s and their public stream getters from `TableCache`: `insertStream`, `deleteStream`, `updateStream`, `changeStream`, `insertEventStream`, `updateEventStream`, `deleteEventStream`, `eventStream`
- Removed convenience filter streams: `insertsFromReducers`, `myInserts`, `eventsFromReducers`, `myEvents`
- Removed `TableUpdate<T>`, `TableChange<T>`, and `ChangeType` types
- Added `ValueNotifier<List<T>> rows` — synchronous reactive row list, notifies on any insert/update/delete
- Added `ValueNotifier<TableEvent<T>?> lastEvent` — synchronous event detail with full `EventContext`
- All notifications are synchronous (same microtask), replacing the async Stream dispatch

#### Migration guide
- `table.insertStream.listen(cb)` → `table.lastEvent.addListener(() { if (table.lastEvent.value is TableInsertEvent<T>) cb(...) })`
- `table.rows.addListener(cb)` for "anything changed" (replaces subscribing to all 3 streams)
- `stream.firstWhere(condition)` → `Completer` + `lastEvent.addListener` pattern
- `TableUpdate` → use `TableUpdateEvent` from `lastEvent.value`
- Framework adapters (Riverpod, Bloc) can consume `ValueNotifier` natively

## [Unreleased]

### Breaking Changes

#### Replaced per-row `lastEvent` with transaction-aware `lastBatch`
- Removed `ValueNotifier<TableEvent<T>?> lastEvent` from `TableCache`
- Removed per-row emit methods: `emitInsert`, `emitUpdate`, `emitDelete`
- Added `ValueNotifier<TransactionBatch<T>?> lastBatch` — fires exactly once per transaction with all row changes from that transaction as a `List<TableEvent<T>>`
- Added `TransactionBatch<T>` type with `events`, `inserts`, `updates`, `deletes` accessors and the shared `EventContext`
- Added `TableEventKind` enum + `TableEventSpec` data type for building batches across type-erased boundaries
- Added `TableCache.emitBatch(List<TableEventSpec>, EventContext)` — the cache constructs typed `TableEvent<T>` internally from untyped specs
- Events inside a batch are ordered: inserts, then deletes, then updates
- `_emitChanges` now collects all row changes, refreshes `rows`, then fires `lastBatch` exactly once (was: wrote `lastEvent.value` up to N times per transaction)
- `OptimisticStateManager` now flushes one `lastBatch` per affected table per apply, not one per row

#### Migration guide
- `table.lastEvent.addListener(cb)` → `table.lastBatch.addListener(cb)`
- Inside the listener: iterate `batch.events` instead of inspecting a single event:
  ```dart
  table.lastBatch.addListener(() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      switch (event) {
        case TableInsertEvent(:final row): ...
        case TableUpdateEvent(:final oldRow, :final newRow): ...
        case TableDeleteEvent(:final row): ...
      }
    }
  });
  ```
- `table.rows` is unchanged — still fires once per transaction, same semantics

### Why
The server delivers transactions as atomic units. `lastEvent` fired once per row, causing N Flutter rebuilds for an N-row transaction and quietly lying about the unit of delivery. `lastBatch` reflects the server's delivery model: one transaction, one notification, full row change list.

