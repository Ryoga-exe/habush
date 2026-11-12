//! Bounded, in-memory submitted input. Recording belongs to the application.
const std = @import("std");
const Buffer = @import("Buffer.zig");
const History = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList([]const u8) = .empty,
bytes: usize = 0,
max_entries: usize = 1000,
max_bytes: usize = 1024 * 1024,

pub fn deinit(history: *History) void {
    for (history.entries.items) |entry| history.gpa.free(entry);
    history.entries.deinit(history.gpa);
    history.* = undefined;
}

pub fn append(history: *History, source: []const u8) std.mem.Allocator.Error!void {
    const entry = std.mem.trimEnd(u8, source, "\n");
    if (history.max_entries == 0 or entry.len > history.max_bytes or
        std.mem.trim(u8, entry, &std.ascii.whitespace).len == 0) return;
    if (history.entries.getLastOrNull()) |last|
        if (std.mem.eql(u8, last, entry)) return;
    const copy = try history.gpa.dupe(u8, entry);
    errdefer history.gpa.free(copy);
    try history.entries.ensureUnusedCapacity(history.gpa, 1);
    while (history.entries.items.len >= history.max_entries or history.bytes > history.max_bytes - entry.len) {
        const oldest = history.entries.orderedRemove(0);
        history.bytes -= oldest.len;
        history.gpa.free(oldest);
    }
    history.entries.appendAssumeCapacity(copy);
    history.bytes += entry.len;
}

/// One input's navigation state; the draft and byte cursor survive a round trip.
pub const Navigation = struct {
    draft: ?[]u8 = null,
    cursor: usize = 0,
    index: usize = 0,

    pub fn deinit(nav: *Navigation, gpa: std.mem.Allocator) void {
        if (nav.draft) |draft| gpa.free(draft);
        nav.* = undefined;
    }

    pub fn move(nav: *Navigation, history: *const History, buffer: *Buffer, previous: bool, prefix: bool) !bool {
        if (nav.draft == null) {
            if (!previous or history.entries.items.len == 0) return false;
            nav.draft = try buffer.gpa.dupe(u8, buffer.text());
            nav.cursor = buffer.cursor;
            nav.index = history.entries.items.len;
        }
        const draft = nav.draft.?;
        const match = if (prefix) draft[0..nav.cursor] else "";
        var index = nav.index;
        while (true) {
            if (previous) {
                if (index == 0) return false;
                index -= 1;
            } else {
                if (index == history.entries.items.len) return false;
                index += 1;
            }
            const value = if (index == history.entries.items.len) draft else history.entries.items[index];
            if (index != history.entries.items.len and !std.mem.startsWith(u8, value, match)) continue;
            try buffer.replace(0, buffer.text().len, value);
            if (index == history.entries.items.len) buffer.cursor = nav.cursor;
            nav.index = index;
            return true;
        }
    }
};

test "history bounds, ordinary traversal, prefix search, and draft restoration" {
    const gpa = std.testing.allocator;
    var history: History = .{ .gpa = gpa, .max_entries = 3, .max_bytes = 30 };
    defer history.deinit();
    for ([_][]const u8{ "discard", "echo one\n", "pwd", "echo two", "echo two\n", " \n" }) |source|
        try history.append(source);
    try std.testing.expectEqual(@as(usize, 3), history.entries.items.len);
    var buffer: Buffer = .{ .gpa = gpa };
    defer buffer.deinit();
    try buffer.insert("echo draft");
    buffer.cursor = 5;
    var nav: Navigation = .{};
    defer nav.deinit(gpa);
    try std.testing.expect(try nav.move(&history, &buffer, true, false));
    try std.testing.expectEqualStrings("echo two", buffer.text());
    try std.testing.expect(try nav.move(&history, &buffer, true, false));
    try std.testing.expectEqualStrings("pwd", buffer.text());
    try std.testing.expect(try nav.move(&history, &buffer, true, true));
    try std.testing.expectEqualStrings("echo one", buffer.text());
    try std.testing.expect(!try nav.move(&history, &buffer, true, false));
    try std.testing.expect(try nav.move(&history, &buffer, false, true));
    try std.testing.expectEqualStrings("echo two", buffer.text());
    try std.testing.expect(try nav.move(&history, &buffer, false, true));
    try std.testing.expectEqualStrings("echo draft", buffer.text());
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
    try history.append("123456789012345678901234567890");
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try history.append("1234567890123456789012345678901");
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
}
