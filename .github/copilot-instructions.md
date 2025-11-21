**Purpose**: Brief, actionable guidance for AI agents editing `bchan` — a high-performance Zig MPSC/SPSC/SPMC channel library.

- **Big Picture**: `bchan` implements a bounded, lock-free channel in Zig. The core type is `Channel(T)` in `src/channel.zig`. `src/lib.zig` exposes convenience constructors; `src/vyukov.zig` contains a reference Vyukov queue used in benchmarks. Algorithm details live in `bchan_algorithm.md` and higher-level docs in `docs/`.

- **Modes & API**: The channel supports `.SPSC`, `.MPSC`, and `.SPMC` modes. For MPSC you must call `registerProducer()` / `unregisterProducer()` and use the returned `ProducerHandle` to `trySend`, `send`, `reserveBatch`, `commitBatch`, and batch send helpers. See `src/channel.zig` and `tests/all.zig` for examples.

- **Key files to inspect**: `src/channel.zig` (core implementation), `src/lib.zig` (public API), `bchan_algorithm.md` (design rationale), `build.zig` (build/test/bench targets), `tests/all.zig` (test patterns), `benches/*` and `scripts/*` (bench usage).

- **Build / Test / Bench commands**:
  - Build and run tests: `zig build test` (invokes `tests/all.zig`).
  - Run benches (release): `zig build -Doptimize=ReleaseFast` then use `./scripts/run_bench_mpsc.sh` or `./scripts/run_vyukov.sh`.
  - `build.zig` exposes run artifacts named `bench-mpsc`, `bench-spsc`, and `bench-mpsc-vyukov` — use `zig build bench-mpsc` as needed.

- **Concurrency patterns & invariants (must preserve)**:
  - Per-producer tails: each producer has its own `tail` field (aligned/padded) to avoid contention; do not collapse or re-layout these without performance testing. See `Producer` in `src/channel.zig`.
  - Buffer capacity is rounded to a power-of-two (`ceilPowerOfTwo`) and indexing uses `& mask`. Respect this when changing indexing logic.
  - Atomic ordering is intentional: producer `tail` writes use `.release`, consumer `head` uses `.acquire/.release` pairs. Changing memory orderings can break correctness.
  - Futex wait/wake: `producer_waiters` and `consumer_waiters` are used for blocking; backoff thresholds (spin → exponential → futex) are implemented in `send`/`receive` paths (look for `backoff > 512`).

- **Batch semantics**:
  - `reserveBatch` returns pointers to buffer slots without advancing the tail; `commitBatch` advances the producer tail and must be called with the previously reserved count. Tests show usage in `tests/all.zig` (search `reserveBatch` / `commitBatch`).

- **MPSC-specific constraints**:
  - `init(..., .MPSC, max_producers)` requires a non-zero `max_producers`. The `producers` array is allocated only in MPSC mode; `registerProducer()` assigns a slot (fail with `TooManyProducers` if exhausted).
  - Consumer correctness relies on scanning producer tails to compute `min_tail`. Avoid optimizations that remove or substantially alter that scan without re-verifying invariants and tests.

- **Testing & instrumentation**:
  - Unit tests in `tests/all.zig` cover edge cases and concurrent semantics. Run `zig build test` after edits.
  - Debug helpers: `debugConsumerHead()` and `debugProducerTail(id)` in `src/channel.zig`. Counters `futex_wait_count` and `futex_wake_count` exist for futex instrumentation — useful when validating wake/wait behavior.

- **Benchmarks**:
  - Bench targets use `b.addModule` in `build.zig`. Bench binaries are installed by the build and invoked by scripts in `scripts/`.
  - When modifying core concurrency logic, re-run `benches/batch.zig` and `benches/mpsc_vyukov.zig` to compare throughput.

- **Code-change heuristics for PRs**:
  - Preserve `align(64)` / padding for atomic fields unless replacing with a measured improvement.
  - Keep `capacity` power-of-two behavior and `mask` indexing unless changing all usages consistently.
  - Add tests to `tests/all.zig` for any change that touches concurrency, memory ordering, or producer/consumer lifecycles.
  - If adding new API surfaces, update `README.md` usage snippets and `docs/api.md`.

- **Where to look for subtle bugs**:
  - Off-by-one in tail/head arithmetic and wraparound handling.
  - Lost-wake scenarios when editing futex logic: check `swap(0, .acq_rel)` / `fetchAdd` bookkeeping.
  - Producer registration/unregistration race with consumer termination (check `active_producers`).

- **Examples to copy from repo**:
  - `tests/all.zig` shows typical `MPSC` usage: `registerProducer()` → `reserveBatch`/`commitBatch` or `trySendBatch` → `unregisterProducer()`.
  - `examples/simple.zig` shows minimal end-user usage.

If anything in these notes is unclear or you want more depth (e.g., detailed memory-order reasoning or a checklist for making safe concurrency changes), tell me which area to expand and I will iterate.
