const std = @import("std");
const testing = std.testing;
const bchan = @import("bchan");

// Stress tests for high-load scenarios, performance validation, and edge cases

test "Stress: High-throughput MPSC" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 65536, .MPSC, 8);
    defer ch.deinit();

    const num_producers = 8;
    const msgs_per_prod = 10000;

    var producers: [num_producers]bchan.Channel(u64).ProducerHandle = undefined;
    for (&producers) |*p| {
        p.* = try ch.registerProducer();
    }
    defer for (producers) |p| {
        ch.unregisterProducer(p);
    };

    // Producer threads
    var prod_threads: [num_producers]std.Thread = undefined;
    for (prod_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, producerFn, .{ producers[i], @as(u64, i) * msgs_per_prod, msgs_per_prod });
    }

    // Consumer thread
    var cons_thread = try std.Thread.spawn(.{}, consumerFn, .{ &ch, num_producers * msgs_per_prod });

    // Join all
    for (prod_threads) |t| t.join();
    cons_thread.join();
}

fn producerFn(prod: bchan.Channel(u64).ProducerHandle, start: u64, count: usize) void {
    for (0..count) |i| {
        while (!prod.trySend(start + i)) {
            std.atomic.spinLoopHint();
        }
    }
}

fn consumerFn(ch: *bchan.Channel(u64), expected: usize) void {
    var received: usize = 0;
    while (received < expected) {
        if (ch.tryReceive() != null) {
            received += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

test "Stress: Long-running stability" {
    const ch = try bchan.Channel(u32).init(testing.allocator, 1024, .MPSC, 4);
    defer ch.deinit();

    const duration_ms = 1000; // 1 second
    const start_time = std.time.milliTimestamp();

    var producers: [4]bchan.Channel(u32).ProducerHandle = undefined;
    for (&producers) |*p| {
        p.* = try ch.registerProducer();
    }
    defer for (producers) |p| {
        ch.unregisterProducer(p);
    };

    // Continuous send/receive
    var prod_thread = try std.Thread.spawn(.{}, continuousProducer, .{ &producers, start_time + duration_ms });
    var cons_thread = try std.Thread.spawn(.{}, continuousConsumer, .{ ch, start_time + duration_ms });

    prod_thread.join();
    cons_thread.join();
}

fn continuousProducer(prods: []bchan.Channel(u32).ProducerHandle, end_time: i64) void {
    var counter: u32 = 0;
    while (std.time.milliTimestamp() < end_time) {
        for (prods) |p| {
            _ = p.trySend(counter);
            counter +%= 1;
        }
    }
}

fn continuousConsumer(ch: *bchan.Channel(u32), end_time: i64) void {
    while (std.time.milliTimestamp() < end_time) {
        _ = ch.tryReceive();
    }
}

test "Stress: Producer churn" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 256, .MPSC, 10);
    defer ch.deinit();

    const iterations = 100;

    for (0..iterations) |_| {
        var prod = try ch.registerProducer();
        _ = prod.trySend(42);
        ch.unregisterProducer(prod);

        // Consumer drains
        _ = ch.tryReceive();
    }
}

test "Stress: Batch operations under load" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 4096, .MPSC, 4);
    defer ch.deinit();

    var producers: [4]bchan.Channel(u64).ProducerHandle = undefined;
    for (&producers) |*p| {
        p.* = try ch.registerProducer();
    }
    defer for (producers) |p| {
        ch.unregisterProducer(p);
    };

    // Batch producers
    var prod_threads: [4]std.Thread = undefined;
    for (prod_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, batchProducer, .{ producers[i], 1000 });
    }

    // Batch consumer
    var cons_thread = try std.Thread.spawn(.{}, batchConsumer, .{ ch, 4000 });

    for (prod_threads) |t| t.join();
    cons_thread.join();
}

fn batchProducer(prod: bchan.Channel(u64).ProducerHandle, batches: usize) void {
    var buf: [64]u64 = undefined;
    for (0..batches) |b| {
        for (0..64) |i| buf[i] = b * 64 + i;
        _ = prod.trySendBatch(&buf);
    }
}

fn batchConsumer(ch: *bchan.Channel(u64), expected: usize) void {
    var buf: [64]u64 = undefined;
    var received: usize = 0;
    while (received < expected) {
        const count = ch.tryReceiveBatch(&buf);
        received += count;
    }
}

test "Stress: Memory pressure" {
    // Test with small allocations to check for leaks
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ch = try bchan.Channel(u64).init(alloc, 128, .MPSC, 2);
    defer ch.deinit();

    var prod1 = try ch.registerProducer();
    var prod2 = try ch.registerProducer();
    defer ch.unregisterProducer(prod1);
    defer ch.unregisterProducer(prod2);

    // Send/receive many items
    for (0..1000) |_| {
        _ = prod1.trySend(1);
        _ = prod2.trySend(2);
        _ = ch.tryReceive();
        _ = ch.tryReceive();
    }
}

test "Stress: Blocking operations timeout" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 1, .SPSC, 0);
    defer ch.deinit();

    // Fill
    ch.send(1);

    // Producer should block, but we don't wait long
    var sent = false;
    const prod_thread = try std.Thread.spawn(.{}, struct {
        fn f(c: *bchan.Channel(u64), s: *bool) void {
            c.send(2);
            s.* = true;
        }
    }.f, .{ &ch, &sent });

    // Consume to unblock
    _ = ch.receive();

    prod_thread.join();
    try testing.expect(sent);
}

test "Stress: Varying producer counts" {
    const max_prods = 16;
    const ch = try bchan.Channel(u32).init(testing.allocator, 2048, .MPSC, max_prods);
    defer ch.deinit();

    for (1..max_prods + 1) |num_prods| {
        var producers: [max_prods]bchan.Channel(u32).ProducerHandle = undefined;
        var active: [max_prods]bool = [_]bool{false} ** max_prods;

        // Register
        for (0..num_prods) |i| {
            producers[i] = try ch.registerProducer();
            active[i] = true;
        }

        // Send
        for (0..num_prods) |i| {
            if (active[i]) _ = producers[i].trySend(@intCast(i));
        }

        // Receive
        for (0..num_prods) |_| {
            _ = ch.tryReceive();
        }

        // Unregister
        for (0..num_prods) |i| {
            if (active[i]) ch.unregisterProducer(producers[i]);
        }
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
