# Changelog

All notable changes to bchan will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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