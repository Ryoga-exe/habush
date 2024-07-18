const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("token.zig");

const Lexer = @This();

input: []const u8,
position: usize,
read_position: usize,
ch: u8,

pub fn init(input: []const u8) Lexer {
    var self = Lexer{
        .input = input,
        .position = 0,
        .read_position = 0,
        .ch = 0,
    };
    self.readChar();
    return self;
}

pub fn nextToken(self: *Lexer, allocator: Allocator) !Token {
    var token: ?Token = null;

    self.skipWhitespace();

    switch (self.ch) {
        0 => token = try Token.init(allocator, .eof, null),
        else => token = try self.lexWord(allocator),
    }

    self.readChar();

    return token orelse try Token.init(allocator, .illegal, null);
}

fn lexWord(self: *Lexer, allocator: Allocator) !Token {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    while (self.ch != 0 and !std.ascii.isWhitespace(self.ch)) : (self.readChar()) {
        switch (self.ch) {
            '\\' => {
                try buffer.append(self.lexEscapedChar());
            },
            '\'' => try self.lexSingleQuote(&buffer),
            '\"' => try self.lexDoubleQuote(&buffer),
            0 => {},
            else => {
                try buffer.append(self.ch);
            },
        }
    }

    return Token.init(allocator, .word, buffer.items);
}

fn lexEscapedChar(self: *Lexer) u8 {
    if (self.peekChar() == 0) {
        // TODO: Error or Continuation Prompt
        return 0;
    } else {
        // TODO: \n, \t, ...
        self.readChar();
        return self.ch;
    }
}

fn lexSingleQuote(self: *Lexer, buffer: *std.ArrayList(u8)) !void {
    self.readChar(); // consume '
    while (self.ch != 0 and self.ch != '\'') : (self.readChar()) {
        switch (self.ch) {
            '\\' => {
                try buffer.append(self.lexEscapedChar());
            },
            0 => {
                // TODO: Error or Continuation Prompt
            },
            else => {
                try buffer.append(self.ch);
            },
        }
    }
    // self.ch == '
}

fn lexDoubleQuote(self: *Lexer, buffer: *std.ArrayList(u8)) !void {
    self.readChar(); // consume "
    while (self.ch != 0 and self.ch != '\"') : (self.readChar()) {
        switch (self.ch) {
            '\\' => {
                try buffer.append(self.lexEscapedChar());
            },
            0 => {
                // TODO: Error or Continuation Prompt
            },
            else => {
                try buffer.append(self.ch);
            },
        }
    }
    // self.ch == "
}

fn readChar(self: *Lexer) void {
    if (self.read_position < self.input.len) {
        self.ch = self.input[self.read_position];
    } else {
        self.ch = 0;
    }
    self.position = self.read_position;
    self.read_position += 1;
}

fn peekChar(self: Lexer) u8 {
    if (self.read_position < self.input.len) {
        return self.input[self.read_position];
    } else {
        return 0;
    }
}

fn skipWhitespace(self: *Lexer) void {
    while (std.ascii.isWhitespace(self.ch)) {
        self.readChar();
    }
}

test Lexer {
    const ExpectsToken = struct { Token.TokenType, ?[]const u8 };

    const allocator = std.testing.allocator;
    const tests = [_]struct { input: []const u8, expects: []const ExpectsToken }{
        .{
            .input = "echo hello",
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello" },
                .{ .eof, null },
            },
        },
        .{
            .input = "echo hello world",
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello" },
                .{ .word, "world" },
                .{ .eof, null },
            },
        },
        .{
            .input =
            \\ echo "hello world"
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello world" },
                .{ .eof, null },
            },
        },
        .{
            .input =
            \\ echo 'hello world'
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello world" },
                .{ .eof, null },
            },
        },
        .{
            .input =
            \\ echo "he""llo" 'wor''ld' "this is \" and "'\' test!' escaped\ char\ is\ working!
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello" },
                .{ .word, "world" },
                .{ .word, "this is \" and ' test!" },
                .{ .word, "escaped char is working!" },
                .{ .eof, null },
            },
        },
        .{
            .input =
            \\ echo 'hello "world"' this\ line has    extra   \"\"    \'\' "spaces  "      
            ,
            .expects = &[_]ExpectsToken{
                .{ .word, "echo" },
                .{ .word, "hello \"world\"" },
                .{ .word, "this line" },
                .{ .word, "has" },
                .{ .word, "extra" },
                .{ .word, "\"\"" },
                .{ .word, "\'\'" },
                .{ .word, "spaces  " },
                .{ .eof, null },
            },
        },
    };

    for (tests) |t| {
        var lexer = init(t.input);
        for (t.expects) |expected| {
            const token_type, const literal = expected;

            var actual = try lexer.nextToken(allocator);
            defer actual.deinit();

            try std.testing.expectEqual(token_type, actual.token_type);
            try std.testing.expectEqualSlices(u8, literal orelse "EOF", actual.literal orelse "EOF");
        }
    }
}
