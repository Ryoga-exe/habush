//! Host operations used by the Habush runtime.
//!
//! This is a shell-domain boundary rather than a replacement for `std.Io`.
//! A system implementation may use `std.Io` internally, while tests and
//! policy-enforcing hosts can provide another implementation.

const std = @import("std");
const Host = @This();
const CommandPlan = @import("CommandPlan.zig");
const Policy = @import("Security/Policy.zig");

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    spawn: *const fn (?*anyopaque, CommandPlan) Error!SpawnResult,
    wait: *const fn (?*anyopaque, Process) Error!Termination,
};

pub const Error = error{
    OutOfMemory,
    InvalidArguments,
    CommandNotFound,
    AccessDenied,
    InvalidExecutable,
    ResourceUnavailable,
    SecurityUnavailable,
    Unsupported,
    Unexpected,
};

/// An opaque process handle owned by the host implementation.
pub const Process = enum(u32) {
    _,
};

pub const SpawnResult = struct {
    process: Process,
    /// Populated when this spawn created or joined a process group.
    process_group: ?CommandPlan.ProcessGroup = null,
    security: Policy.Coverage,
};

pub const Termination = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub fn spawn(host: Host, plan: CommandPlan) Error!SpawnResult {
    plan.validate() catch return error.InvalidArguments;
    return host.vtable.spawn(host.userdata, plan);
}

pub fn wait(host: Host, process: Process) Error!Termination {
    return host.vtable.wait(host.userdata, process);
}

test {
    _ = @import("host_test.zig");
    std.testing.refAllDecls(@This());
}
