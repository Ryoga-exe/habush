//! Fully expanded, ephemeral plan for one external command.

const std = @import("std");
const CommandPlan = @This();
const SandboxPolicy = @import("SandboxPolicy.zig");

/// Resolved executable representation accepted by `Host`. `Host` does not
/// perform command search.
executable: []const u8,
argv: []const []const u8,
environment: Environment = .inherit,
cwd: WorkingDirectory = .inherit,
/// Path-opening actions must observe the sandbox policy. All actions retain
/// source order because shell redirections are order-dependent.
file_actions: []const FileAction = &.{},
process_group: ProcessGroupAction = .inherit,
sandbox: Sandbox = .inherit,

pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const Environment = union(enum) {
    inherit,
    /// Inherit the parent environment, replacing variables with matching names.
    overlay: []const EnvironmentVariable,
    /// Use exactly the listed variables without inheriting the parent environment.
    replace: []const EnvironmentVariable,
};

pub const WorkingDirectory = union(enum) {
    inherit,
    path: []const u8,
};

/// A logical shell descriptor which the host maps to its native mechanism.
pub const FileDescriptor = enum(u32) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
    _,
};

/// Host-owned resource such as one endpoint of a pipe.
pub const Resource = enum(u32) {
    _,
};

pub const FileAction = union(enum) {
    open: Open,
    duplicate: Duplicate,
    use_resource: UseResource,
    close: FileDescriptor,

    pub const Open = struct {
        path: []const u8,
        target: FileDescriptor,
        access: Access,
        disposition: Disposition,

        pub const Access = enum {
            read,
            write,
            read_write,
        };

        pub const Disposition = enum {
            open_existing,
            create_or_truncate,
            create_or_append,
            create_exclusive,
        };
    };

    pub const Duplicate = struct {
        source: FileDescriptor,
        target: FileDescriptor,
    };

    pub const UseResource = struct {
        resource: Resource,
        target: FileDescriptor,
    };
};

/// An opaque execution group used for pipeline and job control.
pub const ProcessGroup = enum(u32) {
    _,
};

pub const ProcessGroupAction = union(enum) {
    inherit,
    create,
    join: ProcessGroup,
};

pub const Sandbox = union(enum) {
    inherit,
    restrict: SandboxPolicy,

    pub fn clone(sandbox: Sandbox, allocator: std.mem.Allocator) !Sandbox {
        return switch (sandbox) {
            .inherit => .inherit,
            .restrict => |policy| .{ .restrict = try policy.clone(allocator) },
        };
    }

    pub fn deinit(sandbox: *Sandbox, allocator: std.mem.Allocator) void {
        switch (sandbox.*) {
            .inherit => {},
            .restrict => |*policy| policy.deinit(allocator),
        }
        sandbox.* = undefined;
    }
};

pub fn validate(plan: CommandPlan) error{InvalidArguments}!void {
    if (plan.executable.len == 0 or plan.argv.len == 0 or plan.argv[0].len == 0)
        return error.InvalidArguments;
    switch (plan.environment) {
        .inherit => {},
        .overlay, .replace => |variables| for (variables) |variable| {
            if (variable.name.len == 0 or
                std.mem.indexOfScalar(u8, variable.name, '=') != null or
                std.mem.indexOfScalar(u8, variable.name, 0) != null or
                std.mem.indexOfScalar(u8, variable.value, 0) != null)
            {
                return error.InvalidArguments;
            }
        },
    }
    switch (plan.sandbox) {
        .inherit => {},
        .restrict => |policy| policy.validate() catch return error.InvalidArguments,
    }
}
