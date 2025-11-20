const std = @import("std");
const bchan = @import("bchan");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an MPSC channel
    const ch = try bchan.Channel(u64).init(allocator, 1024, .MPSC, 4);
    defer ch.deinit();

    // Register a producer
    const producer = try ch.registerProducer();
    defer ch.unregisterProducer(producer);

    // Send some messages
    try std.testing.expect(producer.trySend(42));
    try std.testing.expect(producer.trySend(1337));

    // Receive them
    const val1 = ch.tryReceive();
    const val2 = ch.tryReceive();

    std.debug.print("Received: {} {}\n", .{ val1.?, val2.? });

    // Close the channel
    ch.close();
    try std.testing.expect(!producer.trySend(999)); // Should fail
    try std.testing.expect(ch.isClosed());
}
