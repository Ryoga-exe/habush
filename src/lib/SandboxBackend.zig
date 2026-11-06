//! An explicitly selected adapter for native process restrictions.
//!
//! Preparation describes what a launcher can enforce; it does not launch a
//! process or prove that a particular launch reached its target executable.
//! The caller must apply the profile before path-opening actions and execution.

const std = @import("std");
const builtin = @import("builtin");
const CommandPlan = @import("CommandPlan.zig");
const Host = @import("Host.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const macos = @import("sandbox/macos.zig");
const SandboxBackend = @This();

kind: Kind,

pub const Kind = enum {
    macos_seatbelt,
};

/// Internal executable dispatch and launch preparation, kept together so an
/// embedding executable can wire the worker without importing duplicate types.
pub const worker = @import("worker.zig");

/// Capabilities of the initial adapter, rather than the availability of the
/// external launcher on this machine. Launchers may still fail at runtime.
pub const Capabilities = struct {
    process_subtree: bool = false,
    read_and_enumerate_bundle: bool = false,
    execute_paths: bool = false,
    write_bundle: bool = false,
    exact_paths: bool = false,
    subtree_paths: bool = false,
    network_deny_all: bool = false,
    network_port_rules: bool = false,
};

pub const Unsupported = packed struct(u8) {
    platform: bool = false,
    filesystem_access: bool = false,
    network_rules: bool = false,
    relative_paths: bool = false,
    unavailable_paths: bool = false,
    path_encoding: bool = false,
    profile_size: bool = false,
    _: u1 = 0,

    pub fn any(unsupported: Unsupported) bool {
        return @as(u8, @bitCast(unsupported)) != 0;
    }
};

pub const Assessment = struct {
    coverage: SandboxPolicy.Coverage,
    unsupported: Unsupported = .{},
};

pub const Prepared = struct {
    /// Owned profile passed as one launcher argument, without a shell.
    profile: []u8,
    assessment: Assessment,

    pub fn deinit(prepared: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(prepared.profile);
        prepared.* = undefined;
    }
};

pub const Preparation = union(enum) {
    ready: Prepared,
    rejected: Assessment,

    pub fn deinit(preparation: *Preparation, gpa: std.mem.Allocator) void {
        switch (preparation.*) {
            .ready => |*prepared| prepared.deinit(gpa),
            .rejected => {},
        }
        preparation.* = undefined;
    }
};

pub const Error = std.mem.Allocator.Error || error{InvalidPolicy};

pub fn launcher(backend: SandboxBackend) []const u8 {
    return switch (backend.kind) {
        .macos_seatbelt => "/usr/bin/sandbox-exec",
    };
}

pub fn capabilities(backend: SandboxBackend) Capabilities {
    return switch (backend.kind) {
        .macos_seatbelt => if (builtin.os.tag == .macos) .{
            .process_subtree = true,
            .read_and_enumerate_bundle = true,
            .execute_paths = true,
            .write_bundle = true,
            .exact_paths = true,
            .subtree_paths = true,
            .network_deny_all = true,
        } else .{},
    };
}

/// Prepares without creating files or launching a process. Filesystem rules
/// name existing absolute paths, resolved once into the launcher's namespace.
/// Required policies reject every unrepresentable part. Best-effort profiles
/// omit unrepresentable grants and network allowlists, and report partial
/// coverage. Omitting a filesystem grant can make the result more restrictive.
pub fn prepare(
    backend: SandboxBackend,
    gpa: std.mem.Allocator,
    io: std.Io,
    policy: SandboxPolicy,
) Error!Preparation {
    policy.validate() catch return error.InvalidPolicy;
    return switch (backend.kind) {
        .macos_seatbelt => if (builtin.os.tag == .macos)
            macos.prepare(gpa, io, policy)
        else
            .{ .rejected = .{ .coverage = .partial, .unsupported = .{ .platform = true } } },
    };
}

/// Launches a fresh worker through the selected backend. The inner host sees
/// only resource bindings: ordered path opens happen after profile application.
/// The parent resolver and language evaluation remain outside this scope.
/// Inherited stdio and prefix resources are explicit, already-open capabilities;
/// path rules do not revoke them or inspect the bytes they can carry.
///
/// Coverage describes the restrictions guaranteed if target code executes.
/// A launcher/profile/worker failure cannot fall back to an unrestricted target;
/// it appears as launcher failure or the worker's exit status and diagnostic.
/// Worker file-action diagnostics index the tail after `resource_prefix`.
/// `worker_executable` must be a trusted executable implementing `worker.run`.
pub fn launch(
    backend: SandboxBackend,
    gpa: std.mem.Allocator,
    io: std.Io,
    host: Host,
    worker_executable: []const u8,
    plan: CommandPlan,
) Host.SpawnError!Host.SpawnOutcome {
    try plan.validate();
    if (plan.sandbox != .restrict) return error.InvalidArguments;
    if (!std.fs.path.isAbsolute(worker_executable) or
        std.mem.indexOfScalar(u8, worker_executable, 0) != null)
        return .{ .failed = .sandbox_unavailable };

    // Validate the entire worker protocol before creating any child or opening
    // a redirected path. Environment/cwd are passed by spawn, never in argv.
    var request = worker.prepare(gpa, plan) catch |err| switch (err) {
        error.Unsupported => return .{ .failed = .unsupported },
        else => |other| return other,
    };
    defer request.deinit(gpa);
    var preparation = backend.prepare(gpa, io, plan.sandbox.restrict) catch |err| switch (err) {
        error.InvalidPolicy => return error.InvalidArguments,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer preparation.deinit(gpa);
    const prepared = switch (preparation) {
        .ready => |value| value,
        .rejected => return .{ .failed = .sandbox_unavailable },
    };
    // Availability checks are advisory. A race or later launch failure still
    // fails closed; this is not a proof that profile application will succeed.
    if (!availableExecutable(io, backend.launcher()) or !availableExecutable(io, worker_executable))
        return .{ .failed = .sandbox_unavailable };

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(gpa);
    try arguments.appendSlice(gpa, &.{ backend.launcher(), "-p", prepared.profile, worker_executable, worker.argument });
    try arguments.appendSlice(gpa, request.arguments);
    var outcome = try host.spawn(.{
        .executable = backend.launcher(),
        .argv = arguments.items,
        .environment = plan.environment,
        .cwd = plan.cwd,
        .file_actions = request.resource_prefix,
        .process_group = plan.process_group,
        .sandbox = .inherit,
    });
    switch (outcome) {
        .spawned => |*spawned| spawned.sandbox_coverage = prepared.assessment.coverage,
        .failed => |failure| switch (failure) {
            .command_not_found, .access_denied, .invalid_executable => return .{ .failed = .sandbox_unavailable },
            else => {},
        },
    }
    return outcome;
}

fn availableExecutable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    return true;
}

test "launch preserves explicit context and sends only resource prefix to the inner host" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const result = try (SandboxBackend{ .kind = .macos_seatbelt }).launch(
        std.testing.allocator,
        std.testing.io,
        fake.host(),
        "/usr/bin/true",
        .{
            .executable = "/bin/command",
            .argv = &.{ "command", "argument" },
            .cwd = .{ .path = "/chosen/cwd" },
            .environment = .{ .replace = &.{.{ .name = "SECRET", .value = "environment-only" }} },
            .file_actions = &.{
                .{ .use_resource = .{ .resource = @enumFromInt(17), .target = .stdin } },
                .{ .open = .{ .target = .stdout, .path = "output", .access = .write, .disposition = .create_or_truncate } },
            },
            .process_group = .create,
            .sandbox = .{ .restrict = .{ .network = .{ .allow = &.{} } } },
        },
    );
    try std.testing.expect(result == .spawned);
    try std.testing.expectEqual(.complete, result.spawned.sandbox_coverage);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const wrapped = fake.spawn_calls.items[0];
    try std.testing.expectEqualStrings("/usr/bin/sandbox-exec", wrapped.executable);
    try std.testing.expectEqualStrings("/chosen/cwd", wrapped.cwd.path);
    try std.testing.expectEqualStrings("environment-only", wrapped.environment.replace[0].value);
    try std.testing.expectEqual(.create, wrapped.process_group);
    try std.testing.expectEqual(.inherit, wrapped.sandbox);
    try std.testing.expectEqual(@as(usize, 1), wrapped.file_actions.len);
    try std.testing.expect(wrapped.file_actions[0] == .use_resource);
    try std.testing.expectEqualStrings(worker.argument, wrapped.argv[4]);
    try std.testing.expectEqualStrings("1", wrapped.argv[5]);
    try std.testing.expectEqualStrings("open", wrapped.argv[6]);
    try std.testing.expectEqualStrings("/bin/command", wrapped.argv[wrapped.argv.len - 2]);
    for (wrapped.argv) |value| try std.testing.expect(!std.mem.eql(u8, value, "environment-only"));
}

test "unsupported restrictions and absent workers never reach the inner host" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const backend: SandboxBackend = .{ .kind = .macos_seatbelt };
    const base: CommandPlan = .{
        .executable = "/bin/command",
        .argv = &.{"command"},
        .sandbox = .{ .restrict = .{} },
    };
    for ([_][]const u8{ "relative-worker", "/definitely/missing/habush-worker" }) |path| {
        const result = try backend.launch(std.testing.allocator, std.testing.io, fake.host(), path, base);
        try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .sandbox_unavailable }, result);
    }
    var unsupported = base;
    unsupported.sandbox.restrict.network = .{ .allow = &.{.{
        .protocol = .tcp,
        .operation = .connect,
        .ports = .{ .first = 443, .last = 443 },
    }} };
    const result = try backend.launch(std.testing.allocator, std.testing.io, fake.host(), "/usr/bin/true", unsupported);
    try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .sandbox_unavailable }, result);
    var interleaved = base;
    interleaved.file_actions = &.{
        .{ .open = .{ .path = "/must-not-open", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
        .{ .use_resource = .{ .resource = @enumFromInt(9), .target = .stdout } },
    };
    const unsupported_actions = try backend.launch(std.testing.allocator, std.testing.io, fake.host(), "/usr/bin/true", interleaved);
    try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .unsupported }, unsupported_actions);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test {
    _ = @import("sandbox/macos.zig");
    _ = worker;
    std.testing.refAllDecls(@This());
}
