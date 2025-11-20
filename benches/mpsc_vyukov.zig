const std = @import("std");
const Vy = @import("bchan").VyukovQueue;

pub fn main() !void {
    // Pin to first N CPUs (if linux)
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        var mask: linux.cpu_set_t = undefined;
        @memset(@as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)], 0);
        // Set bits for first 8 CPUs
        const bytes = @as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)];
        bytes[0] = 0xFF;
        bytes[1] = 0xFF; // optionally up to 16
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(&mask));
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const producers = 4;
    const messages_per_producer: usize = 1_000_000;

    // Vyukov queue capacity
    const qcap = 1 << 16;
    var q = try Vy(u64).init(alloc, qcap);
    defer q.deinit();

    var handles: [producers]std.Thread = undefined;

    var timer = try std.time.Timer.start();

    // Start consumer
    const total = @as(u64, producers * messages_per_producer);
    const cons = try std.Thread.spawn(.{}, struct {
        fn f(queue: *Vy(u64), total_msgs: u64) void {
            var seen: u64 = 0;
            while (seen < total_msgs) {
                const v = queue.dequeue();
                _ = v; // discard
                seen += 1;
            }
        }
    }.f, .{ q, total });

    // small pause to let consumer start
    for (0..1000) |_| _ = std.Thread.yield() catch {};

    for (0..producers) |i| {
        handles[i] = try std.Thread.spawn(.{}, struct {
            fn f(queue: *Vy(u64), n: usize) void {
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    queue.enqueue(@as(u64, j));
                }
            }
        }.f, .{ q, messages_per_producer });
    }

    for (0..producers) |i| handles[i].join();
    cons.join();

    const ns = timer.read();
    const total_msgs = @as(f64, @floatFromInt(producers * messages_per_producer));
    const mps = total_msgs * 1e9 / @as(f64, @floatFromInt(ns)) / 1e6;

    std.debug.print("Vyukov MPMC queue ({} producers): {d:.2} M msg/s\n", .{ producers, mps });
}
