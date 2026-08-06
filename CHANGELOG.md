# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **`SpacetimeDbConnection.setKeepAliveWorkInFlight(bool)`.** Tells the app-level keep-alive monitor that a long server-side operation is in flight, so a silent inbound stream is not mistaken for a dead socket. A no-op when the app-level monitor is not running, so behaviour is unchanged for consumers who have not opted into `appLevelKeepAlive`.

### Fixed

- **The keep-alive monitor no longer declares a live connection dead during a long subscription assemble.** A subscription snapshot arrives as a single inbound frame, so while the server assembles one there is zero inbound traffic to re-arm the idle timer on — a connection that is provably alive was indistinguishable from a dead one and got torn down mid-hydration, restarting the hydration from scratch and self-perpetuating. `SubscriptionManager` now asserts the in-flight signal for as long as any query set is awaiting its `SubscribeApplied`, and clears it on the force-completion path so a dropped connection cannot latch it on.

  Detection is **deferred, not disabled**: the monitor keeps probing on its normal cadence, and after `KeepAliveMonitor.maxDeferredPings` (3) consecutive unanswered pings the connection is declared dead regardless. Any inbound frame resets the budget, so the allowance is spent per silent gap rather than accumulating across a multi-query-set resubscribe. With a 10s/5s configuration this bounds the deferral at ~45s; with the 30s/5s defaults, ~105s.

## 2.4.0 - 2026-07-31

Offline-queue durability fixes plus concurrent reconnect resubscribe. A paused mutation queue could sit idle for a full backoff interval (up to 60s) with work still queued, and reported itself as idle while doing so. Minor bump: `SyncStatus` gains a variant, which is breaking for exhaustive switches.

### Breaking

- **`SyncStatus` has a new variant, `waitingToRetry`.** An exhaustive `switch` over `SyncStatus` in consumer code will no longer compile until the new case is handled. A `SyncState` now reports `waitingToRetry` (not `idle`) whenever the queue has pending work and a retry timer is armed. Consumers treating `status != syncing` as "nothing in flight" should read `hasPending` or the new `isWaitingToRetry` instead.

### Added

- **`SyncState.nextRetryAt`.** The wall-clock time the armed retry will fire, so a consumer can render "retrying in Ns" rather than a spinner that appears stuck. Null when no retry is armed. `copyWith` takes `clearNextRetryAt: true` to unset it.
- **`SyncState.isWaitingToRetry`** convenience getter, alongside the existing `isIdle` / `isSyncing`.
- **Ownership-gain wake.** When a mutation is held in the queue waiting for the server to take ownership of a row it inserted, the sync cycle now resumes as soon as that ownership actually arrives, instead of waiting out the backoff timer. `TableCache.applyServerDelta` gained an optional `onOwnershipGained` callback (source-compatible; existing callers are unaffected) and the subscription layer wires it for transaction-update and reducer-result deltas. The retry timer remains as a backstop.

### Fixed

- **Dropped sync wakeup while a cycle was in flight.** A resume trigger arriving during an active sync cycle was silently discarded by the in-progress guard, leaving the queue parked until the next timer fire. Triggers are now latched and a follow-up cycle runs, coalescing a burst into one follow-up.
- **Interleaved sync cycles over one queue.** The in-progress flag cleared before the cycle's finalize step had finished its storage read, so a trigger landing in that window started a second concurrent cycle. Same mutation could be sent more than once, burning abort-recheck budget and backoff-ladder positions twice.
- **Sync state reported `idle` with work still queued.** A paused queue with an armed retry timer was indistinguishable from an empty one, so consumer indicators stayed visible but stopped moving. See the breaking note above.
- **Subscribe waiter clobbered on resubscribe.** `subscribe()` issued while disconnected parked a waiter that a later reconnect-resubscribe overwrote, so the original future never completed — a consumer awaiting it hung indefinitely and the query set was retained forever. The parked waiter is now reused.

### Changed

- **Reconnect re-subscribes all query sets concurrently instead of serially.** `SubscriptionManager` previously replayed query sets one at a time on reconnect, each awaiting its `SubscribeApplied` (and its own 30-second timeout) before the next was sent — N query sets cost N sequential round-trips and a worst case of N × 30s stuck reconnecting. All `Subscribe` messages are now sent up front and awaited together, so the worst case is bounded by a single 30-second window regardless of set count, and a real link pays one round-trip of inter-set latency instead of one per set. Per-set semantics are unchanged: a timed-out or interrupted set is retained for the next reconnect, a partial resubscribe still skips reconnect eviction and keeps cached rows, and `subscriptionsReady` still flips only once every set has re-applied. No API changes.

Queue-wide pausing on a stuck mutation, same-mutation retry ordering, and the give-up path after repeated aborts are unchanged and intentional.

## 2.3.1 - 2026-07-20

Code-generation fixes, all surfaced by consumers integrating generated clients. No runtime-API changes. Generated clients from 2.3.0 keep working; regenerating against 2.3.1 is additive.

### Added

- **Standalone `#[SpacetimeType]` product structs.** A named product type used as a reducer parameter or field but not backed by a table (e.g. a `ServerPosition` reducer argument) produced no Dart class, forcing consumers to hand-write it. It now emits a full data class alongside table and sum-type classes.
- **`ScheduleAt` / `TimeDuration` special types.** Generated clients now handle `ScheduleAt` columns on `#[scheduled]` tables and `TimeDuration` fields, and synthesize named companion classes for inline (anonymous) sum types instead of failing on an unhandled `IrSumType`.

### Fixed

- **Single-field `hashCode` crash.** A table or struct with exactly one field generated `Object.hash(x)`, which throws at runtime (it needs at least two arguments). Now uses `Object.hashAll([...])`, correct for one field or many.
- **Wrong BSATN method on struct/table references.** `reducers.dart` emitted `.encode()` / `.decode()` on product and table references, but the generated classes expose `encodeBsatn` / `decodeBsatn`, so the output did not compile. Encode and decode are now unified on the `*Bsatn` methods across all generated tables, structs, sum types, synthesized inline-sum companions, and the runtime `ScheduleAt` type. The hand-written wire-protocol `.encode()` / `.decode()` API is a separate surface and is unchanged.
- **Zero-field struct broke `operator ==`.** An empty-field struct generated `other is X && ;`, a syntax error. Equality now guards the zero-field case.
- **Class name and cross-reference name could drift for non-PascalCase type names.** Type-class naming and reference resolution now share one transform, so a `#[allow(non_camel_case_types)]` type name cannot emit a class the rest of the generated code fails to reference.

## 2.3.0 - 2026-07-12

Offline-first correctness hardening. This release closes several silent data-loss and data-integrity gaps on the offline mutation and reconnect paths, adds a `subscriptionsReady` readiness signal so consumers can tell a genuinely-usable connection from a merely socket-open one, and makes the previously-dead `queuePolicy` reachable from generated clients. All additive — existing consumers keep working unchanged.

### Added

- **`subscriptionsReady` (`ValueListenable<bool>`)** on `SubscriptionManager` / generated clients. True only when the connection is open AND *every* active query set has had its `SubscribeApplied` applied to the cache; latches back to false the moment the socket drops or a reconnect begins resubscribing, and returns to true only after all query sets re-apply. `Connected` is socket-open, not usable — gate sends/reads on `subscriptionsReady` to avoid a false-positive connected state.
- **`queuePolicy` reachable from generated `create()`.** The `OfflineQueuePolicy` knob (TTL, queue bounds, `onBeforeReplay` veto) is now threaded through the generated `create()` into `SubscriptionManager` — previously it was unreachable and inert for consumers.
- **`SpacetimeDbStorageException`** — post-send dequeue/storage failures are now classified as storage errors instead of being mislabeled as network errors.
- **`TableCache.applyServerDelta` / `applySnapshot` / `dropQuerySet`** — new internal, `querySetId`-labeled apply methods used exclusively by `SubscriptionManager` for every server-sourced write to a primary-key table. Ownership of a row (which query sets currently have it in their result set) is now tracked per-row and derived only from these labeled wire deltas, closing a class of bugs where a row delivered outside the initial `SubscribeApplied` snapshot (a live `TransactionUpdate`, or a caller's own committed reducer result) could be silently evicted by an unrelated query set's later apply. Rows written through the pre-existing unlabeled methods (`applyTransactionUpdate`, `applyInitialData`, `applyTransactionUpdateAndCollectKeys` — unchanged, still released, still used for no-primary-key and event tables) get no ownership entry; they behave like any other offline-hydrated stray, pinned while optimistic, otherwise healed or evicted on the next covering `SubscribeApplied`.

### Fixed

- **Timed-out UPDATE/DELETE no longer false-confirmed on a flaky link.** A queued UPDATE/DELETE whose send timed out while the reducer never ran on the server was previously confirmed against the client's *own* optimistic overlay in the cache and silently dropped from the durable queue — a lost write. Confirmation now uses server provenance; an unverifiable timeout keeps the mutation queued for at-least-once retry.
- **Stacked cross-request UPDATE no longer deletes a committed row on rollback.** When several offline edits stacked on the same primary key and one failed, older-first rollback could delete a row that actually sat on a committed server value. Rollback now restores the true committed base at rollback time and re-applies surviving overlays on top.
- **No-primary-key rows no longer duplicate on restart or phantom on rollback.** No-PK optimistic rows are tracked by request id rather than content-equality, fixing nested-column snapshot duplication, rollback phantoms, and identical-row ambiguity; optimistic overlays are excluded from persisted snapshots.
- **Reducer-timeout reconciliation.** On timeout the SDK reconciles against the cache before retrying (confirm if landed, keep queued if unverifiable) to prevent duplicate server execution; an unverifiable timeout is only discarded while still connected, and kept when the connection dropped so a flaky link can't lose writes. The retry backoff is clamped so it can't overflow to a zero-delay hot loop.
- **Cross-client overlay protection.** A cross-client committed row is now stashed when protection is skipped, so a later optimistic rollback restores server truth instead of resurrecting a stale pre-optimistic snapshot; another client's commit can't clobber a pending optimistic overlay.
- **Reconnect resubscribes in place** without dropping the query set; reconnect eviction is skipped when resubscribe is interrupted so a mid-reconnect disconnect can't wipe the cache.
- **`subscribe()` never hangs.** It completes on subscription error, disconnect, and dispose; the subscribe waiter always completes even if `SubscribeApplied` handling throws. `dispose()` is idempotent and ignores connection-state events (and the reconnect resubscribe tail) after dispose, so teardown never writes the disposed `subscriptionsReady` notifier.
- **Journal-append-before-mutate ordering** so append failures can't diverge queue state or resurrect confirmed mutations; optimistic changes roll back when an enqueue write fails so a failed queue write can't leave phantom rows.

### Changed (observable, opt-out not available)

- **A row visible to two or more overlapping query sets on the same table now fires exactly one insert event and exactly one delete event**, on the 0→1 and →0 ownership transitions respectively — matching the official SpacetimeDB SDKs' semantics. Previously such a row could double-fire insert/delete events once per owning query set. This is very likely a latent-bug fix for any consumer relying on `onInsert`/`onDelete`/`lastBatch` counts on a table subscribed via more than one overlapping query, but it is an observable behavior change and is called out here per house convention for released-behavior deltas.

## 2.2.0 - 2026-06-27

Hardens the offline-first sync path: a configurable replay policy for the offline mutation queue, surfaced flush failures, append-only journal storage, and a cluster of reconnect-correctness fixes that stop offline edits being silently clobbered when a subscription rehydrates. All additive — existing consumers keep working unchanged.

### Added

- **`OfflineQueuePolicy`** — opt-in control over how the offline mutation queue replays on reconnect. Configurable TTL (drop mutations older than a bound), queue size bounds, and an `onBeforeReplay` veto callback that lets the consumer inspect and reject queued mutations before they flush. Exported from `spacetimedb_sdk.dart` and `codegen.dart`. Defaults preserve prior behaviour (replay everything, no expiry).
- **Sync-failure surfacing on `SyncState`.** Flush rejections are now recorded as failure records on `SyncState` instead of being swallowed, with a configurable retention bound (also via `OfflineQueuePolicy`). New `clearSyncErrors()` to drain them; generated clients expose a `clearSyncErrors` passthrough.
- New exception type(s) on `lib/src/exceptions.dart` for offline-replay rejection paths.

### Changed (non-breaking)

- **Append-only journal storage** for the offline mutation queue. The JSON file backend no longer rewrites the entire queue file on every mutation — it appends to a journal, cutting write amplification for large or churny queues. Transparent to consumers; same `OfflineStorage` contract.

### Fixed

- **Offline edits no longer clobbered on reconnect.** Rows with pending offline mutations are protected from stale-snapshot overwrites when a subscription delivers a fresh server snapshot on reconnect (`5bc3898`).
- **Subscription rehydrates via the awaited subscribe path on reconnect** rather than racing the cache, so reconnect-time row state is correct (`b4bae9f`).
- **`SubscribeApplied` cache clear scoped to the current query set** — a multi-queryset client no longer wipes unrelated cached rows when one subscription re-applies (`48b0a09`).
- **Cache reconciled to committed server rows** when an optimistic confirmation releases a key, eliminating a window where the local view diverged from the server (`1c638df`).



Adds v3 WebSocket transport support (SpacetimeDB 2.2.0+) and unblocks Flutter web wasm builds. Both changes are additive — no consumer code changes required, no semver-breaking deltas.

### Added

- **v3 WebSocket subprotocol negotiation.** SDK now advertises `[v3.bsatn.spacetimedb, v2.bsatn.spacetimedb]` and uses whichever the server picks. v3 servers (SpacetimeDB 2.2.0+, upstream PR #4761) negotiate v3 automatically; older servers fall back to v2 with no behavioural change. New `SpacetimeDbConnection.negotiatedProtocol` getter exposes the result. New public enum `NegotiatedWsProtocol { v2, v3 }`.
- **Inbound v3 frame batching.** On v3, the server may pack multiple `ServerMessage`s into one WebSocket frame to cut per-message overhead. `MessageDecoder.decodeAll(bytes)` reads the compression tag once, decompresses once, then splits the payload into N messages and dispatches each in logical order. The single-message `MessageDecoder.decode(bytes)` is preserved for v2 callers and asserts a single-message payload.
- **Outbound v3 frame batching (opportunistic).** Same-microtask `send(...)` calls coalesce into one frame on v3 — captures the realistic win of N synchronous subscribes during reconnect-resubscribe. Capped at `ConnectionConfig.maxV3OutboundFrameBytes` (default 256 KiB, matching the TypeScript SDK); a queue exceeding the cap splits across multiple frames with a `Timer(Duration.zero)` yield between them so a backlog never starves the read path. New `ConnectionConfig.outboundBatching` knob (`OutboundBatchingPolicy.opportunistic` default, `disabled` for one-frame-per-call). On v2 or with `disabled`, every `send` is one frame unchanged.
- **Flutter web wasm support.** `flutter build web --wasm` no longer fails at first connection with `UnsupportedError: No WebSocket implementation for this platform`. The conditional-import gate in `lib/src/connection/websocket.dart` and `platform.dart` migrated from `dart.library.html` (false under wasm) to `dart.library.js_interop` (true under both JS and wasm). `HtmlWebSocketChannel` in `web_socket_channel` 3.x is already wasm-safe — no behavioural change for existing JS web builds.
- **Integration tests** against a live 2.2.0+ server: `test/integration/v3_protocol_negotiation_test.dart` verifies (a) server accepts v3, (b) `[v3, v2]` lands on v3, (c) v2 fallback regression guard, (d) `SpacetimeDbConnection.negotiatedProtocol == v3` end-to-end with first-frame decode.

### Changed (non-breaking)

- Renamed internal files `websocket_html.dart` → `websocket_web.dart` and `platform_html.dart` → `platform_web.dart`. Public surface unchanged — these files were never exported.

### Compatibility

- **Server:** v3 features require SpacetimeDB 2.2.0+. Older servers transparently negotiate v2.
- **Flutter web:** wasm builds now work; JS builds behave identically to 2.0.0.
- **Test infrastructure:** local development requires `spacetime version use >= 2.2.0` for the v3 integration tests to land on v3 (otherwise the suite still passes via v2 fallback assertions).

## 2.0.0 - 2026-04-25

First release targeting the SpacetimeDB **v2** WebSocket wire protocol (server 2.x). This is a hard cut. The SDK no longer speaks v1; if you need a v1 client, stay on `spacetimedb_sdk 1.x`.

This is a full rewrite of every message the SDK reads and writes, not a compatibility shim or a subprotocol flip. Every `ClientMessage` and `ServerMessage` has been re-encoded and re-decoded against the canonical upstream definitions in `crates/client-api-messages/src/websocket/v2.rs`. Removed message types are gone, not stubbed. Removed fields are deleted, not null-compat'd. Wire-format alignment was verified against live SpacetimeDB 2.x servers, not inferred from docs.

### Added

- **`Uint8List? retValue` on `TransactionResult`.** v2 reducer calls return `ReducerResult` with an optional `ret_value: Bytes` payload. Forward-compat for future typed reducer returns (today it's `null` unless the server sends bytes). Zero-length `Ok.ret_value` and `OkEmpty` both collapse to `retValue: null` so consumers check one thing, not two.
- **`SendDroppedRows` flag on `unsubscribe()`.** New signature: `unsubscribe(int querySetId, {int requestId = 0, bool sendDroppedRows = false})`. When `true`, the server replies with an `UnsubscribeApplied` carrying the rows being dropped from this client's subscription set; the SDK dispatches those as delete events on the affected row streams. Default `false` preserves current behaviour (you clear your own cache view if you care).
- **`InternalError` sealed variant on `UpdateStatus`.** Distinct from `Failed`. Maps v2 `ReducerOutcome::InternalError(Box<str>)`. Carries a server-generated diagnostic string, not consumer-supplied error bytes. Lets consumers distinguish "your reducer returned `Err`" from "the host encountered an internal fault executing your reducer."
- **Live-server v2 integration tests** against a real 2.x server:
  - `v2_protocol_negotiation_test.dart`. Verifies the server accepts `v2.bsatn.spacetimedb` subprotocol and emits a clean `InitialConnection` first frame.
  - `v2_compression_test.dart`. Round-trips compressed frames against the live server.
  - `v2_non_caller_broadcast_test.dart`. Two-connection test proving connection B receives a `TransactionUpdate` when connection A writes, and B's local cache reflects the row.
  - `v2_non_caller_metadata_test.dart`. Pins the v2 caller-vs-non-caller metadata contract: caller sees `ReducerEvent` + `isMyTransaction == true`; non-caller observes the row insert but receives `UnknownTransactionEvent` and the generated `on<Reducer>` listener does not fire.
  - `v2_reducer_result_variants_test.dart`. Pins all four `ReducerOutcome` paths: `Failed(Bytes)` round-trips an `Err("...")` message verbatim, `InternalError(str)` carries a server-generated diagnostic for panicking reducers, and both `Ok` (zero-length `ret_value`) and `OkEmpty` collapse to `retValue: null`.
  - `v2_send_dropped_rows_test.dart`. Pins both `unsubscribe(sendDroppedRows: true)` (server delivers dropped rows + SDK fires deletes) and the default `false` path (no delete events).
  - `v2_transaction_update_wire_test.dart`. Captures a real `TransactionUpdate` frame, hand-decodes it byte-by-byte against `crates/client-api-messages/src/websocket/v2.rs:302-355` + `common.rs:60-94`, and cross-checks the result against the SDK's `MessageDecoder`. Catches symmetric tag/order mistakes that fixture-only unit tests cannot.
- **`check_health_test.dart`**. Live-server probe for the SDK's new silent-dead-socket detection.
- **Message-ordering stress tests** (`message_ordering_stress_test.dart`, `_chrome_test.dart`). Confirm transaction-order invariants hold under burst-y broadcast conditions on both VM and web platforms.

### Changed (breaking)

- **WebSocket subprotocol:** `v1.bsatn.spacetimedb` → `v2.bsatn.spacetimedb`. SDK now only speaks v2. No version fallback.
- **`onReducerEvent` listener semantics.** v2 deliberately strips reducer-call metadata (caller identity, args, reducer name) from non-caller broadcasts at the protocol level. The SDK honours this by only constructing `ReducerEvent` on the caller's own path. **Your generated `on<Reducer>` listeners now fire for self-initiated calls only.** To observe remote mutations, subscribe to the table's row streams (`client.<table>.onInsert` / `onUpdate` / `onDelete`); the delta is what you actually want to react to anyway.
- **`isMyTransaction` derivation.** Same return values for the same situations, but derived from message-type dispatch (caller path vs broadcast path) rather than byte-comparing caller connection IDs. No consumer change needed unless you were pattern-matching on the internal construction.
- **`UpdateStatus` sealed class reworked.** New shape: `Committed(DatabaseUpdate)` / `Failed(Uint8List errorBytes)` / `InternalError(String message)` / `Pending` / `Dropped`. `Failed` now carries raw `Uint8List errorBytes` with a `String get errorMessage => utf8.decode(errorBytes, allowMalformed: true)` getter, forward-compat for future typed errors without another breaking rev. **Removed:** `OutOfEnergy` (no v2 wire source; v2's `ReducerOutcome` enum has no such variant).
- **`TransactionResult` fields removed outright** (no null-compat stubs): `energyConsumed`, `executionDuration`, `isLightUpdate`, `isOutOfEnergy`. None have v2 wire sources.
- **Message types deleted** (no v2 equivalents): `TransactionUpdateLight`, `SubscribeSingle`, `SubscribeMulti`, `UnsubscribeMulti`, `SubscribeMultiApplied`, `UnsubscribeMultiApplied`, `InitialSubscription`, `IdentityTokenMessage` (replaced by `InitialConnectionMessage`).
- **`unsubscribe()` signature:** now takes `querySetId: int` (was `queryId`). Subscriptions are now client-assigned `QuerySetId` (u32) rather than server-assigned opaque IDs, which is what makes reliable resubscribe-on-reconnect possible at all.
- **`oneOffQuery()` signature:** now `(String query, {int requestId = 0})`. Dropped `Uint8List messageId`; v2's `OneOffQuery` message carries a `u32 request_id` instead.
- **`CallReducer` and `CallProcedure` wire formats changed** (v1 → v2 field order). Transparent to consumers if you go through codegen; if you were hand-constructing these messages, field order is now `(tag, requestId, flags, name, args)` per `v2.rs:115-131` and `:150-166`.
- **`InitialConnection` replaces `IdentityToken`** as the server's first message. Field order swapped (v1: `identity, token, connectionId` → v2: `identity, connectionId, token`). Callback renamed `onIdentityToken` → `onInitialConnection`.

### Fixed

- **Silent loss of all subscriptions after a reconnect cycle.** The previous `SubscriptionManager._startConnectionMonitoring()` tracked reconnect intent with a `wasReconnecting` flag that got cleared by the intermediate `Disconnected` state in the SDK's own auto-reconnect sequence (`Reconnecting → Disconnected → Connecting → Connected`). The final `Connected` was then treated as a fresh connect, skipping the resubscribe. Writes kept working (reducer calls don't require a subscription), but no server broadcasts arrived. Silent, easy to miss, affected every long-running client on mobile backgrounding, wifi handoff, server restart, or any transient disconnect. Replaced the transient flag with a `hasConnectedBefore` monotonic latch: any non-initial `Connected` triggers resubscribe. Validated on real iOS; previously-reproducing flake gone.
- **`ProcedureStatus` tag table collision.** v1 Dart decoded tag `1` as `OutOfEnergy` (unit variant) and tag `2` as `InternalError(string)`. v2's `ProcedureStatus` has two variants (tag `0 = Returned(Bytes)`, tag `1 = InternalError(Box<str>)`) and would have silently misaligned the decoder on every v2 `InternalError` (reading the string-length prefix as a phantom unit-variant dispatch). Fixed before any v2 frame touched the decoder.
- **`OneOffQueryResult` Result tag order.** v2's `Result<QueryRows, Box<str>>` encoding uses tag `0 = Ok`, tag `1 = Err` per `crates/sats/src/ser/impls.rs:120-123`. Decoder rewritten to match the canonical upstream encoding.
- **`SubscriptionError` message shape.** Rewritten to v2 layout per `v2.rs:271-291`: `{ request_id: Option<u32>, query_set_id: QuerySetId, error: Box<str> }`. Removed v1 fields `total_host_execution_duration_micros` and `table_id`.
- **Stale `SubscriptionError` recovery regex.** The v1 recovery path was looking for `` `(\w+)` is not a valid table `` but the actual server text (on 2.x) is `no such table: \`<name>\`...`. Recovery was dead code. Replaced with direct query extraction from the `executing: \`<query>\`` suffix, which drops the failed query by exact match rather than fuzzy table-name extraction. Survives future server text tweaks.
- **`TransactionResult.timestamp` was 1000× too small for the entire v1 era.** The wire `Timestamp` is `i64` microseconds since Unix epoch (canonical type at `crates/sats/src/timestamp.rs`, field `__timestamp_micros_since_unix_epoch__`). The SDK's `transaction_result.dart` was treating the wire value as nanoseconds and dividing by 1000 before feeding it to `DateTime.fromMicrosecondsSinceEpoch`. Result: every `result.timestamp` since v1.0.0 came back set to a date in January 1970 instead of the real transaction time. Verified empirically against a live 2.x server (a reducer call's `result.timestamp` now lands within milliseconds of the local `DateTime.now()` straddling the call). Bug was unnoticed because no observed consumer reads `result.timestamp` meaningfully; SpaceNotes ignores it entirely. The raw `ReducerEvent.timestamp` (`Int64`) field was always documented and exposed as microseconds and is unchanged; only the `DateTime` derivation was wrong.

### Why this is a real v2 SDK

The v2 wire protocol isn't a subprotocol flip. It changes message shapes, field orders, tag values, and the relationship between caller and broadcast frames. Half-measures (flipping the subprotocol string while keeping v1 decoders, or patching fields ad-hoc as they surface) produce a client that looks like it works until the first non-trivial transaction silently corrupts a decoder and you get garbled data three message types downstream from the real misalignment.

What this release does instead:

- **Every v1-only message type is deleted**, not stubbed. No `TransactionUpdateLight`, no `SubscribeMulti*`, no `InitialSubscription`. If the compiler lets a v1 reference survive, the code path is dead. There's no v2 frame that would ever route to it.
- **Every v2 tag value is verified against upstream source**, not inferred from docs or reused from v1 by position. `ClientMessage` tags are `Subscribe(0), Unsubscribe(1), OneOffQuery(2), CallReducer(3), CallProcedure(4)` per `v2.rs:18-29`. Every tag differs from v1. `ServerMessage` tags (v2.rs:175-196) likewise.
- **Every field-order change in `CallReducer` / `CallProcedure` / `Subscribe` / `Unsubscribe` / `OneOffQuery` is reflected in the encoder.** The difference between "encoder writes v1 order under v2 subprotocol" and "encoder writes v2 order" is the difference between a silently-broken reducer call and a working one. There is no runtime error, just garbage args.
- **Caller-path vs broadcast-path semantics are modelled explicitly.** v2's deliberate choice to strip reducer metadata from non-caller broadcasts requires the SDK to route `ReducerResult` (caller) and `TransactionUpdate` (broadcast) through different handlers and build `ReducerEvent` on one path, not both. Generated `on<Reducer>` listener contracts reflect this.
- **Resubscribe after reconnect actually works.** This was silently broken under v1 too (see Fixed). A v2 SDK that inherits the v1 resubscribe bug is a v2 SDK that drops all your queries on the first wifi handoff.
- **Live-server integration tests, not unit mocks.** `v2_protocol_negotiation_test`, `v2_compression_test`, `v2_non_caller_broadcast_test`, `v2_non_caller_metadata_test`, `v2_reducer_result_variants_test`, `v2_send_dropped_rows_test`, `v2_transaction_update_wire_test`, `check_health_test`, `message_ordering_stress_test*` all open real WebSocket connections to a live 2.x server and assert against actual server frames. Unit tests give you "I wrote the encoder I intended to write"; integration tests give you "the server on the other end agrees." `v2_transaction_update_wire_test` goes one further: it bypasses the SDK's own decoder and parses raw bytes against the upstream Rust schema, then cross-checks against the SDK's decoder. A symmetric tag-or-order mistake (e.g. swapping `inserts` and `deletes`) would self-consistently round-trip on fixtures the same code produced; this test does not.

### Behaviours worth knowing about

These aren't SDK choices; they're protocol and server behaviours surfaced by the pre-release validation pass. Documented here so consumers don't run into them blind:

- **Reducer panic messages are scrubbed by the server.** A reducer that panics with `panic!("intentional reducer panic")` reaches the client as `InternalError(message: "the instance encountered a fatal error.")`. The original panic text does not cross the wire (upstream privacy behaviour, not an SDK transformation). If you want consumers to see a specific message, return `Err("...")` from the reducer; that path (`Failed(Bytes)`) round-trips the user-supplied string verbatim. (Verified against SpacetimeDB 2026-04-25.)
- **Generated `on<Reducer>` listeners no longer fire on remote writes.** This is the v2 design intent (clients are entitled to *table state*, not *how the state got there*) and it lands as a behavioural change for any consumer that was using the v1 listener API. To react to remote mutations, subscribe to the table's row streams (`onInsert` / `onUpdate` / `onDelete`) and read the row data; that's the audit-trail-free signal v2 commits to delivering. If you genuinely need to know which connection performed a write, model it as explicit data: a row in an `events` or `audit_log` table the reducer writes.
- **`RowSizeHint` variants are not stable per `TableUpdate`.** A single `TableUpdate` can carry inserts encoded as `FixedSize(N)` and deletes encoded as `RowOffsets([])`. Observed in `v2_transaction_update_wire_test`. The SDK's decoder handles both variants on each `BsatnRowList`; consumers that hand-decode wire frames must do the same.

## 1.1.1 - 2026-04-18

Packaging / docs patch. No runtime changes.

### Changed

- Bumped `brotli` constraint from `^0.5.0` to `^0.6.0` to pick up the latest stable. No API change; the SDK only calls `brotli.decode(bytes)`, which is unchanged.
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

### Changed (breaking, but phantom data only)

- `OutOfEnergy` (in `update_status.dart`) no longer has a `budgetInfo: String` field or a string constructor. The field only ever carried garbled bytes from the misaligned decoder; it was never a real value. Consumers constructing `OutOfEnergy('...')` must now use `OutOfEnergy()`. `TransactionResult.errorMessage` returns `'Out of energy'` instead of `'Out of energy: <info>'`. This is technically a breaking change but nobody could have written working code against the old field, so it's ordinarily listed under a minor bump rather than a major.

## 1.0.1 - 2026-04-15

Docs only. README's Quick Start install snippet and codegen command lines still referenced the pre-rename package name (`spacetimedb_dart_sdk`). Fixed to the published name (`spacetimedb_sdk`).

## 1.0.0 - 2026-04-15

First public release on pub.dev.

This version consolidates a multi-month pre-release development effort into the first stable, published API. Everything below was already in place before publication; the CHANGELOG entries exist as a reference for anyone who was tracking the SDK via git before 1.0.

### Reactive primitives

- `TableCache<T>.rows`: `ValueNotifier<List<T>>` that fires on every transaction touching the table.
- `TableCache<T>.lastBatch`: `ValueNotifier<TransactionBatch<T>?>` carrying every row change from the most recent transaction. Fires exactly once per transaction with a `List<TableEvent<T>>` (insert / update / delete subtypes).
- `TableCache<T>.rowNotifier(primaryKey)`: per-row auto-disposing `ValueNotifier<T?>` that fires only when that specific row's value changes. Scales to thousands of concurrent row-watchers at `O(rows_touched)` cost per transaction, not `O(listeners × events)`.
- `TableCache<T>.onInsert` / `onUpdate` / `onDelete`: broadcast `Stream<TableEvent<T>>` for consumers that react to one kind of change (no iteration or type-ladder needed). Fire synchronously in the same transaction as `lastBatch`.
- `TableCache<T>.subscribed`: `Future<void>` that resolves when the server delivers the initial batch for this table (including empty tables).

### Typed client

- Code generation from Rust module: tables, reducers, sum types (Rust enums → Dart sealed classes with exhaustive matching), views (`Vec<T>`, `Option<T>`, single-row).
- Reducers become typed async Dart methods returning `TransactionResult` (energy cost, server timestamp, queued/dropped status).
- Views exposed as direct accessors (`client.activeUsers`, `client.currentAdmin`).

### Optimistic updates

- `OptimisticChange.insertRow(tableCache, row)` / `updateRow` / `deleteRow`: typed helpers that extract the table name and serialize via the decoder.
- `nextOptimisticIntId()`: utility for client-side temporary primary keys.
- Pass `optimisticChanges: [...]` on any reducer call; the SDK applies the writes locally, keeps them on server-ack, or rolls them back on rejection.
- Multi-table reducer support: stage one `OptimisticChange` per table write.

### Offline storage

- `OfflineStorage` abstract class: `saveTableSnapshot` / `loadTableSnapshot`, mutation queue, per-table last-sync timestamps.
- `JsonFileStorage`: durable file-based implementation.
- `InMemoryOfflineStorage`: for tests.
- Cached reads work without a connection; writes queue while disconnected and replay in order on reconnect.
- `client.onSyncStateChanged` + `client.onMutationSyncResult` streams for sync-state UI.

### Exception handling

Sealed `SpacetimeDbException` root with seven typed subtypes (`Reducer`, `Connection`, `Auth`, `Timeout`, `Schema`, `Protocol`, `Subscription`). `on SpacetimeDbException catch (e)` covers every SDK runtime failure.

- `connect()` wraps raw `SocketException` / `HandshakeException` / `WebSocketException` into `SpacetimeDbConnectionException`.
- BSATN decode errors throw `SpacetimeDbProtocolException`.
- `SpacetimeDbAuthException` extends `SpacetimeDbConnectionException`.

### Connection

- Sealed `ConnectionState` (`Connecting` / `Connected` / `Reconnecting` / `Disconnected` / `AuthError` / `FatalError`); `switch` exhaustively.
- `client.connection.onStateChanged`: `Stream<ConnectionState>`.
- Automatic reconnection with exponential backoff.

### Extensions

`ValueListenable<T>` extensions for common async patterns:
- `firstNonNull()`: resolve with first non-null value (current or future).
- `firstWhere(predicate)`: resolve when predicate first holds.
- `next`: resolve on next change, ignore current.
- `toStream()`: bridge to `Stream<T>` for `StreamBuilder` / rxdart interop.

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
