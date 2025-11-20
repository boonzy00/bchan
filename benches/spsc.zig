const std = @import("std");
const Channel = @import("bchan").Channel;

pub fn main() !void {
    // Pin main thread to CPU 0, but producer/consumer will pin themselves
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        var mask: linux.cpu_set_t = undefined;
        @memset(@as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)], 0);
        const bytes = @as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)];
        bytes[0] = 1; // CPU 0
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(&mask));
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const ch = try Channel(u64).init(a, 1024, .SPSC, 0);
    defer ch.deinit();

    const iterations: usize = 100_000_000;
    var sum = std.atomic.Value(u64).init(0);

    var timer = try std.time.Timer.start();

    const producer_thread = try std.Thread.spawn(.{}, struct {
        fn f(c: *Channel(u64), n: usize) void {
            // Pin producer to CPU 0
            if (@import("builtin").os.tag == .linux) {
                const linux = std.os.linux;
                var mask: linux.cpu_set_t = undefined;
                @memset(@as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)], 0);
                const bytes = @as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)];
                bytes[0] = 1; // CPU 0
                _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(&mask));
            }
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                while (!c.trySend(i)) std.atomic.spinLoopHint();
            }
        }
    }.f, .{ ch, iterations });

    const consumer_thread = try std.Thread.spawn(.{}, struct {
        fn f(c: *Channel(u64), n: usize, s: *std.atomic.Value(u64)) void {
            // Pin consumer to CPU 1
            if (@import("builtin").os.tag == .linux) {
                const linux = std.os.linux;
                var mask: linux.cpu_set_t = undefined;
                @memset(@as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)], 0);
                const bytes = @as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)];
                bytes[0] = 2; // CPU 1
                _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(&mask));
            }
            var received: usize = 0;
            var local_sum: u64 = 0;
            while (received < n) {
                if (c.tryReceive()) |value| {
                    local_sum +%= value;
                    received += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            s.store(local_sum, .release);
        }
    }.f, .{ ch, iterations, &sum });

    producer_thread.join();
    consumer_thread.join();

    const dt = timer.read();
    const duration_s = @as(f64, @floatFromInt(dt)) / 1_000_000_000.0;
    const throughput = @as(f64, @floatFromInt(iterations)) / duration_s;

    const expected_sum = @divTrunc(iterations * (iterations - 1), 2);
    const actual_sum = sum.load(.acquire);

    std.debug.print("SPSC: {d:.2} M ops/sec ", .{throughput / 1_000_000.0});
    if (expected_sum == actual_sum) {
        std.debug.print("✓\n", .{});
    } else {
        std.debug.print("✗ FAIL (sum {} != {})\n", .{ actual_sum, expected_sum });
    }
}
