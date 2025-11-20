# bchan Development Guide

This guide covers development workflows, testing, and contribution guidelines for bchan.

## Project Structure

```
bchan/
├── src/                    # Core library
│   ├── lib.zig            # Public API and convenience functions
│   ├── channel.zig        # Main channel implementation
│   └── vyukov.zig         # Vyukov MPMC reference implementation
├── benches/               # Performance benchmarks
│   ├── batch.zig          # MPSC batch benchmark
│   ├── spsc.zig           # SPSC benchmark
│   └── mpsc_vyukov.zig    # Vyukov comparison
├── tests/                 # Test suites
│   ├── all.zig            # Unit tests
│   └── stress.zig         # Stress and edge case tests
├── scripts/               # Benchmark and utility scripts
├── docs/                  # Documentation
├── build.zig              # Build configuration
└── README.md              # User documentation
```

## Development Setup

### Prerequisites

- Zig 0.15.0+
- Linux/macOS/Windows (CI tests all platforms)
- `perf` tool (Linux) for benchmarking

### Building

```bash
# Build library and tests
zig build

# Run tests
zig build test

# Build optimized benchmarks
zig build -Doptimize=ReleaseFast

# Run benchmarks
zig build -Doptimize=ReleaseFast bench
```

### Development Workflow

1. **Fork and clone** the repository
2. **Create feature branch**: `git checkout -b feature/my-feature`
3. **Make changes** with tests
4. **Run tests**: `zig build test`
5. **Run benchmarks** to ensure no regressions
6. **Update documentation** if needed
7. **Commit and push**
8. **Create pull request**

## Testing

### Unit Tests

Run comprehensive test suite:

```bash
zig build test
```

Tests cover:
- Basic send/receive operations
- Batch operations
- Producer registration/unregistration
- Edge cases (empty/full queues)
- Memory safety
- Thread safety

### Stress Tests

Run extended stress tests:

```bash
zig test tests/stress.zig
```

Tests include:
- High-throughput scenarios
- Long-running stability
- Producer churn
- Memory pressure
- Blocking operations

### Benchmark Validation

Ensure benchmarks still work:

```bash
zig build -Doptimize=ReleaseFast
./scripts/run_all_benches.sh
```

### CI Testing

GitHub Actions runs on:
- Ubuntu (primary)
- macOS
- Windows

CI includes:
- Build verification
- Test execution
- Benchmark runs

## Code Style

### Zig Conventions

Follow standard Zig style:
- 4-space indentation
- `camelCase` for functions/variables
- `PascalCase` for types
- `snake_case` for file names
- Comprehensive error handling
- Clear documentation comments

### Documentation

```zig
/// Brief description of function
/// 
/// Detailed explanation with parameters and return values
/// 
/// Example:
/// ```zig
/// const result = myFunction(param);
/// ```
pub fn myFunction(param: Type) ReturnType {
    // Implementation
}
```

### Naming Conventions

- **Types**: `Channel`, `ProducerHandle`, `ChannelMode`
- **Functions**: `trySend`, `registerProducer`, `reserveBatch`
- **Variables**: `consumer_head`, `producer_waiters`
- **Constants**: `DEBUG_PRINTS`, `version`

## Implementation Guidelines

### Thread Safety

- All public APIs thread-safe within documented constraints
- Use atomics for shared state
- Proper memory barriers
- No internal locking

### Memory Management

- RAII-style allocation/deallocation
- No hidden allocations in hot paths
- Cache-aligned critical structures
- Power-of-2 buffer sizes

### Error Handling

- Return errors for configuration issues
- Panic only for programming errors
- Clear error messages
- Safe cleanup on errors

### Performance

- Minimize atomic operations
- Cache-friendly data layout
- Batch operations for throughput
- Efficient blocking with futex

## Adding Features

### New Channel Modes

1. Add to `ChannelMode` enum
2. Implement mode-specific logic in channel.zig
3. Add convenience constructor in lib.zig
4. Update tests and benchmarks
5. Document in API reference

### New Operations

1. Design API for consistency
2. Implement for all relevant modes
3. Add comprehensive tests
4. Update documentation
5. Consider performance impact

### Benchmarks

1. Create new bench file in `benches/`
2. Add build configuration in `build.zig`
3. Add script in `scripts/`
4. Update performance documentation

## Debugging

### Debug Builds

```bash
zig build -Doptimize=Debug
```

Includes:
- Bounds checking
- Debug prints (if `DEBUG_PRINTS = true`)
- Slower execution for analysis

### Instrumentation

Access internal counters:

```zig
std.debug.print("Wakes: {}\n", .{ch.futex_wake_count.load(.monotonic)});
std.debug.print("Waits: {}\n", .{ch.futex_wait_count.load(.monotonic)});
```

### Logging

Enable debug prints in channel.zig:

```zig
const DEBUG_PRINTS = true;
```

### Memory Debugging

Use Zig's leak detection:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{ .retain_metadata = true }){};
defer std.debug.assert(gpa.deinit() == .ok);
```

## Performance Analysis

### Profiling

```bash
# Record profile
perf record -F 1000 ./zig-out/bin/bench-mpsc

# Generate flame graph
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

### Benchmark Comparison

Always compare against baseline:

```bash
# Before changes
./scripts/run_bench_mpsc.sh > before.txt

# After changes
./scripts/run_bench_mpsc.sh > after.txt

# Compare
diff before.txt after.txt
```

### Regression Detection

- Run benchmarks on multiple runs
- Check for >5% performance changes
- Verify on different hardware if possible

## Contributing

### Pull Request Process

1. **Describe changes** clearly
2. **Reference issues** if applicable
3. **Include tests** for new functionality
4. **Update documentation**
5. **Ensure CI passes**

### Code Review Checklist

- [ ] Tests pass
- [ ] Benchmarks show no regression
- [ ] Documentation updated
- [ ] Code style consistent
- [ ] Thread safety verified
- [ ] Memory safety checked

### Issue Reporting

Use GitHub issues for:
- Bug reports with reproduction steps
- Feature requests with use cases
- Performance issues with benchmarks
- Documentation improvements

## Release Process

### Versioning

Follow semantic versioning:
- **Major**: Breaking API changes
- **Minor**: New features
- **Patch**: Bug fixes

### Release Checklist

- [ ] Update version in `src/lib.zig`
- [ ] Update README with new features
- [ ] Run full test suite
- [ ] Run benchmark suite
- [ ] Update documentation
- [ ] Create annotated git tag
- [ ] Publish to GitHub releases

### Maintenance

- Monitor GitHub issues
- Review pull requests promptly
- Keep dependencies updated
- Run benchmarks regularly