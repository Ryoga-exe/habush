//! Platform- and mechanism-independent restrictions for a sandboxed process.
//!
//! A policy can only reduce the authority inherited from its parent domain.
//! A host may use one backend, combine multiple mechanisms, or reject a
//! policy it cannot enforce. Backend-specific concepts do not belong here.

const std = @import("std");
const SandboxPolicy = @This();

enforcement: Enforcement = .required,
file_system: FileSystem = .unrestricted,
network: Network = .unrestricted,

pub const Enforcement = enum {
    /// Do not execute if the backend cannot enforce the complete policy.
    required,
    /// Enforce the supported subset and report incomplete coverage.
    best_effort,
};

/// How completely a requested policy was applied to a spawned process.
pub const Coverage = enum {
    not_requested,
    complete,
    partial,
};

pub const FileSystem = union(enum) {
    unrestricted,
    allow: []const PathRule,
};

pub const PathRule = struct {
    path: []const u8,
    scope: PathScope = .subtree,
    access: FileSystemAccess,
};

pub const PathScope = enum {
    exact,
    subtree,
};

/// Operations whose denial must be guaranteed by the selected backend.
pub const FileSystemAccess = packed struct(u16) {
    execute: bool = false,
    read: bool = false,
    enumerate: bool = false,
    write: bool = false,
    create: bool = false,
    remove: bool = false,
    rename: bool = false,
    change_metadata: bool = false,
    _: u8 = 0,
};

pub const Network = union(enum) {
    unrestricted,
    allow: []const NetworkRule,
};

pub const NetworkRule = struct {
    protocol: Protocol,
    operation: NetworkOperation,
    ports: PortRange,
};

pub const PortRange = struct {
    first: u16,
    last: u16,
};

pub const Protocol = enum {
    tcp,
    udp,
};

pub const NetworkOperation = enum {
    bind,
    connect,
};

pub fn validate(policy: SandboxPolicy) error{InvalidPolicy}!void {
    switch (policy.file_system) {
        .unrestricted => {},
        .allow => |rules| for (rules) |rule| {
            if (rule.path.len == 0) return error.InvalidPolicy;
        },
    }
    switch (policy.network) {
        .unrestricted => {},
        .allow => |rules| for (rules) |rule| {
            if (rule.ports.first > rule.ports.last) return error.InvalidPolicy;
        },
    }
}

pub fn clone(policy: SandboxPolicy, allocator: std.mem.Allocator) !SandboxPolicy {
    var copy: SandboxPolicy = .{
        .enforcement = policy.enforcement,
    };
    errdefer copy.deinit(allocator);

    copy.file_system = switch (policy.file_system) {
        .unrestricted => .unrestricted,
        .allow => |rules| .{ .allow = try clonePathRules(allocator, rules) },
    };
    copy.network = switch (policy.network) {
        .unrestricted => .unrestricted,
        .allow => |rules| .{ .allow = try allocator.dupe(NetworkRule, rules) },
    };
    return copy;
}

pub fn deinit(policy: *SandboxPolicy, allocator: std.mem.Allocator) void {
    switch (policy.file_system) {
        .unrestricted => {},
        .allow => |rules| {
            for (rules) |rule| allocator.free(rule.path);
            allocator.free(rules);
        },
    }
    switch (policy.network) {
        .unrestricted => {},
        .allow => |rules| allocator.free(rules),
    }
    policy.* = undefined;
}

fn clonePathRules(
    allocator: std.mem.Allocator,
    rules: []const PathRule,
) std.mem.Allocator.Error![]const PathRule {
    const copy = try allocator.alloc(PathRule, rules.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |rule| allocator.free(rule.path);
        allocator.free(copy);
    }
    for (rules, copy) |rule, *destination| {
        destination.* = rule;
        destination.path = try allocator.dupe(u8, rule.path);
        copied += 1;
    }
    return copy;
}
