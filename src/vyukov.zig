const std = @import("std");

pub fn VyukovQueue(comptime T: type) type {
    // For our benchmarks (T == u64) make each cell occupy a full 64-byte cache line
    // layout: seq (8) + data (8) + padding (48) = 64 bytes
    return struct {
        const Self = @This();

        const Cell = struct {
            seq: std.atomic.Value(u64) align(64),
            data: T,
            _pad: [48]u8,
        };

        allocator: std.mem.Allocator,
        capacity: usize,
        mask: usize,
        buffer: []Cell,
        enqueue_pos: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
        dequeue_pos: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),

        pub fn init(alloc: std.mem.Allocator, cap: usize) !*Self {
            const real_cap = std.math.ceilPowerOfTwo(usize, cap) catch unreachable;
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            var buf = try alloc.alignedAlloc(Cell, @enumFromInt(6), real_cap);
            errdefer alloc.free(buf);
            // Initialize sequence numbers
            var i: usize = 0;
            while (i < real_cap) : (i += 1) {
                buf[i].seq.store(@as(u64, i), .monotonic);
                // Leave data uninitialized
            }

            self.* = .{
                .allocator = alloc,
                .capacity = real_cap,
                .mask = real_cap - 1,
                .buffer = buf,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.destroy(self);
        }

        pub fn enqueue(self: *Self, value: T) void {
            // Claim a position with fetchAdd; then wait for slot->seq == pos
            const pos = self.enqueue_pos.fetchAdd(1, .acq_rel);
            const idx = (@as(usize, pos) & self.mask);
            var cell = &self.buffer[idx];
            // wait until slot seq equals pos
            while (true) {
                const seq = cell.seq.load(.acquire);
                if (seq == pos) break;
                std.atomic.spinLoopHint();
            }
            cell.data = value;
            cell.seq.store(pos + 1, .release);
        }

        pub fn tryEnqueue(self: *Self, value: T) bool {
            // Attempt to reserve a position if available by reading enqueue_pos and checking slot seq
            var pos = self.enqueue_pos.load(.acquire);
            while (true) {
                const idx = (@as(usize, pos) & self.mask);
                var cell = &self.buffer[idx];
                const seq = cell.seq.load(.acquire);
                const delta = seq - pos;
                if (delta == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .acquire) == pos) {
                        // We reserved it
                        cell.data = value;
                        cell.seq.store(pos + 1, .release);
                        return true;
                    }
                    // CAS failed, pos updated; reload and continue
                    pos = self.enqueue_pos.load(.acquire);
                    continue;
                } else if (delta < 0) {
                    // Slot seq behind pos -> queue is full
                    return false;
                } else {
                    // Slot already claimed by a future enq_pos, try to read pos again
                    pos = self.enqueue_pos.load(.acquire);
                    continue;
                }
            }
        }

        pub fn dequeue(self: *Self) T {
            const pos = self.dequeue_pos.fetchAdd(1, .acq_rel);
            const idx = (@as(usize, pos) & self.mask);
            var cell = &self.buffer[idx];

            while (true) {
                const seq = cell.seq.load(.acquire);
                // seq should be pos + 1 when an item is available
                if (seq == pos + 1) break;
                std.atomic.spinLoopHint();
            }

            const v = cell.data;
            cell.seq.store(pos + @as(u64, self.capacity), .release);
            return v;
        }

        pub fn tryDequeue(self: *Self, out: *T) bool {
            var pos = self.dequeue_pos.load(.acquire);
            while (true) {
                const idx = (@as(usize, pos) & self.mask);
                var cell = &self.buffer[idx];
                const seq = cell.seq.load(.acquire);
                const expected = pos + 1;
                const delta = seq - expected;
                if (delta == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .acquire) == pos) {
                        out.* = cell.data;
                        cell.seq.store(pos + @as(u64, self.capacity), .release);
                        return true;
                    }
                    pos = self.dequeue_pos.load(.acquire);
                    continue;
                } else if (sequenceLess(seq, expected)) {
                    // No item yet (empty)
                    return false;
                } else {
                    pos = self.dequeue_pos.load(.acquire);
                    continue;
                }
            }
        }

        inline fn sequenceLess(a: u64, b: u64) bool {
            // handles wraparound by treating as unsigned values
            return a < b;
        }
    };
}
