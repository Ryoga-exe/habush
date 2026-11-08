//! Shell pattern matching without filesystem access. Quotes are represented by
//! a byte mask rather than interpreted again after word expansion. `?` matches
//! one UTF-8 scalar (or one invalid byte); ranges use scalar order and named
//! character classes use ASCII rules, independently of the process locale.

const std = @import("std");
const Pattern = @This();

bytes: []const u8,
quoted: []const bool = &.{},

pub fn hasMeta(pattern: Pattern) bool {
    for (pattern.bytes, 0..) |byte, index| {
        if (pattern.isQuoted(index)) continue;
        if (byte == '*' or byte == '?') return true;
        if (byte == '[' and pattern.bracket(index, 0) != null) return true;
    }
    return false;
}

/// Matches the complete value. Slash and leading dot have no special meaning;
/// pathname expansion applies those rules separately to each path component.
pub fn matches(pattern: Pattern, value: []const u8) bool {
    std.debug.assert(pattern.quoted.len == 0 or pattern.quoted.len == pattern.bytes.len);
    var cursor: usize = 0;
    var index: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (index < value.len) {
        if (cursor < pattern.bytes.len and pattern.bytes[cursor] == '*' and !pattern.isQuoted(cursor)) {
            cursor += 1;
            star = cursor;
            retry = index;
            continue;
        }
        if (cursor < pattern.bytes.len) {
            const point = character(value, index);
            if (pattern.bytes[cursor] == '?' and !pattern.isQuoted(cursor)) {
                cursor += 1;
                index += point.len;
                continue;
            }
            if (pattern.bytes[cursor] == '[' and !pattern.isQuoted(cursor)) {
                if (pattern.bracket(cursor, point.value)) |result| {
                    if (result.matched) {
                        cursor = result.end;
                        index += point.len;
                        continue;
                    }
                } else if (value[index] == '[') {
                    cursor += 1;
                    index += 1;
                    continue;
                }
            } else {
                const literal = character(pattern.bytes, cursor);
                if (literal.value == point.value) {
                    cursor += literal.len;
                    index += point.len;
                    continue;
                }
            }
        }
        const restart = star orelse return false;
        if (retry == value.len) return false;
        retry += character(value, retry).len;
        index = retry;
        cursor = restart;
    }
    while (cursor < pattern.bytes.len and pattern.bytes[cursor] == '*' and !pattern.isQuoted(cursor)) cursor += 1;
    return cursor == pattern.bytes.len;
}

fn isQuoted(pattern: Pattern, index: usize) bool {
    return pattern.quoted.len != 0 and pattern.quoted[index];
}

const Bracket = struct { end: usize, matched: bool };

fn bracket(pattern: Pattern, start: usize, point: u32) ?Bracket {
    var index = start + 1;
    const negate = index < pattern.bytes.len and pattern.bytes[index] == '!' and !pattern.isQuoted(index);
    if (negate) index += 1;
    var first = true;
    var matched = false;
    while (index < pattern.bytes.len) {
        if (pattern.bytes[index] == ']' and !pattern.isQuoted(index) and !first)
            return .{ .end = index + 1, .matched = matched != negate };
        first = false;
        if (pattern.bytes[index] == '[' and !pattern.isQuoted(index) and
            index + 1 < pattern.bytes.len and pattern.bytes[index + 1] == ':' and !pattern.isQuoted(index + 1))
        {
            const end = std.mem.indexOfPos(u8, pattern.bytes, index + 2, ":]") orelse return null;
            const class = classes.get(pattern.bytes[index + 2 .. end]) orelse return null;
            matched = matched or class.matches(point);
            index = end + 2;
            continue;
        }
        const low = character(pattern.bytes, index);
        index += low.len;
        if (index + 1 < pattern.bytes.len and pattern.bytes[index] == '-' and !pattern.isQuoted(index) and
            (pattern.bytes[index + 1] != ']' or pattern.isQuoted(index + 1)))
        {
            const high = character(pattern.bytes, index + 1);
            matched = matched or (point >= low.value and point <= high.value);
            index += 1 + high.len;
        } else matched = matched or point == low.value;
    }
    return null;
}

const Character = struct { value: u32, len: usize };

fn character(bytes: []const u8, start: usize) Character {
    const len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch
        return .{ .value = 0x110000 + @as(u32, bytes[start]), .len = 1 };
    if (len > bytes.len - start) return .{ .value = 0x110000 + @as(u32, bytes[start]), .len = 1 };
    const point = std.unicode.utf8Decode(bytes[start..][0..len]) catch
        return .{ .value = 0x110000 + @as(u32, bytes[start]), .len = 1 };
    return .{ .value = point, .len = len };
}

const Class = enum {
    alnum,
    alpha,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    xdigit,

    fn matches(class: Class, point: u32) bool {
        if (point > 127) return false;
        const byte: u8 = @intCast(point);
        return switch (class) {
            .alnum => std.ascii.isAlphanumeric(byte),
            .alpha => std.ascii.isAlphabetic(byte),
            .blank => byte == ' ' or byte == '\t',
            .cntrl => std.ascii.isControl(byte),
            .digit => std.ascii.isDigit(byte),
            .graph => std.ascii.isPrint(byte) and byte != ' ',
            .lower => std.ascii.isLower(byte),
            .print => std.ascii.isPrint(byte),
            .punct => std.ascii.isPrint(byte) and !std.ascii.isAlphanumeric(byte) and byte != ' ',
            .space => std.ascii.isWhitespace(byte),
            .upper => std.ascii.isUpper(byte),
            .xdigit => std.ascii.isHex(byte),
        };
    }
};
const classes = std.StaticStringMap(Class).initComptime(.{
    .{ "alnum", .alnum }, .{ "alpha", .alpha }, .{ "blank", .blank }, .{ "cntrl", .cntrl },
    .{ "digit", .digit }, .{ "graph", .graph }, .{ "lower", .lower }, .{ "print", .print },
    .{ "punct", .punct }, .{ "space", .space }, .{ "upper", .upper }, .{ "xdigit", .xdigit },
});

test "shell patterns match scalar characters ranges classes and complete values" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "", "", true },             .{ "*", "", true },                          .{ "a*b*c", "axbybc", true },
        .{ "a*b", "ab-tail", false },
        .{ "?", "日", true },
        .{ "?", "\xff", true },        .{ "[a-c]", "b", true },                     .{ "[!a-c]", "z", true },
        .{ "[!a-c]", "b", false },     .{ "[]-]", "]", true },                      .{ "[-a]", "-", true },
        .{ "[[]", "[", true },         .{ "[unterminated", "[unterminated", true },
        .{ "[[:digit:]]?", "3日", true },
        .{ "[[:alpha:]]", "日", false },
        .{ "a/*", "a/.hidden", true },
    };
    for (cases) |case| try std.testing.expectEqual(case[2], (Pattern{ .bytes = case[0] }).matches(case[1]));
    const quoted: Pattern = .{ .bytes = "*?", .quoted = &.{ true, false } };
    try std.testing.expect(quoted.matches("*日"));
    try std.testing.expect(!quoted.matches("other"));
    try std.testing.expect(!(Pattern{ .bytes = "[" }).hasMeta());
}
