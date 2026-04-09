# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

