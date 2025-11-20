const std = @import("std");
const testing = std.testing;
const bchan = @import("bchan");

test "SPSC basic send/receive" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 16, .SPSC, 0);
    defer ch.deinit();

    try testing.expect(ch.trySend(42));
    const val = ch.tryReceive();
    try testing.expect(val != null);
    try testing.expectEqual(@as(u64, 42), val.?);
}

test "SPSC full buffer" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 4, .SPSC, 0);
    defer ch.deinit();

    // Fill buffer
    for (0..4) |i| {
        try testing.expect(ch.trySend(i));
    }

    // Should fail when full
    try testing.expect(!ch.trySend(999));

    // Drain one
    _ = ch.tryReceive();

    // Should work again
    try testing.expect(ch.trySend(999));
}

test "MPSC multiple producers" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 64, .MPSC, 1);
    defer ch.deinit();

    const prod = try ch.registerProducer();
    defer ch.unregisterProducer(prod);

    // Send from multiple threads (simulated sequentially for test simplicity)
    try testing.expect(prod.trySend(100));
    try testing.expect(prod.trySend(200));
    try testing.expect(prod.trySend(300));

    var sum: u64 = 0;
    while (ch.tryReceive()) |val| {
        sum += val;
    }

    try testing.expectEqual(@as(u64, 600), sum);
}

test "Batch reserve/commit" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 64, .MPSC, 1);
    defer ch.deinit();

    const prod = try ch.registerProducer();
    defer ch.unregisterProducer(prod);

    var ptrs: [10]?*u64 = undefined;
    const reserved = prod.reserveBatch(&ptrs);
    try testing.expect(reserved > 0);

    // Fill reserved slots
    for (0..reserved) |i| {
        if (ptrs[i]) |p| {
            p.* = i * 10;
        }
    }

    prod.commitBatch(reserved);

    // Receive and verify
    var buf: [10]u64 = undefined;
    const received = ch.tryReceiveBatch(&buf);
    try testing.expectEqual(reserved, received);

    for (0..received) |i| {
        try testing.expectEqual(@as(u64, i * 10), buf[i]);
    }
}

// test "Blocking operations" {
//     var ch = try bchan.Channel(u64).init(testing.allocator, 4, .SPSC, 0);
//     defer ch.deinit();

//     // Fill buffer
//     for (0..4) |i| {
//         ch.send(i);
//     }

//     // Spawn consumer thread
//     var consumer_result: ?u64 = null;
//     const consumer_thread = try std.Thread.spawn(.{}, struct {
//         fn consume(c: *bchan.Channel(u64), result: *?u64) void {
//             result.* = c.receive();
//         }
//     }.consume, .{ &ch, &consumer_result });

//     // Small delay to ensure consumer is waiting
//     std.os.nanosleep(10 * std.time.ns_per_ms, 0);

//     // Send one more (should wake consumer)
//     ch.send(999);

//     consumer_thread.join();

//     try testing.expect(consumer_result != null);
//     try testing.expectEqual(@as(u64, 0), consumer_result.?); // First sent
// }

test "Empty queue invariants" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 16, .MPSC, 1);
    defer ch.deinit();

    // Empty queue should return null
    try testing.expect(ch.tryReceive() == null);

    // Batch receive on empty
    var buf: [4]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), ch.tryReceiveBatch(&buf));
}

// test "Full queue blocking" {
//     var ch = try bchan.Channel(u64).init(testing.allocator, 2, .SPSC, 0);
//     defer ch.deinit();

//     // Fill
//     ch.send(1);
//     ch.send(2);

//     // Spawn producer that should block
//     var sent_value: bool = false;
//     const producer_thread = try std.Thread.spawn(.{}, struct {
//         fn produce(c: *bchan.Channel(u64), sent: *bool) void {
//             c.send(3);
//             sent.* = true;
//         }
//     }.produce, .{ &ch, &sent_value });

//     // Consume one to unblock
//     _ = ch.receive();

//     producer_thread.join();
//     try testing.expect(sent_value);
// }

test "Large batch operations" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 1024, .SPSC, 0);
    defer ch.deinit();

    const batch_size = 512;
    var send_buf: [batch_size]u64 = undefined;
    for (0..batch_size) |i| send_buf[i] = i;

    const sent = ch.trySendBatch(&send_buf);
    try testing.expectEqual(batch_size, sent);

    var recv_buf: [batch_size]u64 = undefined;
    const received = ch.tryReceiveBatch(&recv_buf);
    try testing.expectEqual(batch_size, received);

    for (0..batch_size) |i| {
        try testing.expectEqual(@as(u64, i), recv_buf[i]);
    }
}

test "Zero-capacity edge case" {
    // Note: bchan requires capacity >= 1, but test boundary
    const ch = try bchan.Channel(u64).init(testing.allocator, 1, .SPSC, 0);
    defer ch.deinit();

    try testing.expect(ch.trySend(1));
    try testing.expect(!ch.trySend(2)); // Full

    const val = ch.tryReceive();
    try testing.expectEqual(@as(u64, 1), val.?);

    try testing.expect(ch.trySend(2)); // Now can send
}

// Keep remaining tests as a basic coverage set, adapted to use `bchan`

test "SPMC basic send/receive" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 16, .SPMC, 0);
    defer ch.deinit();

    try testing.expect(ch.trySend(42));
    const val = ch.tryReceive();
    try testing.expect(val != null);
    try testing.expectEqual(@as(u64, 42), val.?);
}

test "SPMC batch send/receive" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 64, .SPMC, 0);
    defer ch.deinit();

    // Send batch
    var send_buf: [32]u64 = undefined;
    for (0..32) |i| send_buf[i] = i;

    const sent = ch.trySendBatch(&send_buf);
    try testing.expectEqual(@as(usize, 32), sent);

    // Receive batch
    var recv_buf: [32]u64 = undefined;
    const received = ch.tryReceiveBatch(&recv_buf);
    try testing.expectEqual(@as(usize, 32), received);

    // Verify data
    for (0..32) |i| {
        try testing.expectEqual(@as(u64, i), recv_buf[i]);
    }
}

test "SPSC correctness" {
    const ch = try bchan.Channel(i64).init(testing.allocator, 16384, .SPSC, 0); // Large enough buffer
    defer ch.deinit();

    const iterations: usize = 10000;

    // Send all items (buffer is large enough)
    for (0..iterations) |i| {
        const sent = ch.trySend(@intCast(i));
        try testing.expect(sent); // Should never fail
    }

    // Receive and verify all items
    for (0..iterations) |i| {
        const val = ch.tryReceive();
        try testing.expect(val != null);
        try testing.expectEqual(@as(i64, @intCast(i)), val.?);
    }
}

test "SPSC batch send/receive" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 64, .SPSC, 0);
    defer ch.deinit();

    // Send batch
    var send_buf: [32]u64 = undefined;
    for (0..32) |i| send_buf[i] = i;

    const sent = ch.trySendBatch(&send_buf);
    try testing.expectEqual(@as(usize, 32), sent);

    // Receive batch
    var recv_buf: [32]u64 = undefined;
    const received = ch.tryReceiveBatch(&recv_buf);
    try testing.expectEqual(@as(usize, 32), received);

    // Verify data
    for (0..32) |i| {
        try testing.expectEqual(@as(u64, i), recv_buf[i]);
    }
}

test "MPSC batch send/receive" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 64, .MPSC, 1);
    defer ch.deinit();

    const prod = try ch.registerProducer();
    defer ch.unregisterProducer(prod);

    // Send batch
    var send_buf: [32]u64 = undefined;
    for (0..32) |i| send_buf[i] = i + 100;

    const sent = prod.trySendBatch(&send_buf);
    try testing.expectEqual(@as(usize, 32), sent);

    // Receive batch
    var recv_buf: [32]u64 = undefined;
    const received = ch.tryReceiveBatch(&recv_buf);
    try testing.expectEqual(@as(usize, 32), received);

    // Verify data
    for (0..32) |i| {
        try testing.expectEqual(@as(u64, i + 100), recv_buf[i]);
    }
}

test "Batch partial send" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 8, .SPSC, 0);
    defer ch.deinit();

    // Try to send more than capacity
    var send_buf: [16]u64 = undefined;
    for (0..16) |i| send_buf[i] = i;

    const sent = ch.trySendBatch(&send_buf);
    try testing.expectEqual(@as(usize, 8), sent); // Only 8 fit

    // Verify partial send worked
    var recv_buf: [8]u64 = undefined;
    const received = ch.tryReceiveBatch(&recv_buf);
    try testing.expectEqual(@as(usize, 8), received);

    for (0..8) |i| {
        try testing.expectEqual(@as(u64, i), recv_buf[i]);
    }
}

test "Blocking batch operations" {
    const ch = try bchan.Channel(u64).init(testing.allocator, 128, .MPSC, 1);
    defer ch.deinit();

    const prod = try ch.registerProducer();
    defer ch.unregisterProducer(prod);

    var send_buf: [64]u64 = undefined;
    for (0..64) |i| send_buf[i] = i * 2;

    // Blocking send
    const sent = prod.sendBatch(&send_buf);
    try testing.expectEqual(@as(usize, 64), sent);

    // Blocking receive
    var recv_buf: [64]u64 = undefined;
    const received = ch.receiveBatch(&recv_buf);
    try testing.expectEqual(@as(usize, 64), received);

    for (0..64) |i| {
        try testing.expectEqual(@as(u64, i * 2), recv_buf[i]);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
