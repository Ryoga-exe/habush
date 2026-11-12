//! CLI-owned, length-prefixed source records. A separate lock survives compaction.
const std = @import("std");
const History = @import("habush-edit").History;
const Io = std.Io;
const HistoryStore = @This();

gpa: std.mem.Allocator,
io: Io,
path: []const u8,
max_bytes: usize = 8 * 1024 * 1024,

pub const max_file_bytes = 64 * 1024 * 1024;
pub const max_entry_bytes = 64 * 1024;
const magic = "habush\x00\x01";
const private_file: Io.File.Permissions = if (@import("builtin").target.os.tag == .windows) .default_file else .fromMode(0o600);
const private_dir: Io.Dir.Permissions = if (@import("builtin").target.os.tag == .windows) .default_dir else .fromMode(0o700);

pub fn load(store: HistoryStore, history: *History) !void {
    const locked = try store.lock();
    defer locked.close(store.io);
    const file = locked.dir.openFile(store.io, std.fs.path.basename(store.path), .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(store.io);
    const bytes = try store.read(file);
    defer store.gpa.free(bytes);
    const end = try validEnd(bytes);
    var offset: usize = magic.len;
    while (offset < end) {
        const size = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        try history.append(bytes[offset + 4 ..][0..size]);
        offset += 4 + size;
    }
}

pub fn append(store: HistoryStore, source: []const u8) !void {
    const entry = std.mem.trimEnd(u8, source, "\n");
    if (entry.len > max_entry_bytes or entry.len + 4 + magic.len > store.max_bytes or
        std.mem.indexOfScalar(u8, entry, 0) != null or std.mem.trim(u8, entry, &std.ascii.whitespace).len == 0) return;
    const locked = try store.lock();
    defer locked.close(store.io);
    const name = std.fs.path.basename(store.path);
    const file = locked.dir.openFile(store.io, name, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => try locked.dir.createFile(store.io, name, .{ .read = true, .exclusive = true, .permissions = private_file }),
        else => return err,
    };
    var file_open = true;
    defer if (file_open) file.close(store.io);
    try file.setPermissions(store.io, private_file);
    // shortcut: scans the bounded file per append; use tail/index reads if I/O becomes measurable.
    const bytes = try store.read(file);
    defer store.gpa.free(bytes);
    const end = try validEnd(bytes);
    var start: usize = magic.len;
    var offset = start;
    var last: []const u8 = "";
    while (offset < end) {
        const size = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        last = bytes[offset + 4 ..][0..size];
        offset += 4 + size;
    }
    if (std.mem.eql(u8, last, entry)) return;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(entry.len), .little);
    if (@max(end, magic.len) + 4 + entry.len > store.max_bytes) {
        while (end - start + magic.len + 4 + entry.len > store.max_bytes)
            start += 4 + std.mem.readInt(u32, bytes[start..][0..4], .little);
        var replacement = try locked.dir.createFileAtomic(store.io, name, .{ .replace = true, .permissions = private_file });
        defer replacement.deinit(store.io);
        var writer = replacement.file.writer(store.io, &.{});
        try writer.interface.writeAll(magic);
        try writer.interface.writeAll(bytes[start..end]);
        try writer.interface.writeAll(&length);
        try writer.interface.writeAll(entry);
        try writer.interface.flush();
        try replacement.file.sync(store.io);
        file.close(store.io);
        file_open = false;
        try replacement.replace(store.io);
    } else {
        if (end < magic.len) try file.writePositionalAll(store.io, magic, 0);
        try file.setLength(store.io, @max(end, magic.len));
        try file.writePositionalAll(store.io, &length, @max(end, magic.len));
        try file.writePositionalAll(store.io, entry, @max(end, magic.len) + 4);
        try file.sync(store.io);
    }
}

fn read(store: HistoryStore, file: Io.File) ![]u8 {
    const stat = try file.stat(store.io);
    if (stat.kind != .file) return error.InvalidHistoryFile;
    if (stat.size > max_file_bytes) return error.HistoryTooLarge;
    const bytes = try store.gpa.alloc(u8, @intCast(stat.size));
    errdefer store.gpa.free(bytes);
    if (try file.readPositionalAll(store.io, bytes, 0) != bytes.len) return error.InvalidHistoryFile;
    return bytes;
}

fn validEnd(bytes: []const u8) !usize {
    if (bytes.len < magic.len) {
        if (!std.mem.startsWith(u8, magic, bytes)) return error.InvalidHistoryFile;
        return 0;
    }
    if (!std.mem.startsWith(u8, bytes, magic)) return error.InvalidHistoryFile;
    var offset: usize = magic.len;
    while (bytes.len - offset >= 4) {
        const size = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        if (size == 0 or size > max_entry_bytes) return error.InvalidHistoryFile;
        if (size > bytes.len - offset - 4) break;
        if (std.mem.indexOfScalar(u8, bytes[offset + 4 ..][0..size], 0) != null) return error.InvalidHistoryFile;
        offset += 4 + size;
    }
    return offset;
}

const Locked = struct {
    dir: Io.Dir,
    file: Io.File,

    fn close(locked: Locked, io: Io) void {
        locked.file.close(io);
        locked.dir.close(io);
    }
};

fn lock(store: HistoryStore) !Locked {
    const dir = try Io.Dir.cwd().createDirPathOpen(store.io, std.fs.path.dirname(store.path) orelse ".", .{ .permissions = private_dir });
    errdefer dir.close(store.io);
    const name = try store.gpa.print("{s}.lock", .{std.fs.path.basename(store.path)});
    defer store.gpa.free(name);
    const file = try dir.createFile(store.io, name, .{ .truncate = false, .lock = .exclusive, .permissions = private_file });
    return .{ .dir = dir, .file = file };
}

test "history survives restarts, concurrent writers, partial tails, and bounded compaction" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const history_path = try std.fs.path.join(gpa, &.{ path, "history" });
    defer gpa.free(history_path);
    const first: HistoryStore = .{ .gpa = gpa, .io = io, .path = history_path, .max_bytes = 100 };
    const second = first;
    try first.append("cat <<EOF\none\ntwo\nEOF\n");
    try second.append("echo other session");
    const file = try tmp.dir.openFile(io, "history", .{ .mode = .read_write });
    try file.writePositionalAll(io, &.{ 12, 0, 0, 0, 'x' }, try file.length(io));
    file.close(io);
    var history: History = .{ .gpa = gpa };
    defer history.deinit();
    try first.load(&history);
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expectEqualStrings("cat <<EOF\none\ntwo\nEOF", history.entries.items[0]);
    try first.append("recovered");
    try second.append("last entry is kept while earlier records are compacted");
    var reloaded: History = .{ .gpa = gpa };
    defer reloaded.deinit();
    try second.load(&reloaded);
    try std.testing.expectEqualStrings("recovered", reloaded.entries.items[reloaded.entries.items.len - 2]);
    try std.testing.expectEqualStrings("last entry is kept while earlier records are compacted", reloaded.entries.items[reloaded.entries.items.len - 1]);
    const saved = try tmp.dir.readFileAlloc(io, "history", gpa, .limited(100));
    defer gpa.free(saved);
    try std.testing.expectEqual(saved.len, try validEnd(saved));
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = "unrecognized format" });
    try std.testing.expectError(error.InvalidHistoryFile, first.append("do not overwrite"));
    try tmp.dir.deleteFile(io, "history");
    const Write = struct {
        fn run(store: HistoryStore, label: u8) !void {
            for (0..8) |index| {
                var text: [2]u8 = .{ label, '0' + @as(u8, @intCast(index)) };
                try store.append(&text);
            }
        }
    };
    var shared = first;
    shared.max_bytes = 4096;
    var a = try io.concurrent(Write.run, .{ shared, 'a' });
    defer _ = a.cancel(io) catch {};
    var b = try io.concurrent(Write.run, .{ shared, 'b' });
    defer _ = b.cancel(io) catch {};
    try a.await(io);
    try b.await(io);
    var combined: History = .{ .gpa = gpa };
    defer combined.deinit();
    try shared.load(&combined);
    try std.testing.expectEqual(@as(usize, 16), combined.entries.items.len);
}
