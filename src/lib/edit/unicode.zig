//! Byte offsets remain authoritative; malformed UTF-8 consumes one byte.
const std = @import("std");
const uucode = @import("uucode");

pub const Scalar = struct { len: usize, codepoint: ?u21 };

pub fn decode(source: []const u8) Scalar {
    const invalid: Scalar = .{ .len = 1, .codepoint = null };
    const len = std.unicode.utf8ByteSequenceLength(source[0]) catch return invalid;
    if (len > source.len) return invalid;
    return .{ .len = len, .codepoint = std.unicode.utf8Decode(source[0..len]) catch return invalid };
}

pub fn nextCodepointBoundary(source: []const u8, start: usize) usize {
    return start + decode(source[start..]).len;
}

pub fn previousCodepointBoundary(source: []const u8, end: usize) usize {
    var start = end - 1;
    var remaining: usize = 3;
    while (start != 0 and source[start] & 0xc0 == 0x80 and remaining != 0) : (remaining -= 1) start -= 1;
    return if (nextCodepointBoundary(source, start) == end) start else end - 1;
}

pub fn isWhitespace(source: []const u8) bool {
    const codepoint = decode(source).codepoint orelse return false;
    if (codepoint < 128) return std.ascii.isWhitespace(@intCast(codepoint));
    if (codepoint == 0x85) return true; // NEXT LINE is a control, not a separator.
    return switch (uucode.get(.general_category, codepoint)) {
        .separator_space, .separator_line, .separator_paragraph => true,
        else => false,
    };
}

/// `start` must be a grapheme boundary; invalid bytes never join a cluster.
pub fn nextGraphemeBoundary(source: []const u8, start: usize) usize {
    const first = decode(source[start..]);
    var previous = first.codepoint orelse return start + 1;
    var end = start + first.len;
    var state: uucode.grapheme.BreakState = .{};
    while (end < source.len) {
        const scalar = decode(source[end..]);
        const next = scalar.codepoint orelse break;
        if (uucode.grapheme.isBreak(previous, next, &state)) break;
        previous = next;
        end += scalar.len;
    }
    return end;
}

/// Matching bytes inside a changed grapheme must be repainted with that grapheme.
pub fn sharedGraphemePrefix(a: []const u8, b: []const u8) usize {
    var end: usize = 0;
    while (end < a.len and end < b.len) {
        const a_end = nextGraphemeBoundary(a, end);
        const b_end = nextGraphemeBoundary(b, end);
        if (!std.mem.eql(u8, a[end..a_end], b[end..b_end])) break;
        end = a_end;
    }
    return end;
}

test "grapheme boundaries retain original bytes and isolate malformed UTF-8" {
    const clusters = [_][]const u8{ "a", "か\u{3099}", "e\u{301}", "👩🏽‍🚀", "🇯🇵", "\xff", "\xcc", "x", "\x81" };
    const source = "aか\u{3099}e\u{301}👩🏽‍🚀🇯🇵\xff\xccx\x81";
    var index: usize = 0;
    for (clusters) |cluster| {
        const end = nextGraphemeBoundary(source, index);
        try std.testing.expectEqualStrings(cluster, source[index..end]);
        index = end;
    }
    try std.testing.expectEqual(source.len, index);
    try std.testing.expectEqual(@as(usize, 1), sharedGraphemePrefix("xe", "xe\u{301}"));
    try std.testing.expectEqual(@as(usize, 1), sharedGraphemePrefix("x👩", "x👩🏽‍🚀"));
    try std.testing.expectEqual(@as(usize, 3), sharedGraphemePrefix("日本", "日"));
}
