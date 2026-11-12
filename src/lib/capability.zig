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
pub const ReadError = error{ PermissionDenied, Unsupported, LimitExceeded, ReadFailed, Canceled };

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

    /// Portable '/' relative paths. Rejects links and parent steps rather than
    /// relying on optional resolve_beneath support or string-prefix checks.
    pub fn readFile(scope: Scope, io: Io, path: []const u8, buffer: []u8) ReadError!usize {
        if (!scope.permissions.fs_read) return error.PermissionDenied;
        if (!directory_reads_supported) return error.Unsupported;
        var directory = scope.directory orelse return error.PermissionDenied;
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "\x00\\:") != null) return error.PermissionDenied;
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
            const before = directory.statFile(io, part, .{ .follow_symlinks = false }) catch |err| return readError(err);
            if (before.kind != .file) return error.PermissionDenied;
            const file = directory.openFile(io, part, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| return readError(err);
            defer file.close(io);
            const stat = file.stat(io) catch |err| return readError(err);
            if (stat.kind != .file) return error.PermissionDenied;
            if (stat.size > buffer.len) return error.LimitExceeded;
            return file.readPositionalAll(io, buffer[0..@intCast(stat.size)], 0) catch |err| return readError(err);
        }
        unreachable;
    }
};

fn readError(err: anyerror) ReadError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop, error.NotDir, error.IsDir, error.FileNotFound => error.PermissionDenied,
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
    try std.testing.expectError(error.LimitExceeded, scope.readFile(io, "sub/file", bytes[0..2]));
    try std.testing.expectError(error.PermissionDenied, scope.narrow(.{}).narrow(.all).readFile(io, "sub/file", &bytes));
    for ([_][]const u8{ "../outside", "/outside", "sub/../../outside", "sub//file", "C:outside", "sub\\file", "link", "directory-link/sub/file" }) |path|
        try std.testing.expectError(error.PermissionDenied, scope.readFile(io, path, &bytes));
}
