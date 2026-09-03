//! Structural parsing for the contents of a shell word.
//!
//! This layer records quoting and parameter syntax. It deliberately does not
//! perform parameter expansion, quote removal, field splitting, or globbing.

const std = @import("std");

pub const ByteOffset = u32;

pub const Part = struct {
    tag: Tag,
    start: ByteOffset,
    end: ByteOffset,

    pub const Tag = enum {
        literal,
        escaped,
        single_quoted,
        double_quoted,
        double_quoted_escaped,
        parameter,
        braced_parameter,
        double_quoted_parameter,
        double_quoted_braced_parameter,
    };
};

pub const Incomplete = struct {
    tag: Tag,
    opened_at: ByteOffset,

    pub const Tag = enum {
        escape,
        single_quote,
        double_quote,
        parameter_brace,
    };
};

pub const Status = union(enum) {
    running,
    complete,
    incomplete: Incomplete,
};

pub const Iterator = struct {
    source: []const u8,
    source_start: ByteOffset,
    index: usize = 0,
    state: State = .unquoted,
    quote_start: usize = 0,
    double_quote_has_part: bool = false,
    status: Status = .running,

    const State = enum {
        unquoted,
        double_quoted,
    };

    pub fn init(source: []const u8, source_start: ByteOffset) Iterator {
        return .{
            .source = source,
            .source_start = source_start,
        };
    }

    pub fn next(iterator: *Iterator) ?Part {
        if (iterator.status != .running) return null;

        while (true) switch (iterator.state) {
            .unquoted => {
                if (iterator.index == iterator.source.len) {
                    iterator.status = .complete;
                    return null;
                }

                const literal_start = iterator.index;
                while (iterator.index < iterator.source.len) : (iterator.index += 1) {
                    switch (iterator.source[iterator.index]) {
                        '\'', '"', '\\', '$' => break,
                        else => {},
                    }
                }
                if (iterator.index != literal_start) {
                    return iterator.part(.literal, literal_start, iterator.index);
                }

                switch (iterator.source[iterator.index]) {
                    '\'' => return iterator.singleQuoted(),
                    '"' => {
                        iterator.quote_start = iterator.index;
                        iterator.index += 1;
                        iterator.state = .double_quoted;
                        iterator.double_quote_has_part = false;
                    },
                    '\\' => {
                        const escape_start = iterator.index;
                        iterator.index += 1;
                        if (iterator.index == iterator.source.len) {
                            iterator.setIncomplete(.escape, escape_start);
                            return null;
                        }
                        if (iterator.source[iterator.index] == '\n') {
                            iterator.index += 1;
                            continue;
                        }
                        const escaped_start = iterator.index;
                        iterator.index += 1;
                        return iterator.part(.escaped, escaped_start, iterator.index);
                    },
                    '$' => {
                        if (iterator.parameter(.parameter, .braced_parameter)) |parameter_part| {
                            return parameter_part;
                        }
                        if (iterator.status != .running) return null;

                        const dollar = iterator.index;
                        iterator.index += 1;
                        return iterator.part(.literal, dollar, iterator.index);
                    },
                    else => unreachable,
                }
            },
            .double_quoted => {
                if (iterator.index == iterator.source.len) {
                    iterator.setIncomplete(.double_quote, iterator.quote_start);
                    return null;
                }

                if (iterator.source[iterator.index] == '"') {
                    const close_quote = iterator.index;
                    iterator.index += 1;
                    iterator.state = .unquoted;
                    if (!iterator.double_quote_has_part) {
                        iterator.double_quote_has_part = true;
                        return iterator.part(.double_quoted, close_quote, close_quote);
                    }
                    continue;
                }

                const literal_start = iterator.index;
                while (iterator.index < iterator.source.len) {
                    const byte = iterator.source[iterator.index];
                    if (byte == '"' or byte == '$') break;
                    if (byte == '\\') {
                        if (iterator.index + 1 == iterator.source.len) break;
                        switch (iterator.source[iterator.index + 1]) {
                            '$', '`', '"', '\\', '\n' => break,
                            else => {},
                        }
                    }
                    iterator.index += 1;
                }
                if (iterator.index != literal_start) {
                    iterator.double_quote_has_part = true;
                    return iterator.part(.double_quoted, literal_start, iterator.index);
                }

                switch (iterator.source[iterator.index]) {
                    '$' => {
                        if (iterator.parameter(
                            .double_quoted_parameter,
                            .double_quoted_braced_parameter,
                        )) |parameter_part| {
                            iterator.double_quote_has_part = true;
                            return parameter_part;
                        }
                        if (iterator.status != .running) return null;

                        const dollar = iterator.index;
                        iterator.index += 1;
                        iterator.double_quote_has_part = true;
                        return iterator.part(.double_quoted, dollar, iterator.index);
                    },
                    '\\' => {
                        const escape_start = iterator.index;
                        iterator.index += 1;
                        if (iterator.index == iterator.source.len) {
                            iterator.setIncomplete(.escape, escape_start);
                            return null;
                        }
                        if (iterator.source[iterator.index] == '\n') {
                            iterator.index += 1;
                            continue;
                        }
                        const escaped_start = iterator.index;
                        iterator.index += 1;
                        iterator.double_quote_has_part = true;
                        return iterator.part(
                            .double_quoted_escaped,
                            escaped_start,
                            iterator.index,
                        );
                    },
                    else => unreachable,
                }
            },
        };
    }

    fn singleQuoted(iterator: *Iterator) ?Part {
        const quote_start = iterator.index;
        iterator.index += 1;
        const content_start = iterator.index;
        while (iterator.index < iterator.source.len and
            iterator.source[iterator.index] != '\'')
        {
            iterator.index += 1;
        }
        if (iterator.index == iterator.source.len) {
            iterator.setIncomplete(.single_quote, quote_start);
            return null;
        }

        const content_end = iterator.index;
        iterator.index += 1;
        return iterator.part(.single_quoted, content_start, content_end);
    }

    fn parameter(
        iterator: *Iterator,
        parameter_tag: Part.Tag,
        braced_parameter_tag: Part.Tag,
    ) ?Part {
        std.debug.assert(iterator.source[iterator.index] == '$');
        const dollar = iterator.index;
        if (iterator.index + 1 == iterator.source.len) return null;

        if (iterator.source[iterator.index + 1] == '{') {
            const content_start = iterator.index + 2;
            iterator.index = content_start;
            var depth: u32 = 1;
            while (iterator.index < iterator.source.len) {
                switch (iterator.source[iterator.index]) {
                    '$' => {
                        if (iterator.index + 1 < iterator.source.len and
                            iterator.source[iterator.index + 1] == '{')
                        {
                            depth += 1;
                            iterator.index += 2;
                        } else {
                            iterator.index += 1;
                        }
                    },
                    '}' => {
                        depth -= 1;
                        if (depth == 0) break;
                        iterator.index += 1;
                    },
                    '\\' => {
                        iterator.index += 1;
                        if (iterator.index < iterator.source.len) iterator.index += 1;
                    },
                    else => iterator.index += 1,
                }
            }
            if (iterator.index == iterator.source.len) {
                iterator.setIncomplete(.parameter_brace, dollar);
                return null;
            }

            const content_end = iterator.index;
            iterator.index += 1;
            return iterator.part(braced_parameter_tag, content_start, content_end);
        }

        if (!isNameStart(iterator.source[iterator.index + 1])) return null;
        const name_start = iterator.index + 1;
        iterator.index = name_start + 1;
        while (iterator.index < iterator.source.len and
            isNameContinue(iterator.source[iterator.index]))
        {
            iterator.index += 1;
        }
        return iterator.part(parameter_tag, name_start, iterator.index);
    }

    fn part(iterator: *const Iterator, tag: Part.Tag, start: usize, end: usize) Part {
        return .{
            .tag = tag,
            .start = iterator.absoluteOffset(start),
            .end = iterator.absoluteOffset(end),
        };
    }

    fn setIncomplete(iterator: *Iterator, tag: Incomplete.Tag, opened_at: usize) void {
        iterator.status = .{ .incomplete = .{
            .tag = tag,
            .opened_at = iterator.absoluteOffset(opened_at),
        } };
    }

    fn absoluteOffset(iterator: *const Iterator, relative: usize) ByteOffset {
        return iterator.source_start + @as(ByteOffset, @intCast(relative));
    }
};

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}

test "iterates mixed word parts" {
    const source = "pre'raw value'\"hello $name ${other}\"foo\\ bar";
    var iterator = Iterator.init(source, 0);

    const expected = [_]struct { Part.Tag, []const u8 }{
        .{ .literal, "pre" },
        .{ .single_quoted, "raw value" },
        .{ .double_quoted, "hello " },
        .{ .double_quoted_parameter, "name" },
        .{ .double_quoted, " " },
        .{ .double_quoted_braced_parameter, "other" },
        .{ .literal, "foo" },
        .{ .escaped, " " },
        .{ .literal, "bar" },
    };
    for (expected) |item| {
        const part = iterator.next().?;
        try std.testing.expectEqual(item[0], part.tag);
        try std.testing.expectEqualStrings(item[1], source[part.start..part.end]);
    }
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.status == .complete);
}

test "preserves empty quoted parts" {
    const source = "''\"\"";
    var iterator = Iterator.init(source, 4);

    const single = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.single_quoted, single.tag);
    try std.testing.expectEqual(@as(ByteOffset, 5), single.start);
    try std.testing.expectEqual(single.start, single.end);

    const double = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.double_quoted, double.tag);
    try std.testing.expectEqual(@as(ByteOffset, 7), double.start);
    try std.testing.expectEqual(double.start, double.end);
    try std.testing.expect(iterator.next() == null);
}

test "double quote backslash follows shell rules" {
    const source = "\"a\\$b\\q\"";
    var iterator = Iterator.init(source, 0);

    try std.testing.expectEqual(Part.Tag.double_quoted, iterator.next().?.tag);
    const escaped = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.double_quoted_escaped, escaped.tag);
    try std.testing.expectEqualStrings("$", source[escaped.start..escaped.end]);
    const literal = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.double_quoted, literal.tag);
    try std.testing.expectEqualStrings("b\\q", source[literal.start..literal.end]);
    try std.testing.expect(iterator.next() == null);
}

test "reports an unclosed parameter brace" {
    var iterator = Iterator.init("prefix${name", 10);
    try std.testing.expectEqualStrings("prefix", blk: {
        const part = iterator.next().?;
        break :blk iterator.source[part.start - iterator.source_start .. part.end - iterator.source_start];
    });
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.status == .incomplete);
    try std.testing.expectEqual(Incomplete.Tag.parameter_brace, iterator.status.incomplete.tag);
    try std.testing.expectEqual(@as(ByteOffset, 16), iterator.status.incomplete.opened_at);
}
