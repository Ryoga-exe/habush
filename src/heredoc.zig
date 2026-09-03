//! Here-document delimiter handling.
//!
//! This module performs quote removal only. Expanding a here-document body is
//! a later runtime concern.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodedDelimiter = struct {
    text: []u8,
    quoted: bool,

    pub fn deinit(delimiter: *DecodedDelimiter, allocator: Allocator) void {
        allocator.free(delimiter.text);
        delimiter.* = undefined;
    }
};

/// A body owned by the input layer. The AST borrows both slices.
pub const Collected = struct {
    delimiter: []const u8,
    strip_tabs: bool,
    expand_body: bool,
    body: []const u8,
};

pub fn decodeDelimiter(
    allocator: Allocator,
    raw: []const u8,
) Allocator.Error!DecodedDelimiter {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);

    const State = enum {
        normal,
        single_quote,
        double_quote,
    };
    var state: State = .normal;
    var quoted = false;
    var index: usize = 0;

    while (index < raw.len) {
        const byte = raw[index];
        switch (state) {
            .normal => switch (byte) {
                '\'' => {
                    quoted = true;
                    state = .single_quote;
                    index += 1;
                },
                '"' => {
                    quoted = true;
                    state = .double_quote;
                    index += 1;
                },
                '\\' => {
                    quoted = true;
                    if (index + 1 >= raw.len) {
                        index += 1;
                    } else if (raw[index + 1] == '\n') {
                        index += 2;
                    } else {
                        try decoded.append(allocator, raw[index + 1]);
                        index += 2;
                    }
                },
                else => {
                    try decoded.append(allocator, byte);
                    index += 1;
                },
            },
            .single_quote => {
                if (byte == '\'') {
                    state = .normal;
                } else {
                    try decoded.append(allocator, byte);
                }
                index += 1;
            },
            .double_quote => switch (byte) {
                '"' => {
                    state = .normal;
                    index += 1;
                },
                '\\' => {
                    if (index + 1 >= raw.len) {
                        try decoded.append(allocator, '\\');
                        index += 1;
                    } else {
                        const next = raw[index + 1];
                        switch (next) {
                            '$', '`', '"', '\\' => {
                                try decoded.append(allocator, next);
                                index += 2;
                            },
                            '\n' => index += 2,
                            else => {
                                try decoded.append(allocator, '\\');
                                index += 1;
                            },
                        }
                    }
                },
                else => {
                    try decoded.append(allocator, byte);
                    index += 1;
                },
            },
        }
    }

    return .{
        .text = try decoded.toOwnedSlice(allocator),
        .quoted = quoted,
    };
}

pub fn lineAfterTabStripping(line: []const u8, strip_tabs: bool) []const u8 {
    if (!strip_tabs) return line;

    var index: usize = 0;
    while (index < line.len and line[index] == '\t') index += 1;
    return line[index..];
}

test "decodes here-document delimiters" {
    const allocator = std.testing.allocator;

    var plain = try decodeDelimiter(allocator, "EOF");
    defer plain.deinit(allocator);
    try std.testing.expectEqualStrings("EOF", plain.text);
    try std.testing.expect(!plain.quoted);

    var single_quoted = try decodeDelimiter(allocator, "'E OF'");
    defer single_quoted.deinit(allocator);
    try std.testing.expectEqualStrings("E OF", single_quoted.text);
    try std.testing.expect(single_quoted.quoted);

    var escaped = try decodeDelimiter(allocator, "E\\OF");
    defer escaped.deinit(allocator);
    try std.testing.expectEqualStrings("EOF", escaped.text);
    try std.testing.expect(escaped.quoted);

    var double_quoted = try decodeDelimiter(allocator, "\"E\\$O\\qF\"");
    defer double_quoted.deinit(allocator);
    try std.testing.expectEqualStrings("E$O\\qF", double_quoted.text);
    try std.testing.expect(double_quoted.quoted);
}

test "tab stripping removes tabs but preserves spaces" {
    try std.testing.expectEqualStrings("body", lineAfterTabStripping("\t\tbody", true));
    try std.testing.expectEqualStrings(" body", lineAfterTabStripping("\t body", true));
    try std.testing.expectEqualStrings("\tbody", lineAfterTabStripping("\tbody", false));
}
