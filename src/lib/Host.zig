//! Host operations used by the Habush runtime.
//!
//! This is a shell-domain boundary rather than a replacement for `std.Io`.
//! A system implementation may use `std.Io` internally, while tests and
//! policy-enforcing hosts can provide another implementation.

const std = @import("std");
const Host = @This();

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    spawn: *const fn (?*anyopaque, SpawnOptions) Error!Process,
    wait: *const fn (?*anyopaque, Process) Error!Termination,
};

pub const Error = error{
    OutOfMemory,
    InvalidArguments,
    CommandNotFound,
    AccessDenied,
    InvalidExecutable,
    ResourceUnavailable,
    Unsupported,
    Unexpected,
};

/// An opaque process handle owned by the host implementation.
pub const Process = enum(u32) {
    _,
};

pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    /// `null` inherits the host environment. A non-null slice replaces it.
    environment: ?[]const EnvironmentVariable = null,
    /// `null` inherits the host working directory.
    cwd: ?[]const u8 = null,
};

pub const Termination = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub fn spawn(host: Host, options: SpawnOptions) Error!Process {
    if (options.argv.len == 0 or options.argv[0].len == 0)
        return error.InvalidArguments;
    return host.vtable.spawn(host.userdata, options);
}

pub fn wait(host: Host, process: Process) Error!Termination {
    return host.vtable.wait(host.userdata, process);
}

test {
    _ = @import("host_test.zig");
    std.testing.refAllDecls(@This());
}
