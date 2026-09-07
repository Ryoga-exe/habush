//! Native `Host` implementation backed by Zig's cross-platform standard APIs.
//!
//! Process execution is added separately; until then, `spawn` and `wait`
//! explicitly report `Unsupported`.

const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const System = @This();

io: std.Io,

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
    _ = userdata;
    _ = plan;
    return error.Unsupported;
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    _ = userdata;
    _ = process;
    return error.Unsupported;
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

    var system: System = .{ .io = std.testing.io };
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

    var system: System = .{ .io = std.testing.io };
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

    var system: System = .{ .io = std.testing.io };
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

    var system: System = .{ .io = std.testing.io };
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

    var system: System = .{ .io = std.testing.io };
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
