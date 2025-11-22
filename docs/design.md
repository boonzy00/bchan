# bchan v0.2 Design and Correctness — Living Document

> This document supersedes the original `bchan_algorithm.md` (2025) with updated performance results, consumer O(1) fast-path details, and reproducible measurement methodology. The original paper is preserved unchanged in the repository root for historical reference.

Status: Draft — last updated: 2025-11-22

Summary
- Headline locked-run numbers (AMD Ryzen 7 5700G, Zig 0.15.0, `-Doptimize=ReleaseFast`, cores 0/1 isolated, governor=performance):
  - MPSC (batched, zero-copy), 16 producers: 968 M msg/s (mean of 5 runs)
  - SPSC (batched, zero-copy), 1 producer: 206 M msg/s (mean of 7 repeated runs, governor locked)

Purpose
- Keep a single, up-to-date design and reproducibility reference for the implementation shipped in v0.2.x.
- Explain correctness refinements that make the consumer fast-path O(1) in common cases.
- Provide exact reproduction steps and the scripts used to obtain locked-run numbers.

Reproducibility (how we measure)
- Hardware: AMD Ryzen 7 5700G (8c/16t). Run on a single socket, undisturbed by background load.
- Software: Zig 0.15.0 (or newer). Build with `-Doptimize=ReleaseFast`.
- Isolation steps (scripts in `scripts/`):
  1. Save current CPU governors and restore on exit.
  2. Set all CPU `scaling_governor` entries to `performance` (or use `cpupower frequency-set -g performance`).
  3. Optionally isolate CPUs with `cset shield --cpu=0,1 --threads` and pin the bench process with `taskset -c 0,1`.
  4. Run `perf stat -e cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses,cache-references,cache-misses,context-switches -r N` with `N` repeats for aggregated mean±std.
  5. Run the bench binary: `./zig-out/bin/bench-simple-spsc-batched -- <duration-s> <batch-size>` for SPSC batched runs; use `./scripts/run_bench_mpsc.sh` for MPSC multi-producer runs.

Scripts
- `scripts/run_peak_locked.sh`: performs the governor lock, optional `cset` shielding, runs the SPSC batched binary under `perf stat -r 7` (default), captures stdout/stderr and perf output in `/tmp/bchan_spsc_peak_<ts>` and restores system state on exit.
- `scripts/run_scaling_locked.sh`: loops a set of batch sizes (1,4,16,64,256) and writes `scaling_locked.log` into `/tmp/bchan_scaling_locked_<ts>`.

Design updates (v0.2.x)

1) Consumer O(1) Fast-Path: generation counters + lazy tail caching
- Problem: earlier designs required an O(P) scan of producer tails on every dequeue to compute the min tail and determine emptiness. For P large this is costly.
- Idea: maintain a per-producer monotonic generation counter that changes whenever a producer advances its tail beyond previously observed values. The consumer keeps a cached min-tail and only updates it when it observes progress or a potential empty condition.
- Effect: the common-case consumer read (when buffer has items) becomes O(1) — read `consumer_head`, check cached_min_tail; if cached_min_tail > head, we can consume without scanning. A full O(P) scan is needed only when cached_min_tail == head (potential empty) or when `active_producers == 0` (final drain).

2) Reserve/Commit semantics clarified
- `reserveBatch(&ptrs)` returns pointers to contiguous buffer slots and records the intended reservation in the producer's `reserved` field without advancing the tail.
- `commitBatch(n)` advances the producer tail with `.release` ordering and resets `reserved`. The producer must not write beyond the reserved count.
- These semantics ensure safe zero-copy fills while preserving linearizability: other readers will not observe partially filled slots because `tail` advancement is the linearizing action.

3) Memory ordering and padding rules
- Producer `tail` writes use `.release` for visibility; consumer `head` uses `.acquire` when reading dependent data.
- Per-producer `tail` fields are cache-line aligned and padded to avoid false sharing.
- `active_producers` is modified under `.release` on register/unregister and read `.acquire` by the consumer to know when a final drain is safe.

Correctness notes
- Linearizability: enqueue's linearization point is the `.release` store of the producer's `tail` (or `commitBatch`); dequeue linearization is `consumer_head` advancement.
- No lost-wake: futex wait/wake uses a swap/clear pattern for waiter counters to avoid races where a wake comes before a waiter increments its counter.
- Producer registration: `registerProducer()` allocates a per-producer slot and increments `active_producers` with `.release`. Unregister decrements with `.acq_rel` and may trigger final wake behavior.

Bench details and tips
- Batch size tuning: batched SPSC peaks in the 64–256 batch range on our hardware; MPSC uses larger aggregate batches across producers.
- Buffer sizing: power-of-two capacities are required; prefer large buffers (64K+) for high-throughput sustained runs.
- Pin producer/consumer to separate physical cores (not logical siblings) to reduce interference.

Files and artifacts
- `docs/design.md` (this file): living design + reproducibility notes.
- `bchan_algorithm.md`: original historical paper (untouched).
- `scripts/run_peak_locked.sh`, `scripts/run_scaling_locked.sh`: reproducible measurement scripts.

Next steps (suggested)
- Review this draft and provide additional correctness details you want preserved (e.g., exact pseudocode for generation counters, state diagrams for producer registration lifecycle).
- After approval, add this file to the docs index and link it from `README.md` and `CHANGELOG.md`.

Acknowledgements
- This living document collects the final measurement and correctness work done in November 2025 and should be kept up-to-date as the project evolves.
# bchan v0.2 Design and Correctness — Living Document

> This document supersedes the original `bchan_algorithm.md` (2025) with updated performance results, consumer O(1) fast-path details, and reproducible measurement methodology. The original paper is preserved unchanged in the repository root for historical reference.

Status: Draft — last updated: 2025-11-22

Summary
- Headline locked-run numbers (AMD Ryzen 7 5700G, Zig 0.15.0, `-Doptimize=ReleaseFast`, cores 0/1 isolated, governor=performance):
  - MPSC (batched, zero-copy), 16 producers: 968 M msg/s (mean of 5 runs)
  - SPSC (batched, zero-copy), 1 producer: 206 M msg/s (mean of 7 repeated runs, governor locked)

Purpose
- Keep a single, up-to-date design and reproducibility reference for the implementation shipped in v0.2.x.
- Explain correctness refinements that make the consumer fast-path O(1) in common cases.
- Provide exact reproduction steps and the scripts used to obtain locked-run numbers.

Reproducibility (how we measure)
- Hardware: AMD Ryzen 7 5700G (8c/16t). Run on a single socket, undisturbed by background load.
- Software: Zig 0.15.0 (or newer). Build with `-Doptimize=ReleaseFast`.
- Isolation steps (scripts in `scripts/`):
  1. Save current CPU governors and restore on exit.
  2. Set all CPU `scaling_governor` entries to `performance` (or use `cpupower frequency-set -g performance`).
  3. Optionally isolate CPUs with `cset shield --cpu=0,1 --threads` and pin the bench process with `taskset -c 0,1`.
  4. Run `perf stat -e cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses,cache-references,cache-misses,context-switches -r N` with `N` repeats for aggregated mean±std.
  5. Run the bench binary: `./zig-out/bin/bench-simple-spsc-batched -- <duration-s> <batch-size>` for SPSC batched runs; use `./scripts/run_bench_mpsc.sh` for MPSC multi-producer runs.

Scripts
- `scripts/run_peak_locked.sh`: performs the governor lock, optional `cset` shielding, runs the SPSC batched binary under `perf stat -r 7` (default), captures stdout/stderr and perf output in `/tmp/bchan_spsc_peak_<ts>` and restores system state on exit.
- `scripts/run_scaling_locked.sh`: loops a set of batch sizes (1,4,16,64,256) and writes `scaling_locked.log` into `/tmp/bchan_scaling_locked_<ts>`.

Design updates (v0.2.x)

1) Consumer O(1) Fast-Path: generation counters + lazy tail caching
- Problem: earlier designs required an O(P) scan of producer tails on every dequeue to compute the min tail and determine emptiness. For P large this is costly.
- Idea: maintain a per-producer monotonic generation counter that changes whenever a producer advances its tail beyond previously observed values. The consumer keeps a cached min-tail and only updates it when it observes progress or a potential empty condition.
- Effect: the common-case consumer read (when buffer has items) becomes O(1) — read `consumer_head`, check cached_min_tail; if cached_min_tail > head, we can consume without scanning. A full O(P) scan is needed only when cached_min_tail == head (potential empty) or when `active_producers == 0` (final drain).

2) Reserve/Commit semantics clarified
- `reserveBatch(&ptrs)` returns pointers to contiguous buffer slots and records the intended reservation in the producer's `reserved` field without advancing the tail.
- `commitBatch(n)` advances the producer tail with `.release` ordering and resets `reserved`. The producer must not write beyond the reserved count.
- These semantics ensure safe zero-copy fills while preserving linearizability: other readers will not observe partially filled slots because `tail` advancement is the linearizing action.

3) Memory ordering and padding rules
- Producer `tail` writes use `.release` for visibility; consumer `head` uses `.acquire` when reading dependent data.
- Per-producer `tail` fields are cache-line aligned and padded to avoid false sharing.
- `active_producers` is modified under `.release` on register/unregister and read `.acquire` by the consumer to know when a final drain is safe.

Correctness notes
- Linearizability: enqueue's linearization point is the `.release` store of the producer's `tail` (or `commitBatch`); dequeue linearization is `consumer_head` advancement.
- No lost-wake: futex wait/wake uses a swap/clear pattern for waiter counters to avoid races where a wake comes before a waiter increments its counter.
- Producer registration: `registerProducer()` allocates a per-producer slot and increments `active_producers` with `.release`. Unregister decrements with `.acq_rel` and may trigger final wake behavior.

Bench details and tips
- Batch size tuning: batched SPSC peaks in the 64–256 batch range on our hardware; MPSC uses larger aggregate batches across producers.
- Buffer sizing: power-of-two capacities are required; prefer large buffers (64K+) for high-throughput sustained runs.
- Pin producer/consumer to separate physical cores (not logical siblings) to reduce interference.

Files and artifacts
- `docs/design.md` (this file): living design + reproducibility notes.
- `bchan_algorithm.md`: original historical paper (untouched).
- `scripts/run_peak_locked.sh`, `scripts/run_scaling_locked.sh`: reproducible measurement scripts.

Next steps (suggested)
- Review this draft and provide additional correctness details you want preserved (e.g., exact pseudocode for generation counters, state diagrams for producer registration lifecycle).
- After approval, add this file to the docs index and link it from `README.md` and `CHANGELOG.md`.

Acknowledgements
- This living document collects the final measurement and correctness work done in November 2025 and should be kept up-to-date as the project evolves.
# bchan v0.2 Design and Correctness — Living Document

> This document supersedes the original `bchan_algorithm.md` (2025) with updated performance results, consumer O(1) fast-path details, and reproducible measurement methodology. The original paper is preserved unchanged in the repository root for historical reference.

Status: Draft — last updated: 2025-11-22

Summary
- Headline locked-run numbers (AMD Ryzen 7 5700G, Zig 0.15.0, `-Doptimize=ReleaseFast`, cores 0/1 isolated, governor=performance):
  - MPSC (batched, zero-copy), 16 producers: 968 M msg/s (mean of 5 runs)
  - SPSC (batched, zero-copy), 1 producer: 206 M msg/s (mean of 7 repeated runs, governor locked)

Purpose
- Keep a single, up-to-date design and reproducibility reference for the implementation shipped in v0.2.x.
- Explain correctness refinements that make the consumer fast-path O(1) in common cases.
- Provide exact reproduction steps and the scripts used to obtain locked-run numbers.

Reproducibility (how we measure)
- Hardware: AMD Ryzen 7 5700G (8c/16t). Run on a single socket, undisturbed by background load.
- Software: Zig 0.15.0 (or newer). Build with `-Doptimize=ReleaseFast`.
- Isolation steps (scripts in `scripts/`):
  1. Save current CPU governors and restore on exit.
 2. Set all CPU `scaling_governor` entries to `performance` (or use `cpupower frequency-set -g performance`).
 3. Optionally isolate CPUs with `cset shield --cpu=0,1 --threads` and pin the bench process with `taskset -c 0,1`.
 4. Run `perf stat -e cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses,cache-references,cache-misses,context-switches -r N` with `N` repeats for aggregated mean±std.
 5. Run the bench binary: `./zig-out/bin/bench-simple-spsc-batched -- <duration-s> <batch-size>` for SPSC batched runs; use `./scripts/run_bench_mpsc.sh` for MPSC multi-producer runs.

Scripts
- `scripts/run_peak_locked.sh`: performs the governor lock, optional `cset` shielding, runs the SPSC batched binary under `perf stat -r 7` (default), captures stdout/stderr and perf output in `/tmp/bchan_spsc_peak_<ts>` and restores system state on exit.
- `scripts/run_scaling_locked.sh`: loops a set of batch sizes (1,4,16,64,256) and writes `scaling_locked.log` into `/tmp/bchan_scaling_locked_<ts>`.

Design updates (v0.2.x)

1) Consumer O(1) Fast-Path: generation counters + lazy tail caching
- Problem: earlier designs required an O(P) scan of producer tails on every dequeue to compute the min tail and determine emptiness. For P large this is costly.
- Idea: maintain a per-producer monotonic generation counter that changes whenever a producer advances its tail beyond previously observed values. The consumer keeps a cached min-tail and only updates it when it observes progress or a potential empty condition.
- Effect: the common-case consumer read (when buffer has items) becomes O(1) — read `consumer_head`, check cached_min_tail; if cached_min_tail > head, we can consume without scanning. A full O(P) scan is needed only when cached_min_tail == head (potential empty) or when `active_producers == 0` (final drain).

2) Reserve/Commit semantics clarified
- `reserveBatch(&ptrs)` returns pointers to contiguous buffer slots and records the intended reservation in the producer's `reserved` field without advancing the tail.
- `commitBatch(n)` advances the producer tail with `.release` ordering and resets `reserved`. The producer must not write beyond the reserved count.
- These semantics ensure safe zero-copy fills while preserving linearizability: other readers will not observe partially filled slots because `tail` advancement is the linearizing action.

3) Memory ordering and padding rules
- Producer `tail` writes use `.release` for visibility; consumer `head` uses `.acquire` when reading dependent data.
- Per-producer `tail` fields are cache-line aligned and padded to avoid false sharing.
- `active_producers` is modified under `.release` on register/unregister and read `.acquire` by the consumer to know when a final drain is safe.

Correctness notes
- Linearizability: enqueue's linearization point is the `.release` store of the producer's `tail` (or `commitBatch`); dequeue linearization is `consumer_head` advancement.
- No lost-wake: futex wait/wake uses a swap/clear pattern for waiter counters to avoid races where a wake comes before a waiter increments its counter.
- Producer registration: `registerProducer()` allocates a per-producer slot and increments `active_producers` with `.release`. Unregister decrements with `.acq_rel` and may trigger final wake behavior.

Bench details and tips
- Batch size tuning: batched SPSC peaks in the 64–256 batch range on our hardware; MPSC uses larger aggregate batches across producers.
- Buffer sizing: power-of-two capacities are required; prefer large buffers (64K+) for high-throughput sustained runs.
- Pin producer/consumer to separate physical cores (not logical siblings) to reduce interference.

Files and artifacts
- `docs/design.md` (this file): living design + reproducibility notes.
- `bchan_algorithm.md`: original historical paper (untouched).
- `scripts/run_peak_locked.sh`, `scripts/run_scaling_locked.sh`: reproducible measurement scripts.

Next steps (suggested)
- Review this draft and provide additional correctness details you want preserved (e.g., exact pseudocode for generation counters, state diagrams for producer registration lifecycle).
- After approval, add this file to the docs index and link it from `README.md` and `CHANGELOG.md`.

Acknowledgements
- This living document collects the final measurement and correctness work done in November 2025 and should be kept up-to-date as the project evolves.
