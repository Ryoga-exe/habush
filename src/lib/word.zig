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

pub const ParameterExpansion = struct {
    parameter: []const u8,
    operator: ?Operator = null,
    word: []const u8 = "",

    pub const Operator = enum {
        default_if_unset,
        default_if_unset_or_null,
        assign_if_unset,
        assign_if_unset_or_null,
        error_if_unset,
        error_if_unset_or_null,
        alternative_if_set,
        alternative_if_set_and_not_null,
    };

    pub fn parse(source: []const u8) ?ParameterExpansion {
        const parameter_end = parameterEnd(source) orelse return null;
        if (parameter_end == source.len) {
            return .{ .parameter = source };
        }

        const operator_source = source[parameter_end..];
        const operator: Operator, const operator_len: usize = if (std.mem.startsWith(
            u8,
            operator_source,
            ":-",
        ))
            .{ .default_if_unset_or_null, 2 }
        else if (std.mem.startsWith(u8, operator_source, ":="))
            .{ .assign_if_unset_or_null, 2 }
        else if (std.mem.startsWith(u8, operator_source, ":?"))
            .{ .error_if_unset_or_null, 2 }
        else if (std.mem.startsWith(u8, operator_source, ":+"))
            .{ .alternative_if_set_and_not_null, 2 }
        else switch (operator_source[0]) {
            '-' => .{ .default_if_unset, 1 },
            '=' => .{ .assign_if_unset, 1 },
            '?' => .{ .error_if_unset, 1 },
            '+' => .{ .alternative_if_set, 1 },
            else => return null,
        };
        return .{
            .parameter = source[0..parameter_end],
            .operator = operator,
            .word = source[parameter_end + operator_len ..],
        };
    }

    fn parameterEnd(source: []const u8) ?usize {
        if (source.len == 0) return null;
        if (isSpecialParameter(source[0])) return 1;
        if (std.ascii.isDigit(source[0])) {
            var end: usize = 1;
            while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
            return end;
        }
        if (!isNameStart(source[0])) return null;
        var end: usize = 1;
        while (end < source.len and isNameContinue(source[end])) : (end += 1) {}
        return end;
    }
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
    implicit_double_quote: bool = false,
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

    pub fn initExpansionWord(
        source: []const u8,
        source_start: ByteOffset,
        double_quoted: bool,
    ) Iterator {
        var iterator = init(source, source_start);
        if (double_quoted) {
            iterator.state = .double_quoted;
            iterator.implicit_double_quote = true;
        }
        return iterator;
    }

    pub fn next(iterator: *Iterator) ?Part {
        if (iterator.status != .running) return null;

        while (true) switch (iterator.state) {
            .unquoted => {
                if (iterator.index == iterator.source.len) {
                    if (iterator.implicit_double_quote) {
                        iterator.setIncomplete(.double_quote, iterator.quote_start);
                        return null;
                    }
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
                    if (iterator.implicit_double_quote) {
                        iterator.status = .complete;
                        return null;
                    }
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

        const first = iterator.source[iterator.index + 1];
        if (isSpecialParameter(first) or std.ascii.isDigit(first)) {
            iterator.index += 2;
            return iterator.part(parameter_tag, iterator.index - 1, iterator.index);
        }
        if (!isNameStart(first)) return null;
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

pub fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

pub fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}

pub fn isSpecialParameter(byte: u8) bool {
    return switch (byte) {
        '@', '*', '#', '?', '-', '$', '!' => true,
        else => false,
    };
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

test "iterates positional and special parameters" {
    const source = "$1x \"$@:$?:$#:$10:${10}:$*:$-:$$:$!\"";
    var iterator = Iterator.init(source, 0);

    const expected = [_]struct { Part.Tag, []const u8 }{
        .{ .parameter, "1" },
        .{ .literal, "x " },
        .{ .double_quoted_parameter, "@" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "?" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "#" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "1" },
        .{ .double_quoted, "0:" },
        .{ .double_quoted_braced_parameter, "10" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "*" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "-" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "$" },
        .{ .double_quoted, ":" },
        .{ .double_quoted_parameter, "!" },
    };
    for (expected) |item| {
        const part = iterator.next().?;
        try std.testing.expectEqual(item[0], part.tag);
        try std.testing.expectEqualStrings(item[1], source[part.start..part.end]);
    }
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.status == .complete);
}

test "parses braced parameter expansion operators" {
    const expected = [_]struct { []const u8, ParameterExpansion.Operator }{
        .{ "name-word", .default_if_unset },
        .{ "name:-word", .default_if_unset_or_null },
        .{ "name=word", .assign_if_unset },
        .{ "name:=word", .assign_if_unset_or_null },
        .{ "name?word", .error_if_unset },
        .{ "name:?word", .error_if_unset_or_null },
        .{ "name+word", .alternative_if_set },
        .{ "name:+word", .alternative_if_set_and_not_null },
    };
    for (expected) |item| {
        const expansion = ParameterExpansion.parse(item[0]).?;
        try std.testing.expectEqualStrings("name", expansion.parameter);
        try std.testing.expectEqual(item[1], expansion.operator.?);
        try std.testing.expectEqualStrings("word", expansion.word);
    }

    const plain = ParameterExpansion.parse("10").?;
    try std.testing.expectEqualStrings("10", plain.parameter);
    try std.testing.expectEqual(null, plain.operator);
    try std.testing.expectEqualStrings("", plain.word);

    try std.testing.expect(ParameterExpansion.parse("") == null);
    try std.testing.expect(ParameterExpansion.parse("name:word") == null);
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

test "expansion word can inherit a surrounding double quote" {
    const source = "'literal' a\\qb $name";
    var iterator = Iterator.initExpansionWord(source, 0, true);

    const literal = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.double_quoted, literal.tag);
    try std.testing.expectEqualStrings("'literal' a\\qb ", source[literal.start..literal.end]);
    const parameter = iterator.next().?;
    try std.testing.expectEqual(Part.Tag.double_quoted_parameter, parameter.tag);
    try std.testing.expectEqualStrings("name", source[parameter.start..parameter.end]);
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.status == .complete);
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
