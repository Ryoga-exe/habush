const std = @import("std");
const Token = @This();

token_type: TokenType,
loc: Loc,

pub const Loc = struct {
    start: usize,
    end: usize,
};

pub const TokenType = enum {
    invalid,
    word,
    pipe,
    redirection_input,
    redirection_output,
    redirection_output_append,
    redirection_heredocument,
    quoted_double,
    quoted_single,
    semicolon,
    whitespace,
    eof,
};
