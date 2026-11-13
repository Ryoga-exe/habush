//! Owned byte buffer with a byte cursor and one reversible editing snapshot.
//! UTF-8 cursor movement follows codepoints; invalid bytes remain editable.
const std = @import("std");
const unicode = @import("unicode.zig");
const Buffer = @This();

gpa: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,
cursor: usize = 0,
revision: u64 = 0,
previous: ?Snapshot = null,

const Snapshot = struct { bytes: std.ArrayList(u8), cursor: usize };

pub fn deinit(buffer: *Buffer) void {
    buffer.bytes.deinit(buffer.gpa);
    if (buffer.previous) |*snapshot| snapshot.bytes.deinit(buffer.gpa);
    buffer.* = undefined;
}

pub fn text(buffer: Buffer) []const u8 {
    return buffer.bytes.items;
}

pub fn replace(buffer: *Buffer, start: usize, end: usize, value: []const u8) std.mem.Allocator.Error!void {
    std.debug.assert(start <= end and end <= buffer.bytes.items.len);
    var snapshot: std.ArrayList(u8) = .empty;
    errdefer snapshot.deinit(buffer.gpa);
    try snapshot.appendSlice(buffer.gpa, buffer.bytes.items);
    try buffer.bytes.ensureTotalCapacity(buffer.gpa, buffer.bytes.items.len - (end - start) + value.len);
    if (buffer.previous) |*previous| previous.bytes.deinit(buffer.gpa);
    buffer.previous = .{ .bytes = snapshot, .cursor = buffer.cursor };
    buffer.bytes.replaceRangeAssumeCapacity(start, end - start, value);
    buffer.cursor = start + value.len;
    buffer.revision +%= 1;
}

pub fn insert(buffer: *Buffer, value: []const u8) std.mem.Allocator.Error!void {
    return buffer.replace(buffer.cursor, buffer.cursor, value);
}

pub fn left(buffer: *Buffer) void {
    if (buffer.cursor == 0) return;
    buffer.cursor = previousBoundary(buffer.bytes.items, buffer.cursor);
}

pub fn right(buffer: *Buffer) void {
    if (buffer.cursor == buffer.bytes.items.len) return;
    buffer.cursor = nextBoundary(buffer.bytes.items, buffer.cursor);
}

pub fn lineStart(buffer: Buffer) usize {
    return if (std.mem.lastIndexOfScalar(u8, buffer.text()[0..buffer.cursor], '\n')) |index| index + 1 else 0;
}

pub fn lineEnd(buffer: Buffer) usize {
    return std.mem.indexOfScalarPos(u8, buffer.text(), buffer.cursor, '\n') orelse buffer.text().len;
}

/// Words are whitespace-delimited; shell syntax and path punctuation stay intact.
pub fn wordStart(buffer: Buffer) usize {
    const source = buffer.text();
    var index = buffer.cursor;
    while (index != 0) {
        const previous = previousBoundary(source, index);
        if (!unicode.isWhitespace(source[previous..])) break;
        index = previous;
    }
    while (index != 0) {
        const previous = previousBoundary(source, index);
        if (unicode.isWhitespace(source[previous..])) break;
        index = previous;
    }
    return index;
}

pub fn wordEnd(buffer: Buffer) usize {
    const source = buffer.text();
    var index = buffer.cursor;
    while (index < source.len and unicode.isWhitespace(source[index..])) index = nextBoundary(source, index);
    while (index < source.len and !unicode.isWhitespace(source[index..])) index = nextBoundary(source, index);
    return index;
}

/// Vertical movement retains the Unicode scalar column and clamps on short lines.
pub fn vertical(buffer: *Buffer, previous_line: bool) bool {
    const source = buffer.text();
    const start = buffer.lineStart();
    const end = buffer.lineEnd();
    var column: usize = 0;
    var index = start;
    while (index < buffer.cursor) : (column += 1) index = nextBoundary(source, index);
    const target_start = if (previous_line) target: {
        if (start == 0) return false;
        break :target if (std.mem.lastIndexOfScalar(u8, source[0 .. start - 1], '\n')) |newline| newline + 1 else 0;
    } else target: {
        if (end == source.len) return false;
        break :target end + 1;
    };
    const target_end = std.mem.indexOfScalarPos(u8, source, target_start, '\n') orelse source.len;
    index = target_start;
    while (index < target_end and column != 0) : (column -= 1) index = nextBoundary(source, index);
    buffer.cursor = index;
    return true;
}

pub fn backspace(buffer: *Buffer) std.mem.Allocator.Error!void {
    if (buffer.cursor == 0) return;
    return buffer.replace(previousBoundary(buffer.bytes.items, buffer.cursor), buffer.cursor, "");
}

pub fn delete(buffer: *Buffer) std.mem.Allocator.Error!void {
    if (buffer.cursor == buffer.bytes.items.len) return;
    return buffer.replace(buffer.cursor, nextBoundary(buffer.bytes.items, buffer.cursor), "");
}

pub fn undo(buffer: *Buffer) bool {
    const snapshot = buffer.previous orelse return false;
    buffer.previous = .{ .bytes = buffer.bytes, .cursor = buffer.cursor };
    buffer.bytes = snapshot.bytes;
    buffer.cursor = snapshot.cursor;
    buffer.revision +%= 1;
    return true;
}

const nextBoundary = unicode.nextCodepointBoundary;
const previousBoundary = unicode.previousCodepointBoundary;

test "editing preserves UTF-8 bytes and undo owns its snapshot" {
    var buffer: Buffer = .{ .gpa = std.testing.allocator };
    defer buffer.deinit();
    try buffer.insert("a日本z");
    buffer.left();
    try buffer.backspace();
    try std.testing.expectEqualStrings("a日z", buffer.text());
    try std.testing.expect(buffer.undo());
    try std.testing.expectEqualStrings("a日本z", buffer.text());
    try buffer.insert("!");
    try std.testing.expectEqualStrings("a日本!z", buffer.text());
    buffer.cursor = 0;
    try buffer.delete();
    try std.testing.expectEqualStrings("日本!z", buffer.text());
}

test "word boundaries keep paths, Unicode, and malformed bytes between whitespace" {
    var buffer: Buffer = .{ .gpa = std.testing.allocator };
    defer buffer.deinit();
    for ([_]struct { source: []const u8, cursor: usize, start: usize, end: usize }{
        .{ .source = "", .cursor = 0, .start = 0, .end = 0 },
        .{ .source = "  abc  def\t", .cursor = 0, .start = 0, .end = 5 },
        .{ .source = "  abc  def\t", .cursor = 4, .start = 2, .end = 5 },
        .{ .source = "  abc  def\t", .cursor = 6, .start = 2, .end = 10 },
        .{ .source = "  abc  def\t", .cursor = 11, .start = 7, .end = 11 },
        .{ .source = "./foo-bar/file.zig", .cursor = 9, .start = 0, .end = 18 },
        .{ .source = "日\u{3000}か\u{3099}👩🏽‍🚀\n本", .cursor = "日\u{3000}か".len, .start = "日\u{3000}".len, .end = "日\u{3000}か\u{3099}👩🏽‍🚀".len },
        .{ .source = "日\n本", .cursor = "日".len, .start = 0, .end = "日\n本".len },
        .{ .source = "a\u{85}\u{a0}\u{2028}\u{2029}b", .cursor = 1, .start = 0, .end = "a\u{85}\u{a0}\u{2028}\u{2029}b".len },
        .{ .source = "a\xff\xcc x\x81", .cursor = 2, .start = 0, .end = 3 },
    }) |case| {
        try buffer.replace(0, buffer.text().len, case.source);
        buffer.cursor = case.cursor;
        const revision = buffer.revision;
        try std.testing.expectEqual(case.start, buffer.wordStart());
        try std.testing.expectEqual(case.end, buffer.wordEnd());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
        try std.testing.expectEqual(revision, buffer.revision);
    }
}
