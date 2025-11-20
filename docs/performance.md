# bchan Performance Guide

This guide covers performance optimization, benchmarking, and tuning bchan channels.

## Benchmarking Setup

### Hardware Considerations

- **CPU Affinity**: Pin threads to specific cores to reduce migration overhead
- **NUMA**: Run on single NUMA node for consistent memory access
- **Hyperthreading**: Disable or account for sibling core interference

### Benchmark Scripts

Use the provided scripts for consistent results:

```bash
# Run MPSC benchmark 5 times with stats
./scripts/run_bench_mpsc.sh

# Run Vyukov comparison
./scripts/run_vyukov.sh

# Run all benchmarks
./scripts/run_all_benches.sh
```

### Perf Integration

Benchmarks include `perf stat` output for detailed hardware counters:

```bash
taskset -c 0-7 perf stat -d -r1 ./zig-out/bin/bench-mpsc
```

Key metrics:
- Instructions per cycle (IPC)
- Cache miss rates
- Branch mispredictions
- Context switches

## Performance Results

### Current Benchmarks (AMD Ryzen 7 5700G)

| Configuration | Throughput | Notes |
|---------------|------------|-------|
| MPSC (4p1c, 64-msg batches) | 156 M msg/s | Mean of 5 runs |
| SPSC | 85+ M msg/s | Single-threaded |
| Vyukov MPMC (4p4c) | 19 M msg/s | Reference implementation |

### Scaling Characteristics

- **Producer Scaling**: MPSC throughput increases with producers (up to ~8-16)
- **Batch Size**: Larger batches reduce overhead (64-256 optimal)
- **Buffer Size**: 1K-1M capacity shows minimal impact above 4K

## Optimization Techniques

### Batch Operations

Use batch APIs for high-throughput scenarios:

```zig
// Instead of:
for (items) |item| {
    prod.send(item);
}

// Use:
_ = prod.sendBatch(&items);
```

### Zero-copy Batching

For maximum performance in MPSC:

```zig
var ptrs: [BATCH_SIZE]?*T = undefined;
const reserved = prod.reserveBatch(&ptrs);
for (0..reserved) |i| {
    if (ptrs[i]) |p| p.* = computeValue(i);
}
prod.commitBatch(reserved);
```

### Buffer Sizing

- **Small buffers**: Lower latency, higher contention
- **Large buffers**: Higher throughput, more memory usage
- **Power-of-2**: Required for efficient indexing

### Thread Affinity

Pin producer/consumer threads to different cores:

```zig
// Linux example
const linux = std.os.linux;
var mask: linux.cpu_set_t = undefined;
linux.CPU_SET(0, &mask);  // Pin to CPU 0
linux.sched_setaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
```

## Memory Layout

### Cache Alignment

All critical atomics are 64-byte aligned:

```zig
consumer_head: std.atomic.Value(u64) align(64)
producer_waiters: std.atomic.Value(u32) align(64)
```

### False Sharing Prevention

- Producer structures padded to cache lines
- Separate cache lines for different atomics
- Buffer elements sized for cache efficiency

### Memory Orderings

- **Acquire/Release**: For synchronization
- **Monotonic**: For counters and progress
- **Relaxed**: Where possible for performance

## Blocking Behavior

### Backoff Strategy

Exponential backoff before futex wait:

```zig
var backoff: usize = 1;
while (!tryOp()) {
    for (0..backoff) |_| std.atomic.spinLoopHint();
    backoff = @min(backoff * 2, 1024);
    if (backoff > 512) {
        futexWait();
        backoff = 1;
    }
}
```

### Futex Usage

- **Wake**: Single wake for batch operations
- **Wait**: With timeout for responsiveness
- **Counters**: Track wake/wait frequency for tuning

## Profiling

### Instrumentation

Access internal counters:

```zig
const wakes = ch.futex_wake_count.load(.monotonic);
const waits = ch.futex_wait_count.load(.monotonic);
```

### Flame Graphs

Use `perf record` with benchmarks:

```bash
perf record -F 1000 -g ./zig-out/bin/bench-mpsc
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

### Memory Profiling

Check allocations with Zig's allocator:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
```

## Tuning Guidelines

### For Low Latency

- Small buffer sizes (256-1024)
- Single items over batches
- Avoid blocking operations
- Pin threads to same core (if cache sharing beneficial)

### For High Throughput

- Large batches (64-256 items)
- Zero-copy reserve/commit
- Large buffers (64K+)
- Multiple producers with affinity

### For Energy Efficiency

- Prefer non-blocking operations
- Use futex waits over busy spinning
- Tune backoff parameters

## Common Pitfalls

### Producer Registration

Register producers before starting threads:

```zig
// Good
var prods: [4]ProducerHandle = undefined;
for (&prods) |*p| p.* = try ch.registerProducer();

// Bad - race condition
// Producers registering concurrently
```

### Consumer Termination

Check for active producers:

```zig
while (true) {
    const count = ch.tryReceiveBatch(&buf);
    if (count == 0) {
        if (ch.active_producers.load(.acquire) == 0) break;
        std.atomic.spinLoopHint();
    }
}
```

### Memory Barriers

Operations provide necessary barriers, but external synchronization may be needed for complex patterns.

## Comparison with Alternatives

### vs. Channels in Other Languages

- **Go**: GC overhead, goroutine scheduling
- **Rust crossbeam**: Similar lock-free design, comparable performance
- **C++ moodycamel**: Excellent baseline, bchan competitive

### vs. Mutex-based Queues

- **Throughput**: 10-100x higher
- **Latency**: 10-100x lower
- **Scalability**: Better with multiple producers

## Future Optimizations

### Potential Improvements

- NUMA-aware allocation
- SIMD batch operations
- Hardware transactional memory
- Custom memory allocators

### Experimental Features

- Adaptive spinning based on contention
- Priority queues
- Compression for large batches
- RDMA support for distributed systems