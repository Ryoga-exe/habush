const std = @import("std");
const Token = @This();

token_type: TokenType,
loc: Loc,

pub const Loc = struct {
    start: usize,
    end: usize,
};

// TODO: remove quoted_*, and add expandable for improve parsing speed
pub const TokenType = enum {
    invalid,
    word,
    number,
    pipe,
    redirection_input,
    redirection_output,
    redirection_output_append,
    redirection_output_force,
    redirection_heredocument,
    quoted_single,
    quoted_double,
    semicolon,
    whitespace,
    eof,
};
