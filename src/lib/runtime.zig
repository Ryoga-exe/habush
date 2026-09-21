//! Types shared by the shell execution runtime.

const std = @import("std");
const types = @import("runtime/types.zig");

pub const Diagnostic = @import("runtime/Diagnostic.zig");
pub const ExitStatus = types.ExitStatus;
pub const Io = @import("runtime/Io.zig");
pub const ProcessId = types.ProcessId;
pub const State = @import("runtime/State.zig");

/// A request to transfer control out of the current shell execution unit.
/// The accompanying command status is carried by the execution result.
pub const ControlFlow = union(enum) {
    none,
    exit,
    @"return",
    @"break": u32,
    @"continue": u32,

    pub fn isNone(control_flow: ControlFlow) bool {
        return switch (control_flow) {
            .none => true,
            else => false,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
