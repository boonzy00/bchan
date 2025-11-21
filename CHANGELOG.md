# Changelog

All notable changes to bchan will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-11-21

### Added
- Generation counters and cached tails for O(1) amortized consumer operations
- Scales to 512+ producers without performance degradation
- Watchdog timeout in benchmarks to prevent hangs during development
- New architecture documentation with design patterns and invariants
- Automated scaling benchmark script with mean-of-5 runs

### Changed
- Consumer `tryReceiveMPSC` now uses lazy cached tails with invalidation on producer churn
- Added authoritative full-scan fallback when no active producers remain
- Updated README benchmarks with scaling results (357-968 M msg/s)
- Bumped installation URL to v0.2.0 in README

### Performance
- MPSC scaling (AMD Ryzen 7 5700G, mean of 5 runs):
  - 1 producer: 357 M msg/s
  - 4 producers: 798 M msg/s
  - 16 producers: 968 M msg/s
  - 64 producers: 734 M msg/s
  - 256 producers: 605 M msg/s
  - 512 producers: 519 M msg/s
- Zero API breakage, all tests pass

### Documentation
- Added `docs/architecture.md` with design patterns and invariants
- Added `docs/bench-results.md` with reproducible commands and results
- Updated `docs/performance.md` with v0.2.0 scaling table
- Minor clarifications in `docs/api.md`

## [0.1.0] - 2025-11-20

### Added
- Initial release of bchan, a high-performance lock-free channel library for Zig
- Support for SPSC, MPSC, and SPMC channel modes
- Zero-copy batch operations with reserve/commit API
- Futex-based blocking with exponential backoff
- Dynamic producer registration for MPSC
- Comprehensive test suite and benchmarks
- MIT license

### Features
- Lock-free MPSC with per-producer tail pointers
- Cache-aligned atomics for optimal performance
- Instrumentation counters for debugging
- Production-ready error handling and memory safety

### Performance
- MPSC: ~156 M msg/s (4 producers, 64-msg batches)
- SPSC: ~85+ M msg/s
- Vyukov MPMC comparison: ~19 M msg/s

### Documentation
- Complete API reference
- Performance optimization guide
- Development and contribution guidelines
- Algorithm implementation details