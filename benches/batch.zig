// bchan/benches/batch.zig
const std = @import("std");
const Channel = @import("bchan").Channel;

fn consumer_thread(c: *Channel(u64)) void {
    std.debug.print("[bench] consumer started\n", .{});

    var buf: [64]u64 = undefined;

    while (true) {
        const count = c.tryReceiveBatch(buf[0..]);
        if (count == 0) {
            const act = c.active_producers.load(.acquire);
            if (act == 0) break;
            std.atomic.spinLoopHint();
            continue;
        }
    }
}

fn producer_thread(prod: Channel(u64).ProducerHandle, n: usize) void {
    std.debug.print("[bench] producer start\n", .{});

    var ptrs: [64]?*u64 = undefined;

    var batch: usize = 0;
    while (batch < n) : (batch += 1) {
        var reserved: usize = 0;
        while (reserved == 0) {
            reserved = prod.reserveBatch(&ptrs);
            if (reserved == 0) std.atomic.spinLoopHint();
        }
        for (0..reserved) |j| {
            if (ptrs[j]) |pp| {
                pp.* = @as(u64, @intCast(batch)) * 1000 + @as(u64, @intCast(j));
            } else {
                @panic("reserveBatch returned null pointer");
            }
        }
        prod.commitBatch(reserved);
    }
    std.debug.print("[bench] producer exit\n", .{});
}

pub fn main() !void {
    // Pin to all available cores for multi-producer performance
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        var mask: linux.cpu_set_t = undefined;
        @memset(@as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)], 0);
        // Set bits for first 16 CPUs
        const bytes = @as([*]u8, @ptrCast(&mask))[0..@sizeOf(linux.cpu_set_t)];
        bytes[0] = 0xFF; // CPUs 0-7
        bytes[1] = 0xFF; // CPUs 8-15
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(&mask));
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const chan = try Channel(u64).init(a, 1_000_000, .MPSC, 4);
    defer chan.deinit();

    const producers = 4;
    const batch_size = 64;
    // Full production workload for benchmarking.
    const batches_per_prod = 50_000;

    var timer = try std.time.Timer.start();

    var threads: [producers + 1]std.Thread = undefined;

    // Register all producers up-front in the main thread to avoid races
    // between registration and the consumer/producers starting.
    var handles: [producers]Channel(u64).ProducerHandle = undefined;
    for (0..producers) |i| {
        handles[i] = try chan.registerProducer();
    }

    // Start consumer first so it's ready to drain and wake producers.
    threads[producers] = try std.Thread.spawn(.{}, struct {
        fn f(c: *Channel(u64)) void {
            std.debug.print("[bench] consumer started\n", .{});

            var buf: [batch_size]u64 = undefined;

            // Termination-safe consumer loop: keep receiving until all expected
            // messages are seen or there are no active producers and the queue is empty.
            while (true) {
                const count = c.tryReceiveBatch(buf[0..]);
                if (count == 0) {
                    // If no items now and no active producers, we're done.
                    const act = c.active_producers.load(.acquire);
                    if (act == 0) break;
                    // Otherwise spin and retry.
                    std.atomic.spinLoopHint();
                    continue;
                }

                // process the batch
            }
            // if (received >= total_msgs) break;

            // Final drain — catches any remaining items that arrived during the checks.
            // while (true) {
            //     const count = c.tryReceiveBatch(buf[0..]);
            //     if (count == 0) break;
            //     received += count;
            //     _ = cons_recv_ptr.fetchAdd(count, .monotonic);
            // }

            // std.debug.print("[bench] consumer finished\n", .{});
        }
    }.f, .{chan});

    // Small pause to ensure consumer is running before producers start.
    for (0..1000) |_| _ = std.Thread.yield() catch {};

    const ProducerFn = struct {
        fn f(prod: Channel(u64).ProducerHandle, n: usize) void {
            std.debug.print("[bench] producer start\n", .{});
            var batch: usize = 0;
            var ptrs: [batch_size]?*u64 = undefined;

            while (batch < n) : (batch += 1) {
                var reserved: usize = 0;
                while (reserved == 0) {
                    reserved = prod.reserveBatch(&ptrs);
                    if (reserved == 0) std.atomic.spinLoopHint();
                }
                for (0..reserved) |j| {
                    if (ptrs[j]) |pp| {
                        pp.* = @as(u64, @intCast(batch)) * 1000 + @as(u64, @intCast(j));
                    } else {
                        @panic("reserveBatch returned null pointer");
                    }
                }
                prod.commitBatch(reserved);
            }
            // Producer thread exits; producer will be unregistered by main thread.
            std.debug.print("[bench] producer exit\n", .{});
        }
    };

    for (0..producers) |i| {
        const prod_handle = handles[i];
        threads[i] = try std.Thread.spawn(.{}, ProducerFn.f, .{ prod_handle, batches_per_prod });
    }

    // Join producers then unregister handles
    for (0..producers) |i| {
        threads[i].join();
        std.debug.print("[bench] join producer {d}\n", .{i});
        chan.unregisterProducer(handles[i]);
        std.debug.print("[bench] unregistered producer {d}\n", .{i});
    }

    // Join consumer
    threads[producers].join();

    const ns = timer.read();
    const total = @as(f64, @floatFromInt(producers * batches_per_prod * batch_size));
    const mps = total * 1e9 / @as(f64, @floatFromInt(ns)) / 1e6;
    std.debug.print("Batch (4p1c, 64-msg batches): {d:.2} M msg/s\n", .{mps});
}
