//! The signal handler only publishes a lock-free generation. Task cancellation
//! and resource cleanup run outside the handler, in the interactive adapter.
const std = @import("std");

var generation: std.atomic.Value(u32) = .init(0);

pub fn notify() void {
    _ = generation.fetchAdd(1, .monotonic);
}

pub fn snapshot() u32 {
    return generation.load(.monotonic);
}

pub fn wait(io: std.Io, previous: u32) std.Io.Cancelable!void {
    while (snapshot() == previous) try io.sleep(.fromMilliseconds(10), .awake);
}
