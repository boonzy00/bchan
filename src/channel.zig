const std = @import("std");

const DEBUG_PRINTS = false;

pub const ChannelMode = enum { SPSC, MPSC, SPMC };

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Producer = struct {
            tail: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
            active: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(false),
            gen: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
            // Consumer-side cached view of this producer's tail and gen.
            // Updated by the consumer to avoid reloading `tail` when
            // the producer hasn't changed.
            cached_tail: u64 = 0,
            cached_gen: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
            reserved: usize = 0,
        };

        pub const ProducerHandle = struct {
            id: usize,
            channel: *Self,

            pub fn trySend(self: ProducerHandle, value: T) bool {
                const ch = self.channel;
                if (ch.closed.load(.acquire)) return false;
                const p = &ch.producers[self.id];
                const tail = p.tail.load(.monotonic);
                const head = ch.consumer_head.load(.acquire);

                if ((tail -% head) >= ch.capacity) return false;

                ch.buffer[tail & ch.mask] = value;
                p.tail.store(tail + 1, .release);
                _ = p.gen.fetchAdd(1, .release);

                if (tail == head) {
                    if (ch.consumer_waiters.load(.monotonic) > 0) {
                        _ = ch.futex_wake_count.fetchAdd(1, .monotonic);
                        std.Thread.Futex.wake(&ch.consumer_waiters, std.math.maxInt(u32));
                    }
                }
                return true;
            }

            pub fn send(self: ProducerHandle, value: T) void {
                while (!self.trySend(value)) {
                    const prev = self.channel.producer_waiters.fetchAdd(1, .monotonic);
                    const expected = @as(u32, prev + 1);
                    if (self.trySend(value)) {
                        _ = self.channel.producer_waiters.fetchSub(1, .monotonic);
                        break;
                    }
                    _ = self.channel.futex_wait_count.fetchAdd(1, .monotonic);
                    _ = self.channel.futex_wait_count.fetchAdd(1, .monotonic);
                    std.Thread.Futex.wait(&self.channel.producer_waiters, expected);
                }
            }

            pub fn trySendBatch(self: ProducerHandle, items: []const T) usize {
                const ch = self.channel;
                const p = &ch.producers[self.id];
                const tail = p.tail.load(.monotonic);
                const head = ch.consumer_head.load(.acquire);
                // Compute max_tail for correct available space
                var max_tail: u64 = 0;
                for (ch.producers) |*prod| {
                    const t = prod.tail.load(.acquire);
                    if (t > max_tail) max_tail = t;
                }
                const available = ch.capacity -| (max_tail -% head);
                const n = @min(available, items.len);

                if (n == 0) return 0;

                for (items[0..n], 0..) |item, i| {
                    ch.buffer[(tail + i) & ch.mask] = item;
                }

                p.tail.store(tail + n, .release);
                _ = p.gen.fetchAdd(1, .release);
                if (tail == head) {
                    if (ch.consumer_waiters.load(.monotonic) > 0) {
                        _ = ch.futex_wake_count.fetchAdd(1, .monotonic);
                        std.Thread.Futex.wake(&ch.consumer_waiters, std.math.maxInt(u32));
                    }
                }
                return n;
            }

            pub fn sendBatch(self: ProducerHandle, items: []const T) usize {
                var sent: usize = 0;
                while (sent < items.len) {
                    const n = self.trySendBatch(items[sent..]);
                    if (n == 0) {
                        // Block
                        const prev = self.channel.producer_waiters.fetchAdd(1, .monotonic);
                        const expected = @as(u32, prev + 1);
                        const n2 = self.trySendBatch(items[sent..]);
                        if (n2 > 0) {
                            _ = self.channel.producer_waiters.fetchSub(1, .monotonic);
                            sent += n2;
                            continue;
                        }
                        std.Thread.Futex.wait(&self.channel.producer_waiters, expected);
                    } else {
                        sent += n;
                    }
                }
                return sent;
            }

            pub fn reserveBatch(self: ProducerHandle, ptrs: []?*T) usize {
                const ch = self.channel;
                const p = &ch.producers[self.id];
                const tail = p.tail.load(.monotonic);
                const head = ch.consumer_head.load(.acquire);
                // Compute max_tail for correct available space
                var max_tail: u64 = 0;
                for (ch.producers) |*prod| {
                    const t = prod.tail.load(.acquire);
                    if (t > max_tail) max_tail = t;
                }
                const available = ch.capacity -| (max_tail -% head);
                const n = @min(available, ptrs.len);

                if (n == 0) return 0;

                for (0..n) |i| {
                    ptrs[i] = &ch.buffer[(tail + i) & ch.mask];
                }

                p.reserved = n;
                return n;
            }

            pub fn commitBatch(self: ProducerHandle, count: usize) void {
                const ch = self.channel;
                const p = &ch.producers[self.id];
                const tail = p.tail.load(.monotonic);

                std.debug.assert(count == p.reserved);
                p.tail.store(tail + count, .release);
                p.reserved = 0;

                _ = p.gen.fetchAdd(1, .release);

                const head_snapshot = ch.consumer_head.load(.acquire);
                if (tail == head_snapshot) {
                    if (ch.consumer_waiters.load(.monotonic) > 0) {
                        std.Thread.Futex.wake(&ch.consumer_waiters, std.math.maxInt(u32));
                    }
                }
            }
        };

        allocator: std.mem.Allocator,
        mode: ChannelMode,
        capacity: usize,
        mask: usize,

        buffer: []align(64) T,

        consumer_head: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
        sp_tail: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),

        producer_waiters: std.atomic.Value(u32) align(64) = std.atomic.Value(u32).init(0),
        consumer_waiters: std.atomic.Value(u32) align(64) = std.atomic.Value(u32).init(0),
        active_producers: std.atomic.Value(u32) align(64) = std.atomic.Value(u32).init(0),
        // Instrumentation counters for futex activity
        futex_wake_count: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        futex_wait_count: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),

        consumer_cached_min_tail: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),

        // Hint sized at init time; kept for informational purposes.
        max_producers_hint: usize = 0,

        max_producers: usize = 0,
        producers: []Producer = &[_]Producer{},
        next_producer_id: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),

        closed: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, size: usize, mode: ChannelMode, max_prods: usize) !*Self {
            const cap = std.math.ceilPowerOfTwo(usize, size) catch unreachable;
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const buffer = try alloc.alignedAlloc(T, @enumFromInt(6), cap);
            errdefer alloc.free(buffer);

            var producers: []Producer = &[_]Producer{};
            if (mode == .MPSC) {
                if (max_prods == 0) return error.MpscRequiresMaxProducers;
                producers = try alloc.alignedAlloc(Producer, @enumFromInt(6), max_prods);
                errdefer alloc.free(producers);
                for (producers) |*p| p.* = .{};
            }

            self.* = .{
                .allocator = alloc,
                .mode = mode,
                .capacity = cap,
                .mask = cap - 1,
                .buffer = buffer,
                .max_producers = max_prods,
                .producers = producers,
                .max_producers_hint = if (mode == .MPSC) max_prods else 0,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            if (self.producers.len > 0) {
                self.allocator.free(self.producers);
            }
            // No separate cached arrays to free; per-producer cached fields
            // live inside the `producers` allocation which is freed above.
            self.allocator.destroy(self);
        }

        pub fn registerProducer(self: *Self) !ProducerHandle {
            if (self.mode != .MPSC) return error.NotMpscChannel;
            const id = self.next_producer_id.fetchAdd(1, .monotonic);
            if (id >= self.max_producers) return error.TooManyProducers;
            // Initialize producer state and bump generation so the consumer
            // doesn't rely on stale cached values.
            const p = &self.producers[id];
            p.tail.store(0, .monotonic);
            p.reserved = 0;
            p.cached_tail = 0;
            p.cached_gen.store(0, .monotonic);
            p.gen.store(p.gen.load(.monotonic) + 1, .monotonic);
            p.active.store(true, .monotonic);
            const prev_active = self.active_producers.fetchAdd(1, .monotonic);
            if (prev_active == 0) {
                _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                std.Thread.Futex.wake(&self.consumer_waiters, 1);
            }
            return ProducerHandle{ .id = id, .channel = self };
        }

        pub fn unregisterProducer(self: *Self, handle: ProducerHandle) void {
            if (self.mode != .MPSC or handle.channel != self) return;
            const p = &self.producers[handle.id];
            // Mark inactive first. Use release ordering so that stores
            // prior to this (tail/gen updates) are visible to a consumer
            // that observes `active` as false.
            p.active.store(false, .release);
            // Optional ordering barrier: store tail to ensure any in-flight
            // writes are ordered (no-op but may help some architectures).
            const cur_tail = p.tail.load(.monotonic);
            _ = p.tail.store(cur_tail, .monotonic);
            // Bump generation with release ordering to invalidate any
            // consumer cached view of this producer's tail.
            _ = p.gen.fetchAdd(1, .release);

            // Decrement active producer count. If this was the last active
            // producer, wake the consumer so it can do a final authoritative
            // drain and terminate.
            const prev = self.active_producers.fetchSub(1, .release);
            if (prev == 1) {
                _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                std.Thread.Futex.wake(&self.consumer_waiters, std.math.maxInt(u32));
            }
        }

        // Debug accessors for benches: read internal indices safely.
        pub fn debugConsumerHead(self: *Self) u64 {
            return self.consumer_head.load(.acquire);
        }

        pub fn debugProducerTail(self: *Self, id: usize) u64 {
            if (id >= self.producers.len) return 0;
            return self.producers[id].tail.load(.acquire);
        }

        inline fn trySendSP(self: *Self, value: T) bool {
            const tail = self.sp_tail.load(.monotonic);
            const head = self.consumer_head.load(.acquire);
            if ((tail -% head) >= self.capacity) return false;

            self.buffer[tail & self.mask] = value;
            self.sp_tail.store(tail + 1, .release);

            if (tail == head) {
                const waiters = self.consumer_waiters.swap(0, .acq_rel);
                if (waiters > 0) {
                    _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                    std.Thread.Futex.wake(&self.consumer_waiters, std.math.maxInt(u32));
                }
            }
            return true;
        }

        inline fn tryReceiveSPSC(self: *Self) ?T {
            const head = self.consumer_head.load(.monotonic);
            const tail = self.sp_tail.load(.acquire);
            if (head == tail) return null;

            const value = self.buffer[head & self.mask];
            self.consumer_head.store(head + 1, .release);

            const was_full = ((tail - head) >= @as(u64, self.capacity));
            if (was_full) {
                const waiters = self.producer_waiters.swap(0, .acq_rel);
                if (waiters > 0) {
                    _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                    std.Thread.Futex.wake(&self.producer_waiters, std.math.maxInt(u32));
                }
            }
            return value;
        }

        inline fn tryReceiveSPMC(self: *Self) ?T {
            var head = self.consumer_head.load(.monotonic);
            const tail = self.sp_tail.load(.acquire);

            while (head < tail) {
                if (self.consumer_head.cmpxchgWeak(head, head + 1, .acq_rel, .monotonic)) |updated| {
                    head = updated;
                    continue;
                }

                const value = self.buffer[head & self.mask];

                const was_full = ((tail - head) >= @as(u64, self.capacity));
                if (was_full) {
                    const waiters = self.producer_waiters.swap(0, .acq_rel);
                    if (waiters > 0) {
                        std.Thread.Futex.wake(&self.producer_waiters, std.math.maxInt(u32));
                    }
                }
                return value;
            }
            return null;
        }

        inline fn tryReceiveMPSC(self: *Self) ?T {
            const head = self.consumer_head.load(.monotonic);

            var min_tail: u64 = head + @as(u64, self.capacity);

            // Use per-producer generation counters + consumer-side cache.
            // Only reload a producer's `tail` if its generation changed.
            var i: usize = 0;
            while (i < self.producers.len) : (i += 1) {
                const p = &self.producers[i];
                if (!p.active.load(.acquire)) continue;
                const gen = p.gen.load(.acquire);
                const cached_gen = p.cached_gen.load(.monotonic);
                if (gen == cached_gen) {
                    const cached_t = p.cached_tail;
                    if (cached_t < min_tail) min_tail = cached_t;
                    continue;
                }
                const t = p.tail.load(.acquire);
                p.cached_tail = t;
                p.cached_gen.store(gen, .release);
                if (t < min_tail) min_tail = t;
            }

            self.consumer_cached_min_tail.store(min_tail, .release);

            // If min_tail == head there are no items available.
            if (min_tail == head) return null;

            // Safety fallback: if there are no active producers, perform a
            // full authoritative scan of producer tails (ignoring caches)
            // to determine emptiness. This handles rare cases where the
            // consumer's cached view is stale during producer retire and
            // avoids hanging termination.
            if (self.active_producers.load(.acquire) == 0) {
                var full_min: u64 = head + @as(u64, self.capacity);
                var j: usize = 0;
                while (j < self.producers.len) : (j += 1) {
                    const pp = &self.producers[j];
                    const t = pp.tail.load(.acquire);
                    if (t < full_min) full_min = t;
                }
                self.consumer_cached_min_tail.store(full_min, .release);
                if (full_min == head) return null;
            }

            const value = self.buffer[head & self.mask];
            self.consumer_head.store(head + 1, .release);

            const old_filled: u64 = min_tail - head;

            if (old_filled == @as(u64, self.capacity)) {
                const waiters = self.producer_waiters.swap(0, .acq_rel);
                if (waiters > 0) {
                    _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                    std.Thread.Futex.wake(&self.producer_waiters, std.math.maxInt(u32));
                }
            }
            return value;
        }

        pub inline fn trySend(self: *Self, value: T) bool {
            if (self.closed.load(.acquire)) return false;
            return switch (self.mode) {
                .SPSC, .SPMC => self.trySendSP(value),
                .MPSC => @panic("MPSC requires ProducerHandle.trySend()"),
            };
        }

        pub fn send(self: *Self, value: T) void {
            var backoff: usize = 1;
            while (!self.trySend(value)) {
                for (0..backoff) |_| std.atomic.spinLoopHint();
                backoff = @min(backoff * 2, 1024);
                if (backoff > 512) {
                    const prev = self.producer_waiters.fetchAdd(1, .monotonic);
                    if (self.trySend(value)) {
                        _ = self.producer_waiters.fetchSub(1, .monotonic);
                        backoff = 1;
                        continue;
                    }
                    std.Thread.Futex.wait(&self.producer_waiters, @as(u32, prev + 1));
                    backoff = 1;
                }
            }
        }

        pub fn trySendBatch(self: *Self, items: []const T) usize {
            var sent: usize = 0;
            while (sent < items.len) {
                if (self.trySend(items[sent])) {
                    sent += 1;
                } else break;
            }
            return sent;
        }

        pub fn sendBatch(self: *Self, items: []const T) usize {
            var sent: usize = 0;
            while (sent < items.len) {
                self.send(items[sent]);
                sent += 1;
            }
            return sent;
        }

        pub inline fn tryReceive(self: *Self) ?T {
            return switch (self.mode) {
                .SPSC => self.tryReceiveSPSC(),
                .MPSC => self.tryReceiveMPSC(),
                .SPMC => self.tryReceiveSPMC(),
            };
        }

        pub fn receive(self: *Self) T {
            var backoff: usize = 1;
            while (true) {
                if (self.tryReceive()) |value| return value;
                for (0..backoff) |_| std.atomic.spinLoopHint();
                backoff = @min(backoff * 2, 1024);
                if (backoff > 512) {
                    const prev = self.consumer_waiters.fetchAdd(1, .monotonic);
                    const expected = @as(u32, prev + 1);
                    if (self.tryReceive()) |value| {
                        _ = self.consumer_waiters.fetchSub(1, .monotonic);
                        return value;
                    }
                    _ = self.futex_wait_count.fetchAdd(1, .monotonic);
                    std.Thread.Futex.wait(&self.consumer_waiters, expected);
                    backoff = 1;
                }
            }
        }

        pub fn tryReceiveBatch(self: *Self, buffer: []T) usize {
            var received: usize = 0;
            while (received < buffer.len) {
                if (self.tryReceive()) |value| {
                    buffer[received] = value;
                    received += 1;
                } else break;
            }

            // If we didn't receive anything, and there are no active
            // producers, perform an authoritative fresh scan of all
            // producer tails (ignore consumer caches). This ensures
            // that stale cached_tail values from retired producers do
            // not cause the caller to spin forever.
            if (received == 0 and self.active_producers.load(.acquire) == 0) {
                var fresh_min_tail: u64 = self.consumer_head.load(.acquire) + self.capacity;
                var idx: usize = 0;
                while (idx < self.producers.len) : (idx += 1) {
                    const p = &self.producers[idx];
                    const t = p.tail.load(.acquire);
                    if (t < fresh_min_tail) fresh_min_tail = t;
                }
                if (fresh_min_tail <= self.consumer_head.load(.acquire)) {
                    return received; // truly empty
                }
            }
            return received;
        }

        pub fn receiveBatch(self: *Self, buffer: []T) usize {
            var received: usize = 0;
            var backoff: usize = 1;
            while (received == 0) {
                received = self.tryReceiveBatch(buffer);
                if (received == 0) {
                    // If there are no active producers left, force an
                    // authoritative fresh scan of all producer tails to
                    // avoid stale cached_tail values preventing termination.
                    if (self.active_producers.load(.acquire) == 0) {
                        var fresh_min_tail: u64 = self.consumer_head.load(.acquire) + self.capacity;
                        var kk: usize = 0;
                        while (kk < self.producers.len) : (kk += 1) {
                            const pp = &self.producers[kk];
                            const t = pp.tail.load(.acquire);
                            if (t < fresh_min_tail) fresh_min_tail = t;
                        }
                        if (fresh_min_tail <= self.consumer_head.load(.acquire)) {
                            return received; // truly empty
                        }
                        // else fall through and continue spinning/waiting
                    }
                    for (0..backoff) |_| std.atomic.spinLoopHint();
                    backoff = @min(backoff * 2, 1024);
                    if (backoff > 512) {
                        // If there are no active producers left, perform an
                        // authoritative fresh scan of all producer tails
                        // (ignore consumer caches) to determine emptiness.
                        // This prevents a stale cached_tail from keeping the
                        // consumer spinning forever after all producers retire.
                        if (self.active_producers.load(.acquire) == 0) {
                            var real_min_tail: u64 = self.consumer_head.load(.acquire) + self.capacity;
                            var k: usize = 0;
                            while (k < self.producers.len) : (k += 1) {
                                const pp = &self.producers[k];
                                const t = pp.tail.load(.acquire);
                                if (t < real_min_tail) real_min_tail = t;
                            }
                            if (real_min_tail == self.consumer_head.load(.acquire)) {
                                return received; // queue empty and no producers
                            }
                        }

                        const prev = self.consumer_waiters.fetchAdd(1, .monotonic);
                        const expected = @as(u32, prev + 1);
                        received = self.tryReceiveBatch(buffer);
                        if (received != 0) {
                            _ = self.consumer_waiters.fetchSub(1, .monotonic);
                            break;
                        }
                        _ = self.futex_wait_count.fetchAdd(1, .monotonic);
                        std.Thread.Futex.wait(&self.consumer_waiters, expected);
                        backoff = 1;
                    }
                }
            }
            return received;
        }

        pub fn reserveBatch(self: *Self, ptrs: []?*T) usize {
            if (self.mode == .MPSC) return 0;

            const tail = self.sp_tail.load(.monotonic);
            const head = self.consumer_head.load(.acquire);
            const available = self.capacity -| (tail -% head);
            const n = @min(available, ptrs.len);

            if (n == 0) return 0;

            for (0..n) |i| {
                ptrs[i] = &self.buffer[(tail + i) & self.mask];
            }
            return n;
        }

        pub fn close(self: *Self) void {
            if (self.closed.cmpxchgWeak(false, true, .acq_rel, .monotonic) != null) return; // Already closed

            // Wake all waiting producers and consumers
            const prod_waiters = self.producer_waiters.swap(0, .acq_rel);
            if (prod_waiters > 0) {
                std.Thread.Futex.wake(&self.producer_waiters, std.math.maxInt(u32));
            }
            const cons_waiters = self.consumer_waiters.swap(0, .acq_rel);
            if (cons_waiters > 0) {
                std.Thread.Futex.wake(&self.consumer_waiters, std.math.maxInt(u32));
            }
        }

        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }
    };
}
