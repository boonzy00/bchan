# bchan API Reference

This document provides a comprehensive reference for the bchan lock-free channel library.

## Overview

bchan implements high-performance, lock-free channels for Zig with support for SPSC, MPSC, and SPMC patterns. The library uses atomic operations, futex-based blocking, and per-producer tail pointers to minimize contention.

## Core Types

### Channel(T)

The main channel type, parameterized by the element type `T`.

```zig
const Channel = @import("bchan").Channel;
const ch = try Channel(u64).init(allocator, 1024, .MPSC, 4);
```

#### Initialization

```zig
pub fn init(allocator: std.mem.Allocator, capacity: usize, mode: ChannelMode, max_producers: usize) !*Channel(T)
```

- `capacity`: Buffer size (automatically rounded up to next power of 2)
- `mode`: Channel mode (`.SPSC`, `.MPSC`, `.SPMC`)
- `max_producers`: Maximum producers for MPSC (non-zero required for `.MPSC`)

Important implementation notes:

- `capacity` is rounded to the next power-of-two and indexing uses `index = pos & mask` to avoid slow modulo operations.
- For `.MPSC` mode you must pass a non-zero `max_producers`; the producer array and per-producer cached fields are allocated based on this value.


#### Deinitialization

```zig
pub fn deinit(self: *Self) void
```

Frees all allocated memory. Must unregister all producers first.

### ChannelMode

```zig
pub const ChannelMode = enum { SPSC, MPSC, SPMC };
```

- `SPSC`: Single-producer, single-consumer
- `MPSC`: Multi-producer, single-consumer
- `SPMC`: Single-producer, multi-consumer

### ProducerHandle

Handle for MPSC producers. Obtained via `registerProducer()`.

```zig
const handle = try ch.registerProducer();
defer ch.unregisterProducer(handle);
```

## Send Operations

### Non-blocking Send

```zig
pub fn trySend(self: *Self, value: T) bool  // SPSC/SPMC only
pub fn trySend(self: ProducerHandle, value: T) bool  // MPSC
```

Returns `true` if sent, `false` if buffer full.

### Blocking Send

```zig
pub fn send(self: *Self, value: T) void  // SPSC/SPMC only
pub fn send(self: ProducerHandle, value: T) void  // MPSC
```

Blocks until space available using exponential backoff then futex wait.

### Batch Send (Non-blocking)

```zig
pub fn trySendBatch(self: *Self, items: []const T) usize  // SPSC/SPMC only
pub fn trySendBatch(self: ProducerHandle, items: []const T) usize  // MPSC
```

Sends as many items as possible from slice. Returns count sent.

### Batch Send (Blocking)

```zig
pub fn sendBatch(self: *Self, items: []const T) usize  // SPSC/SPMC only
pub fn sendBatch(self: ProducerHandle, items: []const T) usize  // MPSC
```

Sends all items, blocking as needed. Returns total sent (always `items.len`).

### Channel Management

```zig
pub fn close(self: *Self) void
pub fn isClosed(self: *Self) bool
```

`close()` marks the channel as closed, preventing further sends and waking all blocked operations. `isClosed()` checks if the channel is closed.

## Receive Operations

### Non-blocking Receive

```zig
pub fn tryReceive(self: *Self) ?T
```

Returns `null` if empty.

### Blocking Receive

```zig
pub fn receive(self: *Self) T
```

Blocks until item available.

### Batch Receive (Non-blocking)

```zig
pub fn tryReceiveBatch(self: *Self, buffer: []T) usize
```

Fills buffer with available items. Returns count received.

### Batch Receive (Blocking)

```zig
pub fn receiveBatch(self: *Self, buffer: []T) usize
```

Blocks until at least one item received. Returns count (may be less than `buffer.len`).

## Producer Management (MPSC only)

### Registration

```zig
pub fn registerProducer(self: *Self) !ProducerHandle
```

Registers a new producer. Fails if `max_producers` reached.

### Unregistration

```zig
pub fn unregisterProducer(self: *Self, handle: ProducerHandle) void
```

Unregisters producer. Safe to call from any thread.

## Debug/Instrumentation

### Debug Accessors

```zig
pub fn debugConsumerHead(self: *Self) u64
pub fn debugProducerTail(self: *Self, id: usize) u64
```

Access internal indices for debugging. Not thread-safe.

### Instrumentation Counters

Available via atomic loads:

- `futex_wake_count`: Number of futex wakes
- `futex_wait_count`: Number of futex waits
- `active_producers`: Current active producer count

## Algorithm Details

### Ring Buffer

- Fixed-size ring buffer with power-of-2 capacity
- Head: Consumer position (items before head are consumed)
- Tail: Producer position (items at/before tail are produced)

### SPSC Implementation

- Single shared tail atomic
- Consumer head atomic
- Simple compare for empty/full

### MPSC Implementation

- Per-producer tail atomics
- Consumer scans minimum tail across all producers
- Eliminates producer contention

### SPMC Implementation

- Single shared tail atomic
- Consumer head atomic with CAS
- Allows multiple consumers

### Blocking Mechanism

- Exponential backoff spin (1-1024 iterations)
- Futex wait when backoff exhausted
- Wake on state changes

### Memory Layout

- Cache-aligned atomics (64-byte alignment)
- Producer array for MPSC
- Buffer padded for cache efficiency

## Error Conditions

- `MpscRequiresMaxProducers`: MPSC mode with `max_producers = 0`
- `TooManyProducers`: Exceeded `max_producers` limit
- `NotMpscChannel`: Producer operations on non-MPSC channel

## Performance Characteristics

### Throughput

- MPSC: ~150-170 M msg/s (4 producers, 64-msg batches)
- SPSC: ~85+ M msg/s
- Vyukov MPMC: ~18-19 M msg/s (comparison baseline)

### Latency

- Lock-free fast path: ~10-20ns
- Blocking path: ~1-10μs (futex overhead)

### Scalability

- MPSC scales linearly with producers (up to cache limits)
- SPSC/SPMC optimal for single producer/consumer

## Thread Safety

- All operations thread-safe within mode constraints
- MPSC: Multiple producers, single consumer
- SPSC: One producer, one consumer
- SPMC: One producer, multiple consumers

## Memory Safety

- No allocations during send/receive
- Bounds-checked operations
- Safe producer registration/unregistration
- RAII-style cleanup via `deinit()`

## Examples

See `benches/` and `tests/` directories for comprehensive examples.

### Basic Usage

```zig
const ch = try bchan.newMPSC(u64, allocator, 1024, 4);
defer ch.deinit();

const prod = try ch.registerProducer();
defer ch.unregisterProducer(prod);

// Send
try std.testing.expect(prod.trySend(42));

// Receive
const val = ch.tryReceive();
try std.testing.expectEqual(@as(u64, 42), val.?);
```

### Batch Operations

```zig
var items = [_]u64{1, 2, 3, 4};
const sent = prod.trySendBatch(&items);
try std.testing.expectEqual(@as(usize, 4), sent);

var buf = [_]u64{0} ** 4;
const received = ch.tryReceiveBatch(&buf);
try std.testing.expectEqual(@as(usize, 4), received);
```

### Zero-copy Batch

```zig
var ptrs: [64]?*u64 = undefined;
const reserved = prod.reserveBatch(&ptrs);
for (0..reserved) |i| {
    if (ptrs[i]) |p| p.* = i;
}
prod.commitBatch(reserved);
```