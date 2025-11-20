# Contributing to bchan

Thank you for your interest in contributing to bchan! This document provides guidelines and information for contributors.

## Code of Conduct

This project follows a code of conduct inspired by the [Contributor Covenant](https://www.contributor-covenant.org/). Please be respectful and constructive in all interactions.

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs, request features, or ask questions
- Check existing issues first to avoid duplicates
- Provide detailed reproduction steps, expected vs actual behavior
- Include your Zig version, OS, and hardware details

### Contributing Code

1. **Fork the repository** and create a feature branch
2. **Write tests** for new functionality
3. **Ensure all tests pass**: `zig build test`
4. **Run benchmarks** to check for regressions: `./scripts/run_all_benches.sh`
5. **Follow the code style**:
   - Use `zig fmt` for formatting
   - 4-space indentation
   - Clear, descriptive names
   - Comprehensive documentation comments
6. **Update documentation** if needed
7. **Submit a pull request** with a clear description

### Development Setup

```bash
# Clone and build
git clone https://github.com/boonzy00/bchan
cd bchan
zig build

# Run tests
zig build test

# Run benchmarks
zig build -Doptimize=ReleaseFast
./scripts/run_all_benches.sh
```

### Testing

- **Unit tests**: `zig build test` - covers basic functionality and edge cases
- **Stress tests**: `zig test tests/stress.zig` - long-running concurrent scenarios
- **Benchmarks**: Compare performance against baselines

### Benchmarking

When making performance changes:

1. Run benchmarks 5+ times to account for variance
2. Compare against the main branch
3. Include hardware details in PR description
4. Explain the performance impact

### Documentation

- Update README.md for user-facing changes
- Update docs/api.md for API changes
- Update docs/performance.md for performance notes
- Keep examples in examples/ working

## Architecture Decisions

### Design Principles

- **Lock-free**: No blocking system calls in hot paths
- **Cache-aware**: 64-byte alignment for critical structures
- **Producer-scalable**: Per-producer tail pointers
- **Safe defaults**: Conservative API design

### Code Organization

- `src/lib.zig`: Public API and convenience functions
- `src/channel.zig`: Core channel implementation
- `src/vyukov.zig`: Reference MPMC implementation
- `tests/`: Comprehensive test suite
- `benches/`: Performance benchmarks
- `docs/`: Documentation

## Performance Guidelines

- Minimize atomic operations in hot paths
- Use batch operations for throughput
- Prefer non-blocking over blocking APIs
- Cache-line align shared state
- Profile with `perf` and flame graphs

## Review Process

1. **Automated checks**: CI runs tests and benchmarks
2. **Code review**: At least one maintainer review
3. **Testing**: Ensure new code is well-tested
4. **Documentation**: PRs should include relevant docs
5. **Performance**: No regressions without justification

## Areas for Contribution

### High Priority
- Additional channel modes (SPMC optimizations)
- NUMA-aware memory allocation
- SIMD batch operations
- Hardware transactional memory support

### Medium Priority
- Alternative blocking strategies
- Priority queues
- Compression for large batches
- RDMA/distributed support

### Low Priority
- Additional language bindings
- GUI benchmarking tools
- Alternative backends

## Getting Help

- **GitHub Issues**: For bugs and feature requests
- **GitHub Discussions**: For questions and design discussions
- **Zig community**: Discord, forums, or Reddit

## License

By contributing, you agree to license your contributions under the same MIT license as the project.