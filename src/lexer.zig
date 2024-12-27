// TODO: support multibyte charactor
const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("token.zig");

const Lexer = @This();

buffer: []const u8,
position: usize,
read_position: usize,
ch: u8,

pub fn init(buffer: []const u8) Lexer {
    var self = Lexer{
        .buffer = buffer,
        .position = 0,
        .read_position = 0,
        .ch = 0,
    };
    self.readChar();
    return self;
}

pub fn next(self: *Lexer) Token {
    var token = Token{
        .token_type = .eof,
        .loc = .{
            .start = self.position,
            .end = self.buffer.len,
        },
    };
    switch (self.ch) {
        0 => {
            if (self.read_position < self.buffer.len) {
                token.token_type = .invalid;
                token.loc.end = self.position;
                self.readChar();
            }
        },
        ' ', '\n', '\t', '\r' => {
            token.token_type = .whitespace;
            self.skipWhitespace();
            token.loc.end = self.position;
        },
        '\\' => {},
        '\"' => {
            token.token_type = .quoted_double;
            self.lexQuotedDouble();
            token.loc.end = self.position;
        },
        '\'' => {
            token.token_type = .quoted_double;
            self.lexQuotedSingle();
            token.loc.end = self.position;
        },
        '>' => {},
        else => {
            token.token_type = .word;
            self.lexWord();
            token.loc.end = self.position;
        },
    }
    return token;
}

fn lexWord(self: *Lexer) void {
    while (true) : (self.readChar()) {
        switch (self.ch) {
            0 => {
                break;
            },
            '\\' => {
                self.lexEscapedChar();
            },
            ' ', '\n', '\t', '\r' => {
                break;
            },
            '\"', '\'' => {
                break;
            },
            '>' => {},
            '<' => {},
            else => {},
        }
    }
}

fn lexQuotedDouble(self: *Lexer) void {
    _ = self; // autofix
}

fn lexQuotedSingle(self: *Lexer) void {
    _ = self; // autofix
}

fn lexEscapedChar(self: *Lexer) void {
    if (self.peekChar() == 0) {
        // TODO: Error or Continuation Prompt
    } else {
        self.readChar();
    }
}

fn skipWhitespace(self: *Lexer) void {
    while (true) : (self.readChar()) {
        switch (self.ch) {
            ' ', '\n', '\t', '\r' => {
                continue;
            },
            else => {
                break;
            },
        }
    }
}

fn readChar(self: *Lexer) void {
    if (self.read_position < self.buffer.len) {
        self.ch = self.buffer[self.read_position];
        self.position = self.read_position;
        self.read_position += 1;
    } else {
        self.ch = 0;
        self.position = self.buffer.len;
    }
}

fn peekChar(self: Lexer) u8 {
    if (self.read_position < self.buffer.len) {
        return self.buffer[self.read_position];
    } else {
        return 0;
    }
}

test Lexer {
    const ExpectsToken = struct { Token.TokenType, []const u8 };

    const tests = [_]struct {
        input: []const u8,
        expects: []const ExpectsToken,
    }{
        .{
            .input = "echo hello",
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .word, "hello" },
                .{ .eof, "" },
            },
        },
        .{
            .input = "echo  hello \t world",
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, "  " },
                .{ .word, "hello" },
                .{ .whitespace, " \t " },
                .{ .word, "world" },
                .{ .eof, "" },
            },
        },
    };

    for (tests) |t| {
        var lexer = init(t.input);
        for (t.expects) |expected| {
            const token_type, const literal = expected;
            const actual = lexer.next();
            const actual_literal = t.input[actual.loc.start..actual.loc.end];

            try std.testing.expectEqual(token_type, actual.token_type);
            try std.testing.expectEqualSlices(u8, literal, actual_literal);
        }
    }
}
