//! Types shared by the shell execution runtime.

const std = @import("std");

pub const Diagnostic = @import("runtime/Diagnostic.zig");
pub const Io = @import("runtime/Io.zig");
pub const State = @import("runtime/State.zig");

/// A request to transfer control out of the current shell execution unit.
/// The accompanying command status is carried by the execution result.
pub const ControlFlow = enum {
    none,
    exit,
};

test {
    std.testing.refAllDecls(@This());
}
