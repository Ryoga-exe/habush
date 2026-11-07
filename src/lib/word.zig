//! Structural parsing for the contents of a shell word.
//!
//! This layer records quoting and parameter syntax. It deliberately does not
//! perform parameter expansion, quote removal, field splitting, or globbing.

const std = @import("std");
const heredoc = @import("heredoc.zig");

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
        command_substitution,
        double_quoted_command_substitution,
        arithmetic_substitution,
    };
};

pub const ParameterExpansion = struct {
    parameter: []const u8,
    operator: ?Operator = null,
    word: []const u8 = "",

    pub const Operator = enum {
        length,
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
        if (source.len > 1 and source[0] == '#') {
            if (parameterEnd(source[1..])) |end| {
                if (end == source.len - 1) return .{
                    .parameter = source[1..],
                    .operator = .length,
                };
            }
        }
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
        command_substitution,
    };
};

pub const Status = union(enum) {
    running,
    complete,
    incomplete: Incomplete,
};

/// Returns the closing parenthesis of a `$(...)` beginning at `start`.
/// Quotes, comments and nested substitutions belong to the inner command,
/// independently of the quoting around the outer shell word.
pub fn commandSubstitutionEnd(source: []const u8, start: usize) ?usize {
    return substitutionEnd(source, start, 0);
}

fn substitutionEnd(source: []const u8, start: usize, nesting: usize) ?usize {
    if (nesting >= 128) return null;
    var index = start + 2;
    var parentheses: usize = 1;
    var word_start = true;
    var document_header: ?usize = null;
    while (index < source.len) {
        switch (source[index]) {
            '\n' => if (document_header) |header| {
                index = skipHereDocuments(source, header, index, index + 1) orelse return null;
                document_header = null;
                word_start = true;
                continue;
            },
            '<' => if (isHereDocument(source, index)) {
                const delimiter = scanHereDocument(source, index) orelse return null;
                if (document_header == null) document_header = index;
                index = delimiter.end;
                word_start = false;
                continue;
            },
            '\\' => {
                if (index + 1 == source.len) return null;
                if (source[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                if (source[index + 1] == '\r' and index + 2 < source.len and source[index + 2] == '\n') {
                    index += 3;
                    continue;
                }
                index += 2;
                word_start = false;
                continue;
            },
            '\'', '"' => |quote| {
                index = (quotedEnd(source, index, quote, nesting + 1) orelse return null) + 1;
                word_start = false;
                continue;
            },
            '$' => if (index + 1 < source.len) {
                if (source[index + 1] == '(') {
                    index = (substitutionEnd(source, index, nesting + 1) orelse return null) + 1;
                    word_start = false;
                    continue;
                }
                if (source[index + 1] == '{') {
                    index = (parameterBraceEnd(source, index, nesting + 1) orelse return null) + 1;
                    word_start = false;
                    continue;
                }
            },
            '(' => parentheses += 1,
            ')' => {
                parentheses -= 1;
                if (parentheses == 0) return index;
            },
            '#' => if (word_start) {
                index = std.mem.indexOfScalarPos(u8, source, index, '\n') orelse return null;
                word_start = true;
                continue;
            },
            else => {},
        }
        word_start = std.mem.indexOfScalar(u8, " \t\r\n;|&()<>", source[index]) != null;
        index += 1;
    }
    return null;
}

const HereDocumentDelimiter = struct {
    raw: []const u8,
    end: usize,
    strip_tabs: bool,
    quoted: bool,
};

fn isHereDocument(source: []const u8, index: usize) bool {
    return index + 1 < source.len and source[index] == '<' and source[index + 1] == '<' and
        (index == 0 or source[index - 1] != '<') and
        (index + 2 == source.len or source[index + 2] != '<');
}

fn scanHereDocument(source: []const u8, start: usize) ?HereDocumentDelimiter {
    var index = start + 2;
    const strip_tabs = index < source.len and source[index] == '-';
    if (strip_tabs) index += 1;
    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) index += 1;
    const begin = index;
    var quoted = false;
    while (index < source.len) {
        if (source[index] == '\'' or source[index] == '"') {
            quoted = true;
            index = (quotedEnd(source, index, source[index], 0) orelse return null) + 1;
        } else if (source[index] == '\\') {
            quoted = true;
            if (index + 1 == source.len) return null;
            index += 2;
        } else if (std.mem.indexOfScalar(u8, " \t\r\n;|&()<>", source[index]) != null) break else index += 1;
    }
    if (begin == index) return null;
    return .{ .raw = source[begin..index], .end = index, .strip_tabs = strip_tabs, .quoted = quoted };
}

fn skipHereDocuments(source: []const u8, header: usize, header_end: usize, body_start: usize) ?usize {
    var index = header;
    var body = body_start;
    var word_start = true;
    while (index < header_end) {
        if (isHereDocument(source, index)) {
            const delimiter = scanHereDocument(source, index) orelse return null;
            index = delimiter.end;
            word_start = false;
            var candidate_start = body;
            while (true) {
                if (body == source.len) return null;
                const end = std.mem.indexOfScalarPos(u8, source, body, '\n') orelse source.len;
                var line = source[body..if (end > body and source[end - 1] == '\r') end - 1 else end];
                if (delimiter.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                body = @min(end + 1, source.len);
                if (!delimiter.quoted and heredoc.hasLineContinuation(line)) continue;
                if (delimiterMatches(delimiter.raw, source[candidate_start..body], delimiter.strip_tabs, !delimiter.quoted)) break;
                candidate_start = body;
            }
        } else if (source[index] == '\'' or source[index] == '"') {
            index = (quotedEnd(source, index, source[index], 0) orelse return null) + 1;
            word_start = false;
        } else if (source[index] == '\\') {
            index += @min(@as(usize, 2), source.len - index);
            word_start = false;
        } else if (source[index] == '$' and index + 1 < source.len and source[index + 1] == '(') {
            index = (substitutionEnd(source, index, 0) orelse return null) + 1;
            word_start = false;
        } else if (source[index] == '$' and index + 1 < source.len and source[index + 1] == '{') {
            index = (parameterBraceEnd(source, index, 0) orelse return null) + 1;
            word_start = false;
        } else if (source[index] == '#' and word_start) break else {
            word_start = std.mem.indexOfScalar(u8, " \t\r\n;|&()<>", source[index]) != null;
            index += 1;
        }
    }
    return body;
}

const LogicalBody = struct {
    source: []const u8,
    strip_tabs: bool,
    expand: bool,
    cursor: usize = 0,
    end: usize = 0,
    after: usize = 0,

    fn next(self: *LogicalBody) ?u8 {
        while (self.cursor == self.end) {
            if (self.after == self.source.len) return null;
            const begin = self.after;
            const end = std.mem.indexOfScalarPos(u8, self.source, begin, '\n') orelse self.source.len;
            self.after = @min(end + 1, self.source.len);
            var line = self.source[begin..if (end > begin and self.source[end - 1] == '\r') end - 1 else end];
            if (self.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
            if (self.expand and heredoc.hasLineContinuation(line)) line = line[0 .. line.len - 1];
            self.cursor = @intFromPtr(line.ptr) - @intFromPtr(self.source.ptr);
            self.end = self.cursor + line.len;
        }
        defer self.cursor += 1;
        return self.source[self.cursor];
    }
};

fn delimiterMatches(raw: []const u8, physical: []const u8, strip_tabs: bool, expand: bool) bool {
    var body: LogicalBody = .{ .source = physical, .strip_tabs = strip_tabs, .expand = expand };
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < raw.len) {
        var byte = raw[index];
        if (quote) |active| {
            if (byte == active) {
                quote = null;
                index += 1;
                continue;
            }
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and quote != '\'' and index + 1 < raw.len) {
            const next = raw[index + 1];
            if (quote == null or std.mem.indexOfScalar(u8, "$`\"\\\n", next) != null) {
                index += 1;
                byte = next;
                if (byte == '\n') {
                    index += 1;
                    continue;
                }
            }
        }
        if ((body.next() orelse return false) != byte) return false;
        index += 1;
    }
    return body.next() == null;
}

fn quotedEnd(source: []const u8, start: usize, quote: u8, nesting: usize) ?usize {
    var index = start + 1;
    while (index < source.len) {
        if (source[index] == quote) return index;
        if (quote == '"') {
            if (source[index] == '\\' and index + 1 < source.len) {
                index += 2;
                continue;
            }
            if (source[index] == '$' and index + 1 < source.len and source[index + 1] == '(') {
                index = (substitutionEnd(source, index, nesting + 1) orelse return null) + 1;
                continue;
            }
            if (source[index] == '$' and index + 1 < source.len and source[index + 1] == '{') {
                index = (parameterBraceEnd(source, index, nesting + 1) orelse return null) + 1;
                continue;
            }
        }
        index += 1;
    }
    return null;
}

fn parameterBraceEnd(source: []const u8, start: usize, nesting: usize) ?usize {
    if (nesting >= 128) return null;
    var index = start + 2;
    while (index < source.len) {
        switch (source[index]) {
            '}' => return index,
            '\\' => index += @min(@as(usize, 2), source.len - index),
            '\'', '"' => |quote| index = (quotedEnd(source, index, quote, nesting + 1) orelse return null) + 1,
            '$' => {
                if (index + 1 < source.len and source[index + 1] == '(') {
                    index = (substitutionEnd(source, index, nesting + 1) orelse return null) + 1;
                } else if (index + 1 < source.len and source[index + 1] == '{') {
                    index = (parameterBraceEnd(source, index, nesting + 1) orelse return null) + 1;
                } else index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

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

        if (iterator.source[iterator.index + 1] == '(') {
            const end = commandSubstitutionEnd(iterator.source, iterator.index) orelse {
                iterator.setIncomplete(.command_substitution, dollar);
                return null;
            };
            const content_start = iterator.index + 2;
            const tag: Part.Tag = if (content_start < iterator.source.len and iterator.source[content_start] == '(')
                .arithmetic_substitution
            else if (parameter_tag == .double_quoted_parameter)
                .double_quoted_command_substitution
            else
                .command_substitution;
            iterator.index = end + 1;
            return iterator.part(tag, content_start, end);
        }

        if (iterator.source[iterator.index + 1] == '{') {
            const content_start = iterator.index + 2;
            iterator.index = content_start;
            var depth: u32 = 1;
            while (iterator.index < iterator.source.len) {
                switch (iterator.source[iterator.index]) {
                    '$' => {
                        if (iterator.index + 1 < iterator.source.len and iterator.source[iterator.index + 1] == '(') {
                            iterator.index = (commandSubstitutionEnd(iterator.source, iterator.index) orelse {
                                iterator.setIncomplete(.command_substitution, iterator.index);
                                return null;
                            }) + 1;
                            continue;
                        }
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

    const length = ParameterExpansion.parse("#name").?;
    try std.testing.expectEqualStrings("name", length.parameter);
    try std.testing.expectEqual(ParameterExpansion.Operator.length, length.operator.?);
    try std.testing.expectEqual(null, ParameterExpansion.parse("#").?.operator);

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
