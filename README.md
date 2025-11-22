# bchan


[![CI](https://github.com/boonzy00/bchan/actions/workflows/ci.yml/badge.svg)](https://github.com/boonzy00/bchan/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15+-orange.svg)](https://ziglang.org/)
[![Throughput](https://img.shields.io/badge/throughput-MPSC__968M__%E2%80%A2__SPSC__150M__%2Fs-orange)](scripts/)

A high-performance, lock-free multi-producer single-consumer (MPSC) channel implementation in Zig, designed for low-latency concurrent messaging.

## Features

- **Lock-free MPSC**: Per-producer tail pointers eliminate contention
- **Zero-copy batch API**: Reserve/commit for efficient bulk operations
- **Futex-based blocking**: Energy-efficient waiting with exponential backoff
- **Dynamic producers**: Safe registration and retirement with termination guarantees
- **SPSC/SPMC support**: Unified API for different producer/consumer patterns
- **Production-ready**: Comprehensive tests and benchmarks

## Installation

Add to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .bchan = .{
            .url = "https://github.com/boonzy00/bchan/archive/refs/tags/v0.2.0.tar.gz",
            .hash = "1220xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", // Run `zig fetch --save <url>` to get the actual hash
        },
    },
}
```

Then in `build.zig`:

```zig
const bchan = b.addModule("bchan", .{
    .source_file = .{ .path = "deps/bchan/src/lib.zig" },
});
```

## Usage

### Basic MPSC Channel

```zig
const std = @import("std");
const bchan = @import("bchan");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create MPSC channel with 4 max producers
    const ch = try bchan.Channel(u64).init(allocator, 1024, .MPSC, 4);
    defer ch.deinit();

    // Register a producer
    const producer = try ch.registerProducer();
    defer ch.unregisterProducer(producer);

    // Send messages
    try std.testing.expect(producer.trySend(42));
    try std.testing.expect(producer.trySend(1337));

    // Receive messages
    const val1 = ch.tryReceive();
    const val2 = ch.tryReceive();

    std.debug.print("Received: {} {}\n", .{val1.?, val2.?});
}
```

### Batch Operations

```zig
// Reserve space for batch
var ptrs: [64]?*u64 = undefined;
const reserved = producer.reserveBatch(&ptrs);
if (reserved > 0) {
    // Fill the batch
    for (0..reserved) |i| {
        if (ptrs[i]) |ptr| {
            ptr.* = i;
        }
    }
    // Commit atomically
    producer.commitBatch(reserved);
}

// Receive batch
var buf: [64]u64 = undefined;
const received = ch.tryReceiveBatch(&buf);
```

### Blocking Operations

```zig
// Blocking send
producer.send(42);

// Blocking receive
const val = ch.receive();
```

## Examples

See `examples/simple.zig` for a basic usage example, and `benches/` for complete benchmark examples.

- `benches/batch.zig` - High-throughput MPSC with batching
- `benches/spsc.zig` - SPSC performance test
- `benches/mpsc_vyukov.zig` - Vyukov MPMC comparison

## Benchmarks

Run benchmarks with:

```sh
# Build optimized binaries
zig build -Doptimize=ReleaseFast

# Run MPSC benchmark 5 times with stats
./scripts/run_bench_mpsc.sh

# Run Vyukov comparison
./scripts/run_vyukov.sh
```

### Benchmarks (AMD Ryzen 7 5700G • Zig 0.15.0 • ReleaseFast)

| Scenario                  | Producers | Throughput       | Notes                                    |
|---------------------------|-----------|------------------|------------------------------------------|
| MPSC (batched, zero-copy) | 16        | 968 M msg/s      | Mean of 5 runs                           |
| MPSC (batched, zero-copy) | 4         | 798 M msg/s      | Mean of 5 runs                           |
| SPSC (batched, zero-copy) | 1         | 150 M msg/s      | Mean of 7 runs, σ ≈ 10 M msg/s, governor-locked |
| SPSC (single-message)     | 1         | 8–15 M msg/s     | For comparison                           |
| Vyukov MPMC (4p4c)        | 4         | 19 M msg/s       | Reference implementation                 |

**Performance Comparison**
```
bchan MPSC (16p, batched)      ██████████████████████████████ 968 M/s
bchan SPSC (batched, 1p1c)     ████████████████████ 150 M/s
bchan SPSC (single-msg)        ███████ 8–15 M/s
Vyukov MPMC                    ██ 19 M/s
```

All figures measured with CPU governor locked to performance and cores 0/1 isolated via `cset shield`.
Reproducibility note: Batched SPSC throughput measured via `scripts/run_peak_locked.sh` (batch=64, 35 s duration, 7 repetitions). Individual run values ranged from 128–156 M msg/s; mean 150 M msg/s, σ ≈ 10 M msg/s. See `scripts/run_peak_locked.sh` (SPSC) and `scripts/run_scaling_locked.sh` (batch sweep) for one-click reproducible commands.

## API Reference

### Channel Creation

```zig
pub fn init(allocator: std.mem.Allocator, capacity: u64, mode: Mode, max_producers: u32) !Channel(T)
pub fn deinit(self: *Channel(T)) void
```

### Producer Registration

```zig
pub fn registerProducer(self: *Channel(T)) !ProducerHandle
pub fn unregisterProducer(self: *Channel(T), handle: ProducerHandle) void
```

### Send Operations

```zig
pub fn trySend(self: ProducerHandle, item: T) bool
pub fn send(self: ProducerHandle, item: T) void
pub fn trySendBatch(self: ProducerHandle, items: []const T) usize
pub fn sendBatch(self: ProducerHandle, items: []const T) usize
```

### Batch Reserve/Commit

```zig
pub fn reserveBatch(self: ProducerHandle, ptrs: []?*T) usize
pub fn commitBatch(self: ProducerHandle, count: usize) void
```

### Receive Operations

```zig
pub fn tryReceive(self: *Channel(T)) ?T
pub fn receive(self: *Channel(T)) T
pub fn tryReceiveBatch(self: *Channel(T), buffer: []T) usize
pub fn receiveBatch(self: *Channel(T), buffer: []T) usize
```

See [`bchan_algorithm.md`](bchan_algorithm.md) for detailed algorithm documentation.

## Documentation

- **[API Reference](docs/api.md)**: Complete API documentation with examples
- **[Performance Guide](docs/performance.md)**: Optimization techniques and benchmarking
- **[Development Guide](docs/development.md)**: Contributing and development workflows
- **[Algorithm Details](bchan_algorithm.md)**: Technical implementation details

## Testing

Run the full test suite:

```sh
zig build test
```

Includes correctness tests for all modes, edge cases, and concurrent scenarios.

## Contributing

Contributions welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) file.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Related Projects

- [crossbeam-channel](https://github.com/crossbeam-rs/crossbeam) - Rust channels
- [moodycamel::ConcurrentQueue](https://github.com/cameron314/concurrentqueue) - C++ lock-free queues
- [zig-gamedev](https://github.com/zig-gamedev) - Zig game development ecosystem
- Experiment with backoff strategies, padding/alignment, and futex thresholds to tune performance.
- Add CI jobs to run tests and (optionally) quick benches on supported runners.
Add CI jobs to run tests and (optionally) quick benches on supported runners.
