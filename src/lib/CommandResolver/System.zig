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
    const base = directory orelse "";
    // Keep .. for the filesystem to resolve after following symbolic links.
    const candidate = if (std.fs.path.isAbsolute(name))
        try allocator.dupe(u8, name)
    else if (std.fs.path.isAbsolute(base))
        try std.fs.path.join(allocator, &.{ base, name })
    else
        try std.fs.path.join(allocator, &.{ cwd orelse ".", base, name });
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
    // access reports long components that Zig 0.16's Linux stat treats as bugs.
    if (builtin.os.tag == .linux) {
        const access = try system.checkAccess(candidate);
        if (access != .executable) return access;
    }
    const stat = std.Io.Dir.cwd().statFile(system.io, candidate, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.NameTooLong, error.BadPathName, error.SymLinkLoop => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => error.Unexpected,
    };
    if (stat.kind != .file) return .missing;
    return if (builtin.os.tag == .linux) .executable else system.checkAccess(candidate);
}

fn checkAccess(system: *System, candidate: []const u8) CommandResolver.Error!CandidateStatus {
    std.Io.Dir.cwd().access(system.io, candidate, .{ .execute = true }) catch |err| return switch (err) {
        error.FileNotFound, error.NameTooLong, error.BadPathName, error.SymLinkLoop => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => error.Unexpected,
    };
    return .executable;
}

const default_executable_extensions: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ ".COM", ".EXE", ".BAT", ".CMD" },
    else => &.{},
};

test "system resolver handles search paths, explicit paths, and missing commands" {
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
    const resolver_value = system.resolver();

    const explicit = (try resolver_value.resolve(std.testing.allocator, .{
        .name = "." ++ std.fs.path.sep_str ++ "tool",
        .search_path = &.{},
        .cwd = directory,
    })).?;
    defer std.testing.allocator.free(explicit);
    const expected_explicit = try std.fs.path.join(std.testing.allocator, &.{ directory, ".", "tool" });
    defer std.testing.allocator.free(expected_explicit);
    try std.testing.expectEqualStrings(expected_explicit, explicit);
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

test "system resolver preserves symlink traversal for explicit paths and PATH entries" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "work", "real", "real/sub" }) |path|
        try tmp.dir.createDir(std.testing.io, path, .default_dir);
    for ([_][]const u8{ "work/tool", "real/tool" }) |path| {
        const file = try tmp.dir.createFile(std.testing.io, path, .{ .permissions = .executable_file });
        file.close(std.testing.io);
    }
    try tmp.dir.symLink(std.testing.io, "../real/sub", "work/link", .{ .is_directory = true });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const cwd = try std.fs.path.join(std.testing.allocator, &.{ root, "work" });
    defer std.testing.allocator.free(cwd);
    const absolute = try std.fs.path.join(std.testing.allocator, &.{ cwd, "link", "..", "tool" });
    defer std.testing.allocator.free(absolute);
    const search = std.fs.path.dirname(absolute).?;
    var system = System.init(std.testing.io, .{});
    for ([_]CommandResolver.Request{
        .{ .name = "link/../tool", .search_path = &.{}, .cwd = cwd },
        .{ .name = absolute, .search_path = &.{}, .cwd = "/wrong" },
        .{ .name = "tool", .search_path = &.{"link/.."}, .cwd = cwd },
        .{ .name = "tool", .search_path = &.{search}, .cwd = "/wrong" },
    }) |request| {
        const result = (try system.resolver().resolve(std.testing.allocator, request)).?;
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(absolute, result);
    }
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
