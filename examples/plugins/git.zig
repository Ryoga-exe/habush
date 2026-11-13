//! Git-specific interpretation belongs to the guest. The reader supplies scoped
//! bytes and distinguishes absent files, non-files, and denied access.
const std = @import("std");

pub fn label(gpa: std.mem.Allocator, fs: anytype, cwd: []const u8) !?[]const u8 {
    if (!std.fs.path.isAbsolutePosix(cwd)) return null;
    var root: []const u8 = try std.fs.path.resolveAllocPosix(gpa, &.{cwd});
    for (0..64) |_| {
        const head_path = try std.fs.path.resolveAllocPosix(gpa, &.{ root, ".git", "HEAD" });
        const head = fs.readFile(gpa, head_path) catch |err| switch (err) {
            error.NotFound, error.NotFile => null,
            error.PermissionDenied => return null,
            else => return err,
        };
        if (head) |bytes| return headLabel(bytes);
        const marker_path = try std.fs.path.resolveAllocPosix(gpa, &.{ root, ".git" });
        const marker = fs.readFile(gpa, marker_path) catch |err| switch (err) {
            error.NotFound => null,
            error.NotFile, error.PermissionDenied => return null,
            else => return err,
        };
        if (marker) |bytes| {
            if (!std.mem.startsWith(u8, bytes, "gitdir: ")) return null;
            const path = std.mem.trimEnd(u8, bytes[8..], "\r\n");
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return null;
            const target = try std.fs.path.resolveAllocPosix(gpa, &.{ root, path, "HEAD" });
            const contents = fs.readFile(gpa, target) catch |err| switch (err) {
                error.NotFound, error.NotFile, error.PermissionDenied => return null,
                else => return err,
            };
            return headLabel(contents);
        }
        const parent = std.fs.path.dirnamePosix(root) orelse return null;
        if (std.mem.eql(u8, root, parent)) return null;
        root = parent;
    }
    return null;
}

fn headLabel(bytes: []const u8) ?[]const u8 {
    const head = std.mem.trimEnd(u8, bytes, "\r\n");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, head, prefix)) {
        const branch = head[prefix.len..];
        if (branch.len == 0) return null;
        for (branch) |byte| if (std.ascii.isControl(byte)) return null;
        return branch;
    }
    if (head.len != 40 and head.len != 64) return null;
    for (head) |byte| if (!std.ascii.isHex(byte)) return null;
    return head[0..8];
}

test "guest Git discovery handles parents, detached HEAD, worktrees, missing and denied metadata" {
    const File = struct { path: []const u8, contents: ?[]const u8 };
    const Fs = struct {
        files: []const File,
        root: []const u8,
        fn readFile(fs: @This(), gpa: std.mem.Allocator, path: []const u8) ![]u8 {
            if (!std.mem.startsWith(u8, path, fs.root)) return error.PermissionDenied;
            for (fs.files) |file| if (std.mem.eql(u8, file.path, path)) {
                return gpa.dupe(u8, file.contents orelse return error.NotFile);
            };
            return error.NotFound;
        }
    };
    const Case = struct { cwd: []const u8, files: []const File, expected: ?[]const u8, root: []const u8 = "/project/" };
    const cases = [_]Case{
        .{ .cwd = "/project/sub", .files = &.{.{ .path = "/project/.git/HEAD", .contents = "ref: refs/heads/feature/topic\n" }}, .expected = "feature/topic" },
        .{ .cwd = "/project", .files = &.{.{ .path = "/project/.git/HEAD", .contents = "0123456789012345678901234567890123456789\n" }}, .expected = "01234567" },
        .{ .cwd = "/project/work", .files = &.{
            .{ .path = "/project/work/.git", .contents = "gitdir: ../metadata/work\n" },
            .{ .path = "/project/metadata/work/HEAD", .contents = "ref: refs/heads/work\n" },
        }, .expected = "work" },
        .{ .cwd = "/project/work", .root = "/", .files = &.{
            .{ .path = "/project/work/.git", .contents = "gitdir: /\n" },
            .{ .path = "/HEAD", .contents = "ref: refs/heads/root\n" },
        }, .expected = "root" },
        .{ .cwd = "/project", .files = &.{}, .expected = null },
        .{ .cwd = "/project/work", .files = &.{.{ .path = "/project/work/.git", .contents = "gitdir: /private/metadata\n" }}, .expected = null },
        .{ .cwd = "/project/sub", .files = &.{
            .{ .path = "/project/sub/.git", .contents = null },
            .{ .path = "/project/.git/HEAD", .contents = "ref: refs/heads/outer\n" },
        }, .expected = null },
        .{ .cwd = "/project", .files = &.{.{ .path = "/project/.git/HEAD", .contents = "ref: refs/heads/bad\x1b\n" }}, .expected = null },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const actual = try label(arena.allocator(), Fs{ .files = case.files, .root = case.root }, case.cwd);
        if (case.expected) |expected| try std.testing.expectEqualStrings(expected, actual.?) else try std.testing.expect(actual == null);
    }
}
