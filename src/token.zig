const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @This();

allocator: Allocator,
token_type: TokenType,
literal: ?[]const u8,

pub const TokenType = enum {
    illegal,
    word,
    pipe,
    redirection,
    semicolon,
    eof,
};

pub fn init(allocator: Allocator, token_type: TokenType, literal: ?[]const u8) !Token {
    if (literal) |lit| {
        return Token{
            .allocator = allocator,
            .token_type = token_type,
            .literal = try allocator.dupe(u8, lit),
        };
    } else {
        return Token{
            .allocator = allocator,
            .token_type = token_type,
            .literal = null,
        };
    }
}

pub fn deinit(self: *Token) void {
    if (self.literal) |lit| {
        self.allocator.free(lit);
    }
}
