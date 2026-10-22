# Scan performance

Measured on Apple Silicon/macOS on 2026-10-22, using release builds. The baseline
is commit `aec989c`; both versions used the same `ScanBenchmark.swift` harness
and generated 2,000 sessions with 100 events each. Token totals and index warnings
are checked by the harness. Times below are process CPU time, not peak CPU percent.

| Scenario | Baseline | Optimized | Reduction |
| --- | ---: | ---: | ---: |
| Initial indexing | 65.403 s | 16.404 s | 74.9% |
| Unchanged refresh (median of three) | 7.227 s | 0.047 s | 99.4% |
| One file receives one new event | 7.906 s | 0.673 s | 91.5% |

The main costs were regenerating every historical event ID with formatter-based
SHA256 hex conversion and rewriting the complete cache after any append. Unchanged
scans now read metadata only, keep event IDs and period totals, and write nothing.
Changed scans reuse unchanged file events and persist only changed record shards.

A separate check with approximately 2,350 local session files measured about
6.0 s versus 0.16 s CPU time for an unchanged refresh. The installed app consumed
1.54 CPU seconds over an 85.1-second observation with ongoing session activity
(1.81% of one core on average). These are local observations, not CPU limits;
initial indexing and active updates can still produce short bursts.

Reproduce using synthetic data only:

```sh
bash scripts/benchmark.sh
bash scripts/benchmark.sh --source /path/to/baseline/checkout
```

The harness removes its temporary sessions and cache after each run. Unit tests
also assert zero content reads, zero event ID regeneration, and zero aggregation
rebuilds for unchanged scans. Cache tests cover migration, interrupted writes,
orphan/generation cleanup, missing-source expiry, and preserving unrelated files.
