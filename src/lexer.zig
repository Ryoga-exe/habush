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
        '\'' => {
            token.token_type = .quoted_single;
            token.loc.start = self.position + 1;
            self.lexQuotedSingle();
            token.loc.end = self.position - 1;
        },
        '\"' => {
            token.token_type = .quoted_double;
            token.loc.start = self.position + 1;
            self.lexQuotedDouble();
            token.loc.end = self.position - 1;
        },
        '<' => {
            self.readChar();
            switch (self.ch) {
                '<' => {
                    self.readChar();
                    // if (self.ch == '-') {}
                    token.token_type = .redirection_heredocument;
                },
                '&' => {},
                '>' => {},
                else => {
                    token.token_type = .redirection_input;
                },
            }
            token.loc.end = self.position;
        },
        '>' => {
            self.readChar();
            switch (self.ch) {
                '>' => {
                    self.readChar();
                    token.token_type = .redirection_output_append;
                },
                '&' => {},
                '|' => {
                    self.readChar();
                    token.token_type = .redirection_output_force;
                },
                else => {
                    token.token_type = .redirection_output;
                },
            }
            token.loc.end = self.position;
        },
        else => {
            token = self.lexWord();
        },
    }
    return token;
}

fn lexWord(self: *Lexer) Token {
    const start_position = self.position;
    var is_number = true;
    while (true) : (self.readChar()) {
        switch (self.ch) {
            0 => {
                break;
            },
            '\\' => {
                is_number = false;
                self.lexEscapedChar();
            },
            ' ', '\n', '\t', '\r' => {
                break;
            },
            '\"', '\'' => {
                break;
            },
            '<', '>' => {
                break;
            },
            else => {
                if (!std.ascii.isDigit(self.ch)) {
                    is_number = false;
                }
            },
        }
    }
    return Token{
        .token_type = if (is_number) .number else .word,
        .loc = .{
            .start = start_position,
            .end = self.position,
        },
    };
}

fn lexQuotedSingle(self: *Lexer) void {
    self.readChar(); // consume '
    while (true) : (self.readChar()) {
        switch (self.ch) {
            0 => {
                // TODO: Error or Continuation Prompt
            },
            '\'' => {
                break;
            },
            else => {},
        }
    }
    self.readChar(); // consume '
}

fn lexQuotedDouble(self: *Lexer) void {
    self.readChar(); // consume "
    while (true) : (self.readChar()) {
        switch (self.ch) {
            0 => {
                // TODO: Error or Continuation Prompt
            },
            '\\' => {
                self.lexEscapedChar();
            },
            '\"' => {
                break;
            },
            else => {},
        }
    }
    self.readChar(); // consume "
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
        .{
            .input =
            \\echo 'hello world'
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .quoted_single, "hello world" },
                .{ .eof, "" },
            },
        },
        .{
            .input =
            \\echo "hello world"
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .quoted_double, "hello world" },
                .{ .eof, "" },
            },
        },
        .{
            .input =
            \\echo "hello\" world" hello\ world 123
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .quoted_double, "hello\\\" world" },
                .{ .whitespace, " " },
                .{ .word, "hello\\ world" },
                .{ .whitespace, " " },
                .{ .number, "123" },
                .{ .eof, "" },
            },
        },
        .{
            .input =
            \\echo hello 1>hello.txt
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .word, "hello" },
                .{ .whitespace, " " },
                .{ .number, "1" },
                .{ .redirection_output, ">" },
                .{ .word, "hello.txt" },
                .{ .eof, "" },
            },
        },
        .{
            .input =
            \\echo hello >>hello.txt
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .whitespace, " " },
                .{ .word, "hello" },
                .{ .whitespace, " " },
                .{ .redirection_output_append, ">>" },
                .{ .word, "hello.txt" },
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
