//! Explicit, bounded Git metadata collection once per prompt, never per redraw.
const std = @import("std");
const Io = std.Io;
const Git = @import("habush-edit").Prompt.Git;

pub fn git(gpa: std.mem.Allocator, io: Io, cwd: []const u8) !?Git {
    if (!std.fs.path.isAbsolute(cwd)) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    var root = cwd;
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(100));
    for (0..64) |_| {
        if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return null;
        const marker = try std.fs.path.join(scratch, &.{ root, ".git" });
        const stat = Io.Dir.cwd().statFile(io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const parent = std.fs.path.dirname(root) orelse return null;
                if (std.mem.eql(u8, parent, root)) return null;
                root = parent;
                continue;
            },
            else => return err,
        };
        const directory = switch (stat.kind) {
            .directory => marker,
            .file => worktree: {
                const contents = try Io.Dir.cwd().readFileAlloc(io, marker, scratch, .limited(4096));
                if (!std.mem.startsWith(u8, contents, "gitdir: ")) return null;
                const path = std.mem.trim(u8, contents[8..], "\r\n");
                if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return null;
                break :worktree try std.fs.path.resolveAlloc(scratch, &.{ root, path });
            },
            else => return null,
        };
        const head_path = try std.fs.path.join(scratch, &.{ directory, "HEAD" });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, head_path, scratch, .limited(4096));
        const head = std.mem.trimEnd(u8, bytes, "\r\n");
        const branch_prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, head, branch_prefix)) {
            const branch = head[branch_prefix.len..];
            if (branch.len == 0) return null;
            for (branch) |byte| if (std.ascii.isControl(byte)) return null;
            const owned_root = try gpa.dupe(u8, root);
            errdefer gpa.free(owned_root);
            return .{ .root = owned_root, .branch = try gpa.dupe(u8, branch) };
        }
        if (head.len != 40 and head.len != 64) return null;
        for (head) |byte| if (!std.ascii.isHex(byte)) return null;
        const owned_root = try gpa.dupe(u8, root);
        errdefer gpa.free(owned_root);
        return .{ .root = owned_root, .commit = try gpa.dupe(u8, head) };
    }
    return null;
}

test "Git metadata finds parent repositories, detached HEADs, and linked worktrees" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/feature/topic\n" });
    const cwd = try tmp.dir.realPathFileAlloc(io, "repo/sub", gpa);
    const branch = (try git(gpa, io, cwd)).?;
    try std.testing.expectEqualStrings("feature/topic", branch.branch.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "0123456789012345678901234567890123456789\n" });
    try std.testing.expectEqualStrings("0123456789012345678901234567890123456789", (try git(gpa, io, cwd)).?.commit.?);
    try tmp.dir.createDirPath(io, "linked");
    try tmp.dir.writeFile(io, .{ .sub_path = "linked/.git", .data = "gitdir: ../repo/.git\n" });
    const linked = try tmp.dir.realPathFileAlloc(io, "linked", gpa);
    try std.testing.expect((try git(gpa, io, linked)).?.commit != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/bad\x1b\n" });
    try std.testing.expect(try git(gpa, io, linked) == null);
}
