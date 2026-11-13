//! Authority supplied by the embedding host, shared by plugin and tool adapters.
const std = @import("std");
const Io = std.Io;

pub const Set = packed struct(u8) {
    stdin: bool = false,
    stdout: bool = false,
    stderr: bool = false,
    fs_read: bool = false,
    source: bool = false,
    context: bool = false,
    _: u2 = 0,

    pub const all: Set = .{ .stdin = true, .stdout = true, .stderr = true, .fs_read = true, .source = true, .context = true };

    pub fn intersect(set: Set, ceiling: Set) Set {
        return @bitCast(@as(u8, @bitCast(set)) & @as(u8, @bitCast(ceiling)));
    }

    pub fn contains(set: Set, requested: Set) bool {
        return @as(u8, @bitCast(set.intersect(requested))) == @as(u8, @bitCast(requested));
    }
};

pub const directory_reads_supported = switch (@import("builtin").target.os.tag) {
    .linux, .macos, .freebsd => true,
    else => false,
};
pub const ReadError = error{ PermissionDenied, Unsupported, LimitExceeded, ReadFailed, Canceled, NotFound, NotFile };

/// Directory handles are borrowed until all operations have joined. Narrowing
/// retains resource identities and can only remove permissions.
pub const Scope = struct {
    permissions: Set = .{},
    directory: ?Io.Dir = null,

    pub fn narrow(scope: Scope, ceiling: Set) Scope {
        var result = scope;
        result.permissions = scope.permissions.intersect(ceiling);
        return result;
    }

    /// Relative or absolute names within the grant. Every open is relative to
    /// its directory handle; absolute-name translation grants no extra access.
    pub fn readFile(scope: Scope, io: Io, name: []const u8, buffer: []u8) ReadError!usize {
        if (!scope.permissions.fs_read) return error.PermissionDenied;
        if (!directory_reads_supported) return error.Unsupported;
        if (name.len > Io.Dir.max_path_bytes) return error.LimitExceeded;
        var directory = scope.directory orelse return error.PermissionDenied;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "\x00\\:") != null) return error.PermissionDenied;
        var path = name;
        var root_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        if (std.fs.path.isAbsolutePosix(path)) {
            const root = root_buffer[0 .. directory.realPath(io, &root_buffer) catch |err| return readError(err)];
            if (std.mem.eql(u8, path, root)) return error.NotFile;
            if (!std.mem.startsWith(u8, path, root)) return error.PermissionDenied;
            const start = if (std.mem.eql(u8, root, "/")) 1 else root.len + 1;
            if (start > path.len or path[start - 1] != '/') return error.PermissionDenied;
            path = path[start..];
        }
        var validation = std.mem.splitScalar(u8, path, '/');
        while (validation.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.PermissionDenied;
        }
        var owned = false;
        defer if (owned) directory.close(io);
        var components = std.mem.splitScalar(u8, path, '/');
        while (components.next()) |part| {
            if (components.peek() != null) {
                const child = directory.openDir(io, part, .{ .follow_symlinks = false }) catch |err| return readError(err);
                if (owned) directory.close(io);
                directory = child;
                owned = true;
                continue;
            }
            return readRegular(io, directory, part, buffer);
        }
        unreachable;
    }
};

fn readRegular(io: Io, directory: Io.Dir, name: []const u8, buffer: []u8) ReadError!usize {
    const before = directory.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return readError(err);
    if (before.kind == .directory) return error.NotFile;
    if (before.kind != .file) return error.PermissionDenied;
    const file = directory.openFile(io, name, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| return readError(err);
    defer file.close(io);
    const stat = file.stat(io) catch |err| return readError(err);
    if (stat.kind != .file) return error.PermissionDenied;
    if (stat.size > buffer.len) return error.LimitExceeded;
    return file.readPositionalAll(io, buffer[0..@intCast(stat.size)], 0) catch |err| return readError(err);
}

fn readError(err: anyerror) ReadError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.FileNotFound => error.NotFound,
        error.NotDir, error.IsDir => error.NotFile,
        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => error.PermissionDenied,
        else => error.ReadFailed,
    };
}

test "tool scopes only attenuate authority and directory reads cannot escape through paths or links" {
    if (!directory_reads_supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "private" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/sub/file", .data = "allowed" });
    try tmp.dir.symLink(io, "../outside", "root/link", .{});
    try tmp.dir.symLink(io, "../root", "root/directory-link", .{ .is_directory = true });
    const root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);
    const scope: Scope = .{ .permissions = .{ .fs_read = true }, .directory = root };
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("allowed", bytes[0..try scope.readFile(io, "sub/file", &bytes)]);
    const root_path = try root.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const absolute = try std.testing.allocator.print("{s}/sub/file", .{root_path});
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("allowed", bytes[0..try scope.readFile(io, absolute, &bytes)]);
    const sibling = try std.testing.allocator.print("{s}-other/file", .{root_path});
    defer std.testing.allocator.free(sibling);
    try std.testing.expectError(error.PermissionDenied, scope.readFile(io, sibling, &bytes));
    try std.testing.expectError(error.NotFound, scope.readFile(io, "missing", &bytes));
    try std.testing.expectError(error.NotFile, scope.readFile(io, "sub", &bytes));
    try std.testing.expectError(error.NotFile, scope.readFile(io, "sub/file/HEAD", &bytes));
    try std.testing.expectError(error.LimitExceeded, scope.readFile(io, "sub/file", bytes[0..2]));
    const oversized: [Io.Dir.max_path_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.LimitExceeded, scope.readFile(io, &oversized, &bytes));
    try std.testing.expectError(error.PermissionDenied, scope.narrow(.{}).narrow(.all).readFile(io, "sub/file", &bytes));
    for ([_][]const u8{ "../outside", "/outside", "sub/../../outside", "sub//file", "C:outside", "sub\\file", "link" }) |path|
        try std.testing.expectError(error.PermissionDenied, scope.readFile(io, path, &bytes));
    if (scope.readFile(io, "directory-link/sub/file", &bytes)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        // O_NOFOLLOW reports a symlink component as NOTDIR on some targets.
        try std.testing.expect(err == error.PermissionDenied or err == error.NotFile);
    }
}
