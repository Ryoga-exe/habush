//! Host operations used by the Habush runtime.
//!
//! This is a shell-domain boundary rather than a replacement for `std.Io`.
//! A system implementation may use `std.Io` internally, while tests and
//! sandbox-enforcing hosts can provide another implementation.

const std = @import("std");
const Host = @This();
const CommandPlan = @import("CommandPlan.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    spawn: *const fn (?*anyopaque, CommandPlan) Error!SpawnResult,
    wait: *const fn (?*anyopaque, Process) Error!Termination,
    resolve_working_directory: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        WorkingDirectoryRequest,
    ) Error![]u8 = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidArguments,
    CommandNotFound,
    AccessDenied,
    InvalidExecutable,
    ResourceUnavailable,
    SandboxUnavailable,
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
    sandbox_coverage: SandboxPolicy.Coverage,
};

pub const WorkingDirectoryRequest = struct {
    current: ?[]const u8,
    path: []const u8,
};

pub const Termination = union(enum) {
    /// Portable shell exit status. System hosts normalize native process
    /// results to the range 0...255.
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

/// Resolves and validates a directory using the host platform's path rules.
/// The returned path is owned by `allocator`.
pub fn resolveWorkingDirectory(
    host: Host,
    allocator: std.mem.Allocator,
    request: WorkingDirectoryRequest,
) Error![]u8 {
    if (request.path.len == 0) return error.InvalidArguments;
    const resolve = host.vtable.resolve_working_directory orelse return error.Unsupported;
    return resolve(host.userdata, allocator, request);
}

test {
    _ = @import("host_test.zig");
    std.testing.refAllDecls(@This());
}
