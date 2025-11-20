const std = @import("std");

const DEBUG_PRINTS = false;

pub const ChannelMode = enum { SPSC, MPSC, SPMC };

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Producer = struct {
            tail: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
            active: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(false),
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
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            if (self.producers.len > 0) {
                self.allocator.free(self.producers);
            }
            self.allocator.destroy(self);
        }

        pub fn registerProducer(self: *Self) !ProducerHandle {
            if (self.mode != .MPSC) return error.NotMpscChannel;
            const id = self.next_producer_id.fetchAdd(1, .monotonic);
            if (id >= self.max_producers) return error.TooManyProducers;
            self.producers[id].active.store(true, .monotonic);
            const prev_active = self.active_producers.fetchAdd(1, .monotonic);
            if (prev_active == 0) {
                _ = self.futex_wake_count.fetchAdd(1, .monotonic);
                std.Thread.Futex.wake(&self.consumer_waiters, 1);
            }
            return ProducerHandle{ .id = id, .channel = self };
        }

        pub fn unregisterProducer(self: *Self, handle: ProducerHandle) void {
            if (self.mode != .MPSC or handle.channel != self) return;
            self.producers[handle.id].active.store(false, .monotonic);
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

            // Always scan min_tail for correctness
            var min_tail = head + self.capacity;
            for (self.producers) |*p| {
                if (!p.active.load(.acquire)) continue;
                const t = p.tail.load(.acquire);
                if (t < min_tail) min_tail = t;
            }
            self.consumer_cached_min_tail.store(min_tail, .release);

            // If min_tail == head there are no items available.
            if (min_tail == head) return null;

            // If min_tail was not updated (remained head + capacity) and there
            // are no active producers, treat as empty. When producers are
            // active and min_tail == head + capacity it indicates the queue
            // is full (distance == capacity) and should not be treated as
            // empty — allow consumption to proceed.
            if (min_tail == head + @as(u64, self.capacity) and self.active_producers.load(.acquire) == 0) return null;

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
            return received;
        }

        pub fn receiveBatch(self: *Self, buffer: []T) usize {
            var received: usize = 0;
            var backoff: usize = 1;
            while (received == 0) {
                received = self.tryReceiveBatch(buffer);
                if (received == 0) {
                    for (0..backoff) |_| std.atomic.spinLoopHint();
                    backoff = @min(backoff * 2, 1024);
                    if (backoff > 512) {
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
