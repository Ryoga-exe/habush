//! Native command resolution built on Zig's cross-platform filesystem APIs.

const builtin = @import("builtin");
const std = @import("std");
const CommandResolver = @import("../CommandResolver.zig");
const System = @This();

io: std.Io,
executable_extensions: []const []const u8,

pub const Options = struct {
    /// Extensions tried after an extensionless command name. Windows callers
    /// should initialize this from the session's PATHEXT value when available.
    executable_extensions: []const []const u8 = default_executable_extensions,
};

pub fn init(io: std.Io, options: Options) System {
    return .{
        .io = io,
        .executable_extensions = options.executable_extensions,
    };
}

pub fn resolver(system: *System) CommandResolver {
    return .{ .userdata = system, .vtable = &vtable };
}

const vtable: CommandResolver.VTable = .{ .resolve = resolve };

fn resolve(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: CommandResolver.Request,
) CommandResolver.Error!?[]u8 {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (std.fs.path.isAbsolute(request.name) or std.fs.path.dirname(request.name) != null)
        return system.resolveFrom(allocator, request.cwd, null, request.name);

    var denied = false;
    for (request.search_path) |directory| {
        const result = system.resolveFrom(
            allocator,
            request.cwd,
            directory,
            request.name,
        ) catch |err| switch (err) {
            error.AccessDenied => {
                denied = true;
                continue;
            },
            else => |other| return other,
        };
        if (result) |executable| return executable;
    }
    if (denied) return error.AccessDenied;
    return null;
}

fn resolveFrom(
    system: *System,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    directory: ?[]const u8,
    name: []const u8,
) CommandResolver.Error!?[]u8 {
    var denied = false;
    if (try system.tryCandidate(allocator, cwd, directory, name, &denied)) |candidate|
        return candidate;

    if (std.fs.path.extension(name).len == 0) {
        for (system.executable_extensions) |extension| {
            const extended_name = try std.mem.concat(allocator, u8, &.{ name, extension });
            defer allocator.free(extended_name);
            if (try system.tryCandidate(
                allocator,
                cwd,
                directory,
                extended_name,
                &denied,
            )) |candidate| return candidate;
        }
    }
    if (denied) return error.AccessDenied;
    return null;
}

fn tryCandidate(
    system: *System,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    directory: ?[]const u8,
    name: []const u8,
    denied: *bool,
) CommandResolver.Error!?[]u8 {
    var parts: [3][]const u8 = undefined;
    var len: usize = 0;
    if (cwd) |path| {
        parts[len] = path;
        len += 1;
    }
    if (directory) |path| {
        if (path.len != 0) {
            parts[len] = path;
            len += 1;
        }
    }
    parts[len] = name;
    len += 1;

    const candidate = try std.fs.path.resolve(allocator, parts[0..len]);
    errdefer allocator.free(candidate);
    switch (try system.checkCandidate(candidate)) {
        .executable => return candidate,
        .missing => {
            allocator.free(candidate);
            return null;
        },
        .denied => {
            denied.* = true;
            allocator.free(candidate);
            return null;
        },
    }
}

const CandidateStatus = enum {
    executable,
    missing,
    denied,
};

fn checkCandidate(system: *System, candidate: []const u8) CommandResolver.Error!CandidateStatus {
    const dir = std.Io.Dir.cwd();
    const stat = dir.statFile(system.io, candidate, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => error.Unexpected,
    };
    if (stat.kind != .file) return .missing;
    dir.access(system.io, candidate, .{ .execute = true }) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => error.Unexpected,
    };
    return .executable;
}

const default_executable_extensions: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ ".COM", ".EXE", ".BAT", ".CMD" },
    else => &.{},
};

test "system resolver searches native paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "tool", .{
        .permissions = .executable_file,
    });
    file.close(std.testing.io);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var system = System.init(std.testing.io, .{});

    const executable = (try system.resolver().resolve(std.testing.allocator, .{
        .name = "tool",
        .search_path = &.{directory},
        .cwd = null,
    })).?;
    defer std.testing.allocator.free(executable);

    const expected = try std.fs.path.resolve(std.testing.allocator, &.{ directory, "tool" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, executable);
}

test "system resolver handles explicit relative paths and missing commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "tool", .{
        .permissions = .executable_file,
    });
    file.close(std.testing.io);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var system = System.init(std.testing.io, .{});
    const resolver_value = system.resolver();

    const executable = (try resolver_value.resolve(std.testing.allocator, .{
        .name = "." ++ std.fs.path.sep_str ++ "tool",
        .search_path = &.{},
        .cwd = directory,
    })).?;
    defer std.testing.allocator.free(executable);
    try std.testing.expect(try resolver_value.resolve(std.testing.allocator, .{
        .name = "missing",
        .search_path = &.{directory},
        .cwd = null,
    }) == null);
}

test "system resolver tries configured executable extensions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "tool.test-exe", .{
        .permissions = .executable_file,
    });
    file.close(std.testing.io);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var system = System.init(std.testing.io, .{
        .executable_extensions = &.{".test-exe"},
    });

    const executable = (try system.resolver().resolve(std.testing.allocator, .{
        .name = "tool",
        .search_path = &.{directory},
        .cwd = null,
    })).?;
    defer std.testing.allocator.free(executable);

    try std.testing.expectEqualStrings("tool.test-exe", std.fs.path.basename(executable));
}

test "system resolver handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "tool", .{
        .permissions = .executable_file,
    });
    file.close(std.testing.io);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    var system = System.init(std.testing.io, .{});

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveWithAllocator,
        .{ system.resolver(), directory_buffer[0..directory_len] },
    );
}

fn resolveWithAllocator(
    allocator: std.mem.Allocator,
    resolver_value: CommandResolver,
    directory: []const u8,
) !void {
    const executable = (try resolver_value.resolve(allocator, .{
        .name = "tool",
        .search_path = &.{directory},
        .cwd = null,
    })).?;
    defer allocator.free(executable);
}
