//! Native `Host` implementation backed by Zig's cross-platform standard APIs.
//!
//! The initial process backend supports foreground commands with inherited
//! standard streams. File actions, process groups, and sandbox restrictions
//! remain explicit `Unsupported` boundaries.

const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const System = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// Parent process environment used as the base for `.overlay` plans.
/// The caller retains ownership and must keep it alive while this host is used.
environ_map: ?*const std.process.Environ.Map = null,
children: std.AutoHashMapUnmanaged(Host.Process, std.process.Child) = .empty,
next_process: u32 = 1,

pub fn deinit(system: *System) void {
    var children = system.children.valueIterator();
    while (children.next()) |child| child.kill(system.io);
    system.children.deinit(system.gpa);
    system.* = undefined;
}

pub fn host(system: *System) Host {
    return .{
        .userdata = system,
        .vtable = &vtable,
    };
}

const vtable: Host.VTable = .{
    .spawn = spawn,
    .wait = wait,
    .resolve_working_directory = resolveWorkingDirectory,
};

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) Host.Error!Host.SpawnResult {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (plan.file_actions.len != 0 or
        plan.process_group != .inherit or
        plan.sandbox != .inherit)
    {
        return error.Unsupported;
    }

    var owned_argv: ?[][]const u8 = null;
    defer if (owned_argv) |argv| system.gpa.free(argv);
    // `std.process.spawn` identifies the executable through `argv[0]`. Use the
    // already-resolved executable here so the host never performs another PATH
    // search; the remaining arguments retain the command plan's representation.
    const argv = if (std.mem.eql(u8, plan.executable, plan.argv[0]))
        plan.argv
    else argv: {
        const copy = try system.gpa.dupe([]const u8, plan.argv);
        copy[0] = plan.executable;
        owned_argv = copy;
        break :argv copy;
    };

    var environment = try system.prepareEnvironment(plan.environment);
    defer if (environment) |*map| map.deinit();

    try system.children.ensureUnusedCapacity(system.gpa, 1);
    const child = std.process.spawn(system.io, .{
        .argv = argv,
        .cwd = switch (plan.cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
        },
        .environ_map = if (environment) |*map| map else null,
    }) catch |err| return mapSpawnError(err);

    const process = system.nextProcess();
    system.children.putAssumeCapacityNoClobber(process, child);
    return .{
        .process = process,
        .sandbox_coverage = .not_requested,
    };
}

fn prepareEnvironment(
    system: *System,
    environment: CommandPlan.Environment,
) Host.Error!?std.process.Environ.Map {
    return switch (environment) {
        .inherit => null,
        .overlay => |variables| map: {
            if (variables.len == 0) break :map null;
            const parent = system.environ_map orelse return error.InvalidArguments;
            var map = parent.clone(system.gpa) catch return error.OutOfMemory;
            errdefer map.deinit();
            try applyEnvironmentVariables(&map, variables);
            break :map map;
        },
        .replace => |variables| map: {
            var map = std.process.Environ.Map.init(system.gpa);
            errdefer map.deinit();
            try applyEnvironmentVariables(&map, variables);
            break :map map;
        },
    };
}

fn applyEnvironmentVariables(
    map: *std.process.Environ.Map,
    variables: []const CommandPlan.EnvironmentVariable,
) Host.Error!void {
    for (variables) |variable| {
        if (!std.process.Environ.Map.validateKeyForPut(variable.name))
            return error.InvalidArguments;
        map.put(variable.name, variable.value) catch return error.OutOfMemory;
    }
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const child = system.children.getPtr(process) orelse return error.InvalidArguments;
    const termination = child.wait(system.io) catch |err| return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
    _ = system.children.remove(process);
    return switch (termination) {
        .exited => |status| .{ .exited = status },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped => |signal| .{ .stopped = @intFromEnum(signal) },
        .unknown => |status| .{ .unknown = status },
    };
}

fn nextProcess(system: *System) Host.Process {
    while (true) {
        const process: Host.Process = @enumFromInt(system.next_process);
        system.next_process +%= 1;
        if (system.next_process == 0) system.next_process = 1;
        if (!system.children.contains(process)) return process;
    }
}

fn mapSpawnError(err: std.process.SpawnError) Host.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound, error.NotDir => error.CommandNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.InvalidExe, error.IsDir => error.InvalidExecutable,
        error.NoDevice,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ResourceLimitReached,
        => error.ResourceUnavailable,
        error.OperationUnsupported => error.Unsupported,
        error.InvalidWtf8,
        error.InvalidBatchScriptArg,
        error.InvalidName,
        error.BadPathName,
        error.NameTooLong,
        => error.InvalidArguments,
        else => error.Unexpected,
    };
}

fn resolveWorkingDirectory(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Host.WorkingDirectoryRequest,
) Host.Error![]u8 {
    const system: *System = @ptrCast(@alignCast(userdata.?));

    const resolved = if (std.fs.path.isAbsolute(request.path))
        try std.fs.path.resolve(allocator, &.{request.path})
    else if (request.current) |current|
        if (std.fs.path.isAbsolute(current))
            try std.fs.path.resolve(allocator, &.{ current, request.path })
        else
            try resolveFromProcessDirectory(system.io, allocator, &.{ current, request.path })
    else
        try resolveFromProcessDirectory(system.io, allocator, &.{request.path});
    errdefer allocator.free(resolved);

    const directory = std.Io.Dir.cwd().openDir(system.io, resolved, .{
        .access_sub_paths = false,
    }) catch |err| return mapOpenDirectoryError(err);
    directory.close(system.io);
    return resolved;
}

fn resolveFromProcessDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) Host.Error![]u8 {
    std.debug.assert(paths.len <= 2);
    const process_directory = std.process.currentPathAlloc(io, allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CurrentDirUnlinked => error.InvalidArguments,
        else => error.Unexpected,
    };
    defer allocator.free(process_directory);

    var all_paths: [3][]const u8 = undefined;
    all_paths[0] = process_directory;
    @memcpy(all_paths[1..][0..paths.len], paths);
    return std.fs.path.resolve(allocator, all_paths[0 .. paths.len + 1]);
}

fn mapOpenDirectoryError(err: std.Io.Dir.OpenError) Host.Error {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NoDevice,
        error.SystemResources,
        => error.ResourceUnavailable,
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        error.NetworkNotFound,
        error.NameTooLong,
        error.BadPathName,
        => error.InvalidArguments,
        else => error.Unexpected,
    };
}

test "system host resolves and validates working directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "child", .default_dir);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    const expected = try std.fs.path.resolve(std.testing.allocator, &.{ root_path, "child" });
    defer std.testing.allocator.free(expected);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = root_path,
        .path = "child" ++ std.fs.path.sep_str ++ ".." ++ std.fs.path.sep_str ++ "child",
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "system host accepts absolute directories independently of shell state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = "relative-shell-directory",
        .path = path,
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(path, resolved);
}

test "system host uses the process directory when shell state is unavailable" {
    const expected = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = null,
        .path = ".",
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "system host rejects missing paths and non-directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "file", .{});
    file.close(std.testing.io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.resolveWorkingDirectory(std.testing.allocator, .{
            .current = root_path,
            .path = "missing",
        }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.resolveWorkingDirectory(std.testing.allocator, .{
            .current = root_path,
            .path = "file",
        }),
    );
}

test "system host working-directory resolution handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveWithAllocator,
        .{ system.host(), root_buffer[0..root_len] },
    );
}

fn resolveWithAllocator(
    allocator: std.mem.Allocator,
    system_host: Host,
    current: []const u8,
) !void {
    const resolved = try system_host.resolveWorkingDirectory(allocator, .{
        .current = current,
        .path = ".",
    });
    defer allocator.free(resolved);
}

test "system host owns foreground processes until wait" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();

    const spawned = try system_host.spawn(exitCommand(23));
    try std.testing.expectEqual(@as(usize, 1), system.children.count());
    try std.testing.expectEqual(@as(?CommandPlan.ProcessGroup, null), spawned.process_group);
    try std.testing.expectEqual(.not_requested, spawned.sandbox_coverage);

    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 23 },
        try system_host.wait(spawned.process),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.wait(spawned.process),
    );
}

test "system host reports missing executables" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const missing = "habush-executable-that-does-not-exist";

    try std.testing.expectError(
        error.CommandNotFound,
        system.host().spawn(.{ .executable = missing, .argv = &.{missing} }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host rejects process features before spawning" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const executable = exitCommand(0).executable;
    const argv = exitCommand(0).argv;
    try std.testing.expectError(
        error.Unsupported,
        system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .file_actions = &.{.{ .close = .stdout }},
        }),
    );
    try std.testing.expectError(
        error.Unsupported,
        system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .process_group = .create,
        }),
    );
    try std.testing.expectError(
        error.Unsupported,
        system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .sandbox = .{ .restrict = .{} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host prepares replacement and overlay environments" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PARENT", "visible");
    try parent.put("SHARED", "parent");
    var system: System = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &parent,
    };
    defer system.deinit();

    var overlay = (try system.prepareEnvironment(.{ .overlay = &.{
        .{ .name = "CHILD", .value = "visible" },
        .{ .name = "SHARED", .value = "child" },
    } })).?;
    defer overlay.deinit();
    try std.testing.expectEqualStrings("visible", overlay.get("PARENT").?);
    try std.testing.expectEqualStrings("visible", overlay.get("CHILD").?);
    try std.testing.expectEqualStrings("child", overlay.get("SHARED").?);
    try std.testing.expectEqualStrings("parent", parent.get("SHARED").?);

    var replacement = (try system.prepareEnvironment(.{ .replace = &.{
        .{ .name = "ONLY", .value = "replacement" },
    } })).?;
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 1), replacement.count());
    try std.testing.expectEqualStrings("replacement", replacement.get("ONLY").?);
    try std.testing.expect(replacement.get("PARENT") == null);
}

test "system host passes replacement environments to child processes" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const variables = [_]CommandPlan.EnvironmentVariable{
        .{ .name = "HABUSH_SYSTEM_HOST", .value = "expected" },
    };
    var plan = environmentCheckCommand();
    plan.environment = .{ .replace = &variables };

    const spawned = try system.host().spawn(plan);
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 0 },
        try system.host().wait(spawned.process),
    );
}

test "system host requires a parent environment for overlays" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        system.host().spawn(.{
            .executable = exitCommand(0).executable,
            .argv = exitCommand(0).argv,
            .environment = .{ .overlay = &.{.{ .name = "NAME", .value = "value" }} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

fn exitCommand(comptime status: u8) CommandPlan {
    const script = std.fmt.comptimePrint("exit {d}", .{status});
    return switch (@import("builtin").os.tag) {
        .windows => .{
            .executable = "cmd.exe",
            .argv = &.{ "shell-spelling", "/C", script },
        },
        else => .{
            .executable = "/bin/sh",
            .argv = &.{ "shell-spelling", "-c", script },
        },
    };
}

fn environmentCheckCommand() CommandPlan {
    return switch (@import("builtin").os.tag) {
        .windows => .{
            .executable = "cmd.exe",
            .argv = &.{
                "shell-spelling",
                "/D",
                "/C",
                "if \"%HABUSH_SYSTEM_HOST%\"==\"expected\" (exit 0) else (exit 1)",
            },
        },
        else => .{
            .executable = "/bin/sh",
            .argv = &.{
                "shell-spelling",
                "-c",
                "test \"$HABUSH_SYSTEM_HOST\" = expected",
            },
        },
    };
}
