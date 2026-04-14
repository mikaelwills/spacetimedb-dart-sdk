# MMORPG Scale Benchmark — Tier 1 Per-Row Notifier

Date: 2026-04-14
SDK commit: f300adb + tier-1-per-row-notifiers branch
Platform: macos Version 15.5 (Build 24F74)

## Summary vs. 2026-04-12-baseline.md

With 10× the listeners (100 → 1000), listener fan-out dropped from p50=5-9µs to **p50=0µs, p95=1µs, p99=1µs** — the expected `O(rows_touched)` win. Only the ~10 rows actually touched per transaction wake their notifiers; the other 990 listeners stay asleep.

Per-tx latency and throughput sit in the same band as the baseline `mmorpg-multi-listener` config — matching the prediction in `knowledge.md` that the SDK reactive layer is not the throughput bottleneck at game scale. The win is CPU time avoided at the consumer (widgets not rebuilding), not raw throughput.

## Methodology

- Client-side measurement only (SDK reactive primitives, not server)
- Per-tx latency: time from onMessage (WS frame received) to lastBatch listener fire
- Fan-out: time inside rows.addListener callback (includes count() call)
- Preloaded entity table to target size before each workload
- SdkLogger.level = none, offlineStorage = null
- Serial execution, fresh connection per config

## Results

### mmorpg-per-row-notifier
- Config: N=1000 tx/s, K=10 rows/tx, table=100000, listeners=1000, duration=10s
- Wall time: 18367ms
- Throughput: 10000 fired, 6763 observed (67.6% kept up)
- Per-tx latency (onMessage → lastBatch): p50=2523us, p95=4285us, p99=5711us
- Listener fan-out (rows callback): p50=0us, p95=1us, p99=1us
- Frame budget misses (>16ms): 0


