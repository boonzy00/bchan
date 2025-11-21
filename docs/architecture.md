# bchan Architecture & Design Patterns

This document summarizes the architecture, core design patterns, and invariants used by `bchan` (the bounded, lock-free MPSC channel).

Design Pattern IDs (canonical labels used in this project):

- `pattern:ring-buffer`: Fixed-size power-of-two ring buffer with `mask` indexing.
- `pattern:per-producer-tail`: Per-producer `tail` atomics to avoid producer contention.
- `pattern:gen-cache`: Per-producer generation counters + consumer-side cached_tail with lazy invalidation.
- `pattern:zero-copy-batch`: Reserve/commit zero-copy batching for producers.
- `pattern:backoff-futex`: Exponential backoff followed by futex wait/wake for blocking.
- `pattern:termination-broadcast`: Last-producer retirement semantics + authoritative final-scan fallback to guarantee termination.

Summary

- Producer-Consumer: The core concurrency model is multi-producer, single-consumer (MPSC). Producers exclusively advance their own `tail`; the consumer advances a single `consumer_head`.
- Lock-free fast-path: All hot-path operations avoid locks and only use atomics with carefully chosen memory orderings (monotonic / acquire / release) to preserve correctness without unnecessary fences.
- Cache-conscious layout: Key atomics are aligned to 64-byte cache lines and the `Producer` struct is padded to avoid false sharing between producers.

Key invariants

- `capacity` is a power-of-two; all indexing uses `index = pos & mask`.
- Producers only write to their own `tail` and buffer slots they own; the consumer only reads from buffer slots `head..min_tail-1`.
- Memory ordering:
  - Producers store `tail` with `.release` after writing the slot contents.
  - Consumer reads `min_tail` (producer tails) with `.acquire` to observe those writes.
- Registration/unregistration semantics for MPSC keep `active_producers` updated and use a generation counter bump (`gen.fetchAdd(1, .release)`) to ensure the consumer invalidates any stale cached view when a producer retires.

Why `gen-cache`?

The consumer scanning all producers on every dequeue is O(P) and quickly becomes a bottleneck as P grows. `gen-cache` lets the consumer keep a cached tail per producer and only reload it when the producer bumped its generation counter (i.e., it advanced its tail or retired). This makes the common path O(1) for the consumer while still guaranteeing correctness.

Final-drain correctness

When the last producer unregisters there is a pathological case where the consumer's cached view of an inactive producer's `cached_tail` may be stale and falsely indicate items remain. To handle this, `bchan` performs a single authoritative full scan of all producer `tail`s when `active_producers == 0`. This scan runs at most once per channel lifetime and ensures termination.

Notes on extensibility

- The patterns here are intentionally modular: you can swap the transport (e.g., use the Vyukov queue) or adjust backoff parameters without changing the correctness arguments.
- Any API changes that alter producer registration or per-producer layout must preserve the cache-line padding and atomic ordering invariants.

References

- Vyukov bounded MPMC queue (conceptual inspiration for ring index math)
- Crossbeam and Folly termination patterns (authoritative final-scan on last-producer retirement)

