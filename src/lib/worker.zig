//! Internal, versioned argv protocol for a fresh worker process.
//!
//! The parent supplies cwd and environment through its spawn API. Pipe/resource
//! bindings may appear only as a prefix handled by the parent; path-opening
//! actions run here. A sandbox launcher can apply restrictions before entry;
//! ordinary launches use the same worker to defer blocking FIFO opens.
//! No shell source is constructed or evaluated.

const std = @import("std");
const builtin = @import("builtin");
const CommandPlan = @import("CommandPlan.zig");
const Host = @import("Host.zig");
const append_file = @import("Host/System/append_file.zig");
const worker_channel = if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi)
    struct {}
else
    @import("Host/System/worker_channel.zig");
const Reporter = if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) void else worker_channel.Reporter;

pub const argument = "--internal-command-worker";
/// Used only by the private System worker host; not part of the public plan.
pub const bootstrap_argument = "--stdio-channel";
const version = "1";

pub const PrepareError = std.mem.Allocator.Error || error{ InvalidArguments, Unsupported };
pub const ParseError = std.mem.Allocator.Error || error{InvalidArguments};
pub const LaunchError = Host.SpawnError || error{Unsupported};

pub const ActionSplit = struct {
    resource_prefix: []const CommandPlan.FileAction,
    worker_actions: []const CommandPlan.FileAction,
};

/// Borrowed resource IDs stay opaque: the parent resolves them through its
/// resource table. An interleaved resource action is rejected before any open.
pub fn splitFileActions(actions: []const CommandPlan.FileAction) error{Unsupported}!ActionSplit {
    var prefix_len: usize = 0;
    while (prefix_len < actions.len and actions[prefix_len] == .use_resource) : (prefix_len += 1) {
        if (!standardDescriptor(actions[prefix_len].use_resource.target)) return error.Unsupported;
    }
    for (actions[prefix_len..]) |action| switch (action) {
        .use_resource => return error.Unsupported,
        .open => |open| if (!standardDescriptor(open.target)) return error.Unsupported,
        .duplicate => |duplicate| if (!standardDescriptor(duplicate.source) or
            !standardDescriptor(duplicate.target)) return error.Unsupported,
        .close => |descriptor| if (!standardDescriptor(descriptor)) return error.Unsupported,
    };
    return .{ .resource_prefix = actions[0..prefix_len], .worker_actions = actions[prefix_len..] };
}

pub const Prepared = struct {
    /// Owned slice; string payloads borrow the command plan until spawn returns.
    arguments: [][]const u8,
    resource_prefix: []const CommandPlan.FileAction,

    pub fn deinit(prepared: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(prepared.arguments);
        prepared.* = undefined;
    }
};

/// Arguments following `argument`, suitable for a normal process spawn.
/// Environment values are deliberately absent from this argv protocol.
pub fn prepare(gpa: std.mem.Allocator, plan: CommandPlan) PrepareError!Prepared {
    try plan.validate();
    // A resolved path avoids a second, implicit PATH search in the worker.
    if (plan.command_failure == null and std.mem.indexOfScalar(u8, plan.executable, '/') == null)
        return error.Unsupported;
    const split = try splitFileActions(plan.file_actions);
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(gpa);
    try arguments.append(gpa, version);
    if (plan.suspend_before_execute) try arguments.append(gpa, "suspend");
    for (split.worker_actions) |action| switch (action) {
        .open => |open| try arguments.appendSlice(gpa, &.{
            "open",                     descriptorText(open.target), @tagName(open.access),
            @tagName(open.disposition), open.path,
        }),
        .duplicate => |duplicate| try arguments.appendSlice(gpa, &.{
            "duplicate", descriptorText(duplicate.source), descriptorText(duplicate.target),
        }),
        .close => |descriptor| try arguments.appendSlice(gpa, &.{ "close", descriptorText(descriptor) }),
        .use_resource => unreachable,
    };
    if (plan.command_failure) |failure|
        try arguments.appendSlice(gpa, &.{ "fail", @tagName(failure) });
    try arguments.append(gpa, "--");
    try arguments.append(gpa, plan.executable);
    try arguments.appendSlice(gpa, plan.argv[1..]);
    return .{
        .arguments = try arguments.toOwnedSlice(gpa),
        .resource_prefix = split.resource_prefix,
    };
}

/// Defers compatible path opens to a fresh process, allowing the parent to
/// launch neighbouring stages while a FIFO open waits for its other endpoint.
/// The inner host receives only the leading resource bindings and must not
/// wrap such a plan again. Unsupported action layouts are returned unchanged
/// as `error.Unsupported` so the caller can choose an explicit fallback.
///
/// This helper adds no restrictions; restricted plans require SandboxBackend.
/// Payloads borrow the plan until the inner spawn returns. System's private
/// worker host reports late startup failures through Termination.spawn_failed.
/// Other hosts may retain exit status and stderr reporting.
pub fn launch(
    gpa: std.mem.Allocator,
    host: Host,
    worker_executable: []const u8,
    plan: CommandPlan,
) LaunchError!Host.SpawnOutcome {
    if (plan.sandbox != .inherit) return error.Unsupported;
    if (!std.fs.path.isAbsolute(worker_executable) or
        std.mem.indexOfScalar(u8, worker_executable, 0) != null)
        return error.InvalidArguments;
    var prepared = try prepare(gpa, plan);
    defer prepared.deinit(gpa);
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(gpa);
    try arguments.appendSlice(gpa, &.{ worker_executable, argument });
    try arguments.appendSlice(gpa, prepared.arguments);
    var wrapped = plan;
    wrapped.executable = worker_executable;
    wrapped.argv = arguments.items;
    wrapped.file_actions = prepared.resource_prefix;
    wrapped.command_failure = null;
    wrapped.suspend_before_execute = false;
    return host.spawn(wrapped);
}

pub const Decoded = struct {
    actions: []CommandPlan.FileAction,
    argv: []const []const u8,
    command_failure: ?CommandPlan.CommandFailure = null,
    suspend_before_execute: bool = false,

    pub fn deinit(decoded: *Decoded, gpa: std.mem.Allocator) void {
        gpa.free(decoded.actions);
        decoded.* = undefined;
    }
};

/// Parses and validates the entire request before applying any action. Payload
/// strings borrow `arguments`; the returned action slice is owned.
pub fn parse(gpa: std.mem.Allocator, arguments: []const []const u8) ParseError!Decoded {
    if (arguments.len == 0 or !std.mem.eql(u8, arguments[0], version)) return error.InvalidArguments;
    for (arguments) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidArguments;
    var actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    defer actions.deinit(gpa);
    var index: usize = 1;
    var command_failure: ?CommandPlan.CommandFailure = null;
    var suspend_before_execute = false;
    while (index < arguments.len) {
        const opcode = arguments[index];
        index += 1;
        if (std.mem.eql(u8, opcode, "--")) {
            if (index == arguments.len or arguments[index].len == 0 or
                (command_failure == null and std.mem.indexOfScalar(u8, arguments[index], '/') == null))
                return error.InvalidArguments;
            return .{
                .actions = try actions.toOwnedSlice(gpa),
                .argv = arguments[index..],
                .command_failure = command_failure,
                .suspend_before_execute = suspend_before_execute,
            };
        }
        if (std.mem.eql(u8, opcode, "suspend")) {
            if (suspend_before_execute or actions.items.len != 0 or command_failure != null) return error.InvalidArguments;
            suspend_before_execute = true;
        } else if (std.mem.eql(u8, opcode, "fail")) {
            if (command_failure != null or index == arguments.len) return error.InvalidArguments;
            command_failure = std.meta.stringToEnum(CommandPlan.CommandFailure, arguments[index]) orelse
                return error.InvalidArguments;
            index += 1;
        } else if (std.mem.eql(u8, opcode, "open")) {
            if (arguments.len - index < 4) return error.InvalidArguments;
            const access = std.meta.stringToEnum(CommandPlan.FileAction.Open.Access, arguments[index + 1]) orelse
                return error.InvalidArguments;
            const disposition = std.meta.stringToEnum(CommandPlan.FileAction.Open.Disposition, arguments[index + 2]) orelse
                return error.InvalidArguments;
            if (access == .read and disposition != .open_existing) return error.InvalidArguments;
            try actions.append(gpa, .{ .open = .{
                .target = try parseDescriptor(arguments[index]),
                .access = access,
                .disposition = disposition,
                .path = arguments[index + 3],
            } });
            index += 4;
        } else if (std.mem.eql(u8, opcode, "duplicate")) {
            if (arguments.len - index < 2) return error.InvalidArguments;
            try actions.append(gpa, .{ .duplicate = .{
                .source = try parseDescriptor(arguments[index]),
                .target = try parseDescriptor(arguments[index + 1]),
            } });
            index += 2;
        } else if (std.mem.eql(u8, opcode, "close")) {
            if (index == arguments.len) return error.InvalidArguments;
            try actions.append(gpa, .{ .close = try parseDescriptor(arguments[index]) });
            index += 1;
        } else return error.InvalidArguments;
    }
    return error.InvalidArguments;
}

/// Called only by the executable's early hidden-worker dispatch. It mutates
/// process stdio and replaces this fresh process, never the embedding process.
/// Launcher/profile failure prevents this code and the target from running.
/// A prepared coverage claim is conditional on target execution, not a report
/// that a failed launcher or failed worker actually reached that target.
pub fn run(init: std.process.Init, arguments: []const [:0]const u8) u8 {
    const gpa = init.gpa;
    var reporter: ?Reporter = null;
    const bootstrap = arguments.len != 0 and std.mem.eql(u8, arguments[0], bootstrap_argument);
    if (bootstrap) {
        if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
            report(init.io, "unsupported platform");
            return 126;
        } else {
            reporter = worker_channel.Reporter.receive() catch {
                report(init.io, "invalid bootstrap");
                return 126;
            };
        }
    }
    defer if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) {
        if (reporter) |channel| channel.deinit();
    };
    const payload = if (bootstrap) arguments[1..] else arguments;
    const values = gpa.alloc([]const u8, payload.len) catch {
        if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) {
            if (reporter) |channel| channel.send(.resource_unavailable);
        }
        report(init.io, "out of memory");
        return 126;
    };
    defer gpa.free(values);
    for (payload, values) |value, *destination| destination.* = value;
    var decoded = parse(gpa, values) catch |err| {
        if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) {
            if (reporter) |channel|
                channel.send(if (err == error.OutOfMemory) .resource_unavailable else .unsupported);
        }
        report(init.io, @errorName(err));
        return 126;
    };
    defer decoded.deinit(gpa);

    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        report(init.io, "unsupported platform");
        return 126;
    } else {
        if (decoded.suspend_before_execute) {
            // std.process.spawn has already exec'd this fresh worker, so its
            // parent's exec-error handshake is complete. Unlike stopping a
            // pre-exec child, this does not block the parent's spawn call.
            std.posix.kill(std.posix.system.getpid(), .STOP) catch |err| {
                if (reporter) |channel| channel.send(.unsupported);
                report(init.io, @errorName(err));
                return 126;
            };
        }
        for (decoded.actions, 0..) |action, index| applyAction(init.io, action) catch |err| {
            if (reporter) |channel| channel.send(.{ .file_action = .{
                .action_index = @intCast(index),
                .reason = fileActionReason(err),
            } });
            reportActionFailure(init.io, index, err);
            return 126;
        };
        if (decoded.command_failure) |failure| {
            const reason: Host.SpawnFailure = switch (failure) {
                .command_not_found => .command_not_found,
                .access_denied => .access_denied,
            };
            if (reporter) |channel| channel.send(reason);
            report(init.io, @tagName(failure));
            return if (failure == .command_not_found) 127 else 126;
        }
        const err = std.process.replace(init.io, .{
            .argv = decoded.argv,
            .environ_map = init.environ_map,
        });
        if (reporter) |channel| channel.send(executeFailure(err));
        report(init.io, @errorName(err));
        return 126;
    }
}

fn fileActionReason(err: anyerror) Host.FileActionFailure.Reason {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.NetworkNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied, error.IsDir => .access_denied,
        error.InvalidName, error.BadPathName, error.NameTooLong => .invalid_path,
        error.PathAlreadyExists => .path_already_exists,
        error.BadDescriptor => .bad_file_descriptor,
        error.OutOfMemory,
        error.NoDevice,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.FileBusy,
        error.PipeBusy,
        => .resource_unavailable,
        else => .unsupported,
    };
}

fn executeFailure(err: anyerror) Host.SpawnFailure {
    return switch (err) {
        error.FileNotFound, error.NotDir => .command_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.InvalidExe, error.IsDir => .invalid_executable,
        error.OutOfMemory,
        error.NoDevice,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ResourceLimitReached,
        => .resource_unavailable,
        else => .unsupported,
    };
}

fn standardDescriptor(descriptor: CommandPlan.FileDescriptor) bool {
    return @backingInt(descriptor) <= 2;
}

fn descriptorText(descriptor: CommandPlan.FileDescriptor) []const u8 {
    return switch (descriptor) {
        .stdin => "0",
        .stdout => "1",
        .stderr => "2",
        else => unreachable,
    };
}

fn parseDescriptor(text: []const u8) error{InvalidArguments}!CommandPlan.FileDescriptor {
    if (text.len != 1) return error.InvalidArguments;
    return switch (text[0]) {
        '0' => .stdin,
        '1' => .stdout,
        '2' => .stderr,
        else => error.InvalidArguments,
    };
}

fn applyAction(io: std.Io, action: CommandPlan.FileAction) !void {
    switch (action) {
        .open => |open| {
            const file = try openFile(io, open);
            const target: std.posix.fd_t = @intCast(@backingInt(open.target));
            if (file.handle == target) {
                // open() may reuse a closed stdio descriptor. It is CLOEXEC by
                // default, and dup2(fd, fd) would not clear that flag.
                try clearCloseOnExec(target);
            } else {
                defer file.close(io);
                try duplicateDescriptor(file.handle, target);
            }
        },
        .duplicate => |binding| try duplicateDescriptor(
            @intCast(@backingInt(binding.source)),
            @intCast(@backingInt(binding.target)),
        ),
        .close => |descriptor| switch (std.posix.errno(std.posix.system.close(@intCast(@backingInt(descriptor))))) {
            .SUCCESS, .INTR, .BADF => {},
            else => return error.CloseFailed,
        },
        .use_resource => unreachable,
    }
}

fn descriptorFlags(fd: std.posix.fd_t) !usize {
    while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadDescriptor,
            else => return error.DescriptorFailed,
        }
    }
}

fn clearCloseOnExec(fd: std.posix.fd_t) !void {
    const flags = try descriptorFlags(fd);
    while (true) switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, flags & ~@as(usize, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.DescriptorFailed,
    };
}

fn duplicateDescriptor(source: std.posix.fd_t, target: std.posix.fd_t) !void {
    // Some Linux dup2(fd, fd) implementations do not validate fd in Release.
    _ = try descriptorFlags(source);
    std.Io.Threaded.dup2(source, target) catch return error.DuplicateFailed;
    if (source == target) try clearCloseOnExec(target);
}

fn openFile(io: std.Io, open: CommandPlan.FileAction.Open) !std.Io.File {
    return switch (open.disposition) {
        .open_existing => std.Io.Dir.cwd().openFile(io, open.path, .{
            .mode = switch (open.access) {
                .read => .read_only,
                .write => .write_only,
                .read_write => .read_write,
            },
            .allow_directory = false,
        }),
        .create_or_append => append_file.open(io, .cwd(), open.path, std.fs.path.isAbsolute(open.path), open.access == .read_write),
        .create_or_open, .create_or_truncate, .create_exclusive => std.Io.Dir.cwd().createFile(io, open.path, .{
            .read = open.access == .read_write,
            .truncate = open.disposition != .create_or_open,
            .exclusive = open.disposition == .create_exclusive,
        }),
    };
}

fn report(io: std.Io, message: []const u8) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    stderr.interface.print("habush: worker: {s}\n", .{message}) catch {};
}

fn reportActionFailure(io: std.Io, index: usize, err: anyerror) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    stderr.interface.print("habush: worker: file action {d}: {s}\n", .{ index, @errorName(err) }) catch {};
}

test "startup suspension is parsed before every file action" {
    var prepared = try prepare(std.testing.allocator, .{
        .executable = "/bin/cat",
        .argv = &.{"/bin/cat"},
        .suspend_before_execute = true,
        .file_actions = &.{.{ .close = .stdin }},
    });
    defer prepared.deinit(std.testing.allocator);
    var decoded = try parse(std.testing.allocator, prepared.arguments);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(decoded.suspend_before_execute);
    try std.testing.expectEqual(@as(usize, 1), decoded.actions.len);
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{
        "1", "close", "0", "suspend", "--", "/bin/cat",
    }));
}

test "worker protocol preserves ordered actions and literal argv without environment" {
    const gpa = std.testing.allocator;
    const actions: []const CommandPlan.FileAction = &.{
        .{ .use_resource = .{ .resource = @fromBackingInt(93), .target = .stdin } },
        .{ .duplicate = .{ .source = .stdout, .target = .stderr } },
        .{ .open = .{ .path = "); $(false) --", .target = .stdout, .access = .write, .disposition = .create_or_append } },
        .{ .close = .stdin },
    };
    var prepared = try prepare(gpa, .{
        .executable = "/resolved/program",
        .argv = &.{ "program", "--", "$(false)", "", "line\nbreak" },
        .file_actions = actions,
        .environment = .{ .replace = &.{.{ .name = "SECRET", .value = "secret-environment-value" }} },
    });
    defer prepared.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_prefix.len);
    for (prepared.arguments) |value| try std.testing.expect(!std.mem.eql(u8, value, "secret-environment-value"));
    var decoded = try parse(gpa, prepared.arguments);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualDeep(actions[1..], decoded.actions);
    try std.testing.expectEqual(@as(usize, 5), decoded.argv.len);
    try std.testing.expectEqualStrings("/resolved/program", decoded.argv[0]);
    try std.testing.expectEqualStrings("$(false)", decoded.argv[2]);
    try std.testing.expectEqualStrings("", decoded.argv[3]);
    try std.testing.expectEqualStrings("line\nbreak", decoded.argv[4]);
}

test "ordinary worker launch delegates context and only the resource prefix" {
    const FakeHost = @import("Host/FakeHost.zig");
    const gpa = std.testing.allocator;
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    const worker_executable = if (builtin.target.os.tag == .windows) "C:/trusted/habush.exe" else "/trusted/habush";
    const plan: CommandPlan = .{
        .executable = "/resolved/tool",
        .argv = &.{ "tool", "literal argument" },
        .cwd = .{ .path = "/chosen/work" },
        .environment = .{ .replace = &.{.{ .name = "MARKER", .value = "environment-only" }} },
        .file_actions = &.{
            .{ .use_resource = .{ .resource = @fromBackingInt(17), .target = .stdin } },
            .{ .open = .{ .path = "fifo", .target = .stdout, .access = .write, .disposition = .open_existing } },
            .{ .duplicate = .{ .source = .stdout, .target = .stderr } },
        },
        .process_group = .create,
    };
    const outcome = try launch(gpa, fake.host(), worker_executable, plan);
    try std.testing.expect(outcome == .spawned);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const wrapped = fake.spawn_calls.items[0];
    try std.testing.expectEqualStrings(worker_executable, wrapped.executable);
    try std.testing.expectEqualStrings("/chosen/work", wrapped.cwd.path);
    try std.testing.expectEqualStrings("environment-only", wrapped.environment.replace[0].value);
    try std.testing.expectEqual(.create, wrapped.process_group);
    try std.testing.expectEqual(.inherit, wrapped.sandbox);
    try std.testing.expectEqual(@as(usize, 1), wrapped.file_actions.len);
    try std.testing.expectEqual(@as(u32, 17), @backingInt(wrapped.file_actions[0].use_resource.resource));
    try std.testing.expectEqualStrings(argument, wrapped.argv[1]);
    var decoded = try parse(gpa, wrapped.argv[2..]);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualDeep(plan.file_actions[1..], decoded.actions);
    try std.testing.expectEqualStrings("/resolved/tool", decoded.argv[0]);
    try std.testing.expectEqualStrings("literal argument", decoded.argv[1]);
    for (wrapped.argv) |value| try std.testing.expect(!std.mem.eql(u8, value, "environment-only"));
    var unsupported = plan;
    unsupported.file_actions = &.{ plan.file_actions[1], plan.file_actions[0] };
    try std.testing.expectError(error.Unsupported, launch(gpa, fake.host(), worker_executable, unsupported));
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
}

test "worker rejects resource interleaving and arbitrary descriptors before preparing" {
    const actions: []const CommandPlan.FileAction = &.{
        .{ .open = .{ .path = "/must-not-open", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
        .{ .use_resource = .{ .resource = @fromBackingInt(1), .target = .stdout } },
    };
    try std.testing.expectError(error.Unsupported, splitFileActions(actions));
    try std.testing.expectError(error.Unsupported, splitFileActions(&.{.{ .close = @fromBackingInt(100) }}));
}

test "worker validates truncated and malformed protocol before any redirect" {
    const gpa = std.testing.allocator;
    const bad: []const []const []const u8 = &.{
        &.{},                                                                  &.{"2"},                                                                         &.{"1"},                                               &.{ "1", "--" },                                                                  &.{ "1", "--", "bare-command" },
        &.{ "1", "--", "" },                                                   &.{ "1", "unknown", "--", "/bin/true" },                                         &.{ "1", "open", "1", "write", "create_or_truncate" }, &.{ "1", "open", "3", "write", "create_or_truncate", "path", "--", "/bin/true" }, &.{ "1", "open", "1", "read", "create_exclusive", "path", "--", "/bin/true" },
        &.{ "1", "open", "1", "write", "invalid", "path", "--", "/bin/true" }, &.{ "1", "open", "1", "write", "open_existing", "path\x00", "--", "/bin/true" }, &.{ "1", "duplicate", "0" },                           &.{ "1", "duplicate", "00", "1", "--", "/bin/true" },                             &.{ "1", "close" },
        &.{ "1", "close", "-1", "--", "/bin/true" },                           &.{ "1", "resource", "1", "1", "--", "/bin/true" },
    };
    for (bad) |arguments| try std.testing.expectError(error.InvalidArguments, parse(gpa, arguments));
    const complete: []const []const u8 = &.{ "1", "open", "1", "write", "create_or_truncate", "path", "duplicate", "1", "2", "close", "0", "--", "/bin/true" };
    for (0..complete.len) |len| try std.testing.expectError(error.InvalidArguments, parse(gpa, complete[0..len]));
}

test "worker protocol handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, protocolWithAllocator, .{});
}

fn protocolWithAllocator(gpa: std.mem.Allocator) !void {
    var prepared = try prepare(gpa, .{
        .executable = "/bin/program",
        .argv = &.{ "program", "argument" },
        .file_actions = &.{.{ .open = .{
            .path = "output",
            .target = .stdout,
            .access = .write,
            .disposition = .create_or_truncate,
        } }},
    });
    defer prepared.deinit(gpa);
    var decoded = try parse(gpa, prepared.arguments);
    defer decoded.deinit(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
