const std = @import("std");

pub const Channel = @import("channel.zig").Channel;
pub const ChannelMode = @import("channel.zig").ChannelMode;
pub const VyukovQueue = @import("vyukov.zig").VyukovQueue;
pub const ProducerHandle = @import("channel.zig").Channel(u8).ProducerHandle; // Type for any T

/// Create a new SPSC channel
pub fn newSPSC(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !*Channel(T) {
    return try Channel(T).init(allocator, capacity, .SPSC, 0);
}

/// Create a new MPSC channel with per-producer registration
pub fn newMPSC(comptime T: type, allocator: std.mem.Allocator, capacity: usize, max_producers: usize) !*Channel(T) {
    return try Channel(T).init(allocator, capacity, .MPSC, max_producers);
}

/// Create a new SPMC channel
pub fn newSPMC(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !*Channel(T) {
    return try Channel(T).init(allocator, capacity, .SPMC, 0);
}

/// Version information
pub const version = "0.1.0";
pub const version_info = "bchan v0.1.0 - Minimal fork for testing";

test {
    std.testing.refAllDecls(@This());
}
