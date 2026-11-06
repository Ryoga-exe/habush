//! Structured execution without the shell parser or language evaluator.

const std = @import("std");

pub const CommandPlan = @import("CommandPlan.zig");
pub const ExecutionContext = @import("ExecutionContext.zig");
pub const Host = @import("Host.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const worker = @import("worker.zig");

test {
    std.testing.refAllDecls(@This());
}
