//! Fully expanded, ephemeral plan for one external command.

const CommandPlan = @This();
const Policy = @import("Security/Policy.zig");

/// Resolved executable path. `Host` does not perform `PATH` lookup.
executable: []const u8,
argv: []const []const u8,
environment: Environment = .inherit,
cwd: WorkingDirectory = .inherit,
/// Path-opening actions must observe the security policy. All actions retain
/// source order because shell redirections are order-dependent.
file_actions: []const FileAction = &.{},
process_group: ProcessGroupAction = .inherit,
security: Security = .inherit,

pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const Environment = union(enum) {
    inherit,
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

pub const Security = union(enum) {
    inherit,
    restrict: Policy,
};

pub fn validate(plan: CommandPlan) error{InvalidArguments}!void {
    if (plan.executable.len == 0 or plan.argv.len == 0 or plan.argv[0].len == 0)
        return error.InvalidArguments;
    switch (plan.security) {
        .inherit => {},
        .restrict => |policy| policy.validate() catch return error.InvalidArguments,
    }
}
