//! Tokenizer for habush source.
//! Based on  https://codeberg.org/ziglang/zig/src/branch/master/lib/std/zig/tokenizer.zig

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "if", .keyword_if },
        .{ "then", .keyword_then },
        .{ "elif", .keyword_elif },
        .{ "else", .keyword_else },
        .{ "fi", .keyword_fi },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        invalid,
        eof,
        word,
        digits,

        keyword_if,
        keyword_then,
        keyword_elif,
        keyword_else,
        keyword_fi,

        unterminated_single_quote,
        unterminated_double_quote,
        unterminated_escape,

        newline,

        semicolon,
        semicolon_semicolon,
        semicolon_ampersand,
        semicolon_semicolon_ampersand,

        ampersand,
        ampersand_ampersand,
        ampersand_gt,
        ampersand_gt_gt,

        pipe,
        pipe_pipe,
        pipe_ampersand,

        l_paren,
        r_paren,

        lt,
        gt,
        lt_lt,
        lt_lt_minus,
        lt_lt_lt,
        gt_gt,
        lt_ampersand,
        gt_ampersand,
        lt_gt,
        gt_pipe,
    };

    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid,
            .eof,
            .word,
            .digits,
            .unterminated_single_quote,
            .unterminated_double_quote,
            .unterminated_escape,
            .newline,
            => null,

            .keyword_if => "if",
            .keyword_then => "then",
            .keyword_elif => "elif",
            .keyword_else => "else",
            .keyword_fi => "fi",

            .semicolon => ";",
            .semicolon_semicolon => ";;",
            .semicolon_ampersand => ";&",
            .semicolon_semicolon_ampersand => ";;&",
            .ampersand => "&",
            .ampersand_ampersand => "&&",
            .ampersand_gt => "&>",
            .ampersand_gt_gt => "&>>",
            .pipe => "|",
            .pipe_pipe => "||",
            .pipe_ampersand => "|&",
            .l_paren => "(",
            .r_paren => ")",
            .lt => "<",
            .gt => ">",
            .lt_lt => "<<",
            .lt_lt_minus => "<<-",
            .lt_lt_lt => "<<<",
            .gt_gt => ">>",
            .lt_ampersand => "<&",
            .gt_ampersand => ">&",
            .lt_gt => "<>",
            .gt_pipe => ">|",
        };
    }

    pub fn symbol(tag: Tag) []const u8 {
        return lexeme(tag) orelse switch (tag) {
            .invalid => "invalid token",
            .eof => "EOF",
            .word => "a word",
            .digits => "a digits literal",
            .unterminated_single_quote => "UNTERMINATED (')",
            .unterminated_double_quote => "UNTERMINATED (\")",
            .unterminated_escape => "UNTERMINATED (\\)",
            .newline => "newline",
            else => unreachable,
        };
    }
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    /// For debugging purposes.
    pub fn dump(self: *Tokenizer, token: *const Token) void {
        std.debug.print("{s} \"{s}\"\n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end] });
    }

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present.
        return .{
            .buffer = buffer,
            .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
        };
    }

    const State = enum {
        start,
        comment,
        word,
        word_escape,
        single_quote,
        double_quote,
        double_quote_escape,
        semicolon,
        semicolon_semicolon,
        ampersand,
        ampersand_gt,
        pipe,
        lt,
        lt_lt,
        gt,
        invalid,
    };

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        var quote_start: usize = undefined;
        var escape_start: usize = undefined;
        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    }
                    return .{
                        .tag = .eof,
                        .loc = .{
                            .start = self.index,
                            .end = self.index,
                        },
                    };
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '\n' => {
                    result.tag = .newline;
                    self.index += 1;
                },
                '\r' => {
                    if (self.buffer[self.index + 1] == '\n') {
                        result.tag = .newline;
                        self.index += 2;
                    } else {
                        result.tag = .word;
                        continue :state .word;
                    }
                },
                '#' => continue :state .comment,
                ';' => continue :state .semicolon,
                '&' => continue :state .ampersand,
                '|' => continue :state .pipe,
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '<' => continue :state .lt,
                '>' => continue :state .gt,
                '0'...'9' => {
                    result.tag = .digits;
                    continue :state .word;
                },
                else => {
                    result.tag = .word;
                    continue :state .word;
                },
            },
            .comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            result.loc.start = self.index;
                            continue :state .invalid;
                        }
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    },
                    '\n' => {
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '\r' => {
                        if (self.buffer[self.index + 1] == '\n') {
                            result.loc.start = self.index;
                            continue :state .start;
                        }
                        continue :state .comment;
                    },
                    else => continue :state .comment,
                }
            },
            .word => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        result.loc.start = self.index;
                        continue :state .invalid;
                    }
                },
                ' ', '\t', '\n', ';', '&', '|', '(', ')', '<', '>' => {},
                '\r' => {
                    if (self.buffer[self.index + 1] != '\n') {
                        result.tag = .word;
                        self.index += 1;
                        continue :state .word;
                    }
                },
                '0'...'9' => {
                    self.index += 1;
                    continue :state .word;
                },
                '\'' => {
                    result.tag = .word;
                    quote_start = self.index;
                    self.index += 1;
                    continue :state .single_quote;
                },
                '"' => {
                    result.tag = .word;
                    quote_start = self.index;
                    self.index += 1;
                    continue :state .double_quote;
                },
                '\\' => {
                    escape_start = self.index;
                    self.index += 1;
                    continue :state .word_escape;
                },
                else => {
                    result.tag = .word;
                    self.index += 1;
                    continue :state .word;
                },
            },
            .word_escape => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        result.loc.start = self.index;
                        continue :state .invalid;
                    }
                    result.tag = .unterminated_escape;
                    result.loc.start = escape_start;
                },
                '\n' => {
                    self.index += 1;
                    if (self.index == self.buffer.len) {
                        result.tag = .unterminated_escape;
                        result.loc.start = escape_start;
                    } else {
                        continue :state .word;
                    }
                },
                '\r' => {
                    if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        if (self.index == self.buffer.len) {
                            result.tag = .unterminated_escape;
                            result.loc.start = escape_start;
                        } else {
                            continue :state .word;
                        }
                    } else {
                        result.tag = .word;
                        self.index += 1;
                        continue :state .word;
                    }
                },
                else => {
                    result.tag = .word;
                    self.index += 1;
                    continue :state .word;
                },
            },
            .single_quote => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        result.loc.start = self.index;
                        continue :state .invalid;
                    }
                    result.tag = .unterminated_single_quote;
                    result.loc.start = quote_start;
                },
                '\'' => {
                    self.index += 1;
                    continue :state .word;
                },
                else => {
                    self.index += 1;
                    continue :state .single_quote;
                },
            },
            .double_quote => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        result.loc.start = self.index;
                        continue :state .invalid;
                    }
                    result.tag = .unterminated_double_quote;
                    result.loc.start = quote_start;
                },
                '"' => {
                    self.index += 1;
                    continue :state .word;
                },
                '\\' => {
                    escape_start = self.index;
                    self.index += 1;
                    continue :state .double_quote_escape;
                },
                else => {
                    self.index += 1;
                    continue :state .double_quote;
                },
            },
            .double_quote_escape => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        result.loc.start = self.index;
                        continue :state .invalid;
                    }
                    result.tag = .unterminated_escape;
                    result.loc.start = escape_start;
                },
                '\n' => {
                    self.index += 1;
                    if (self.index == self.buffer.len) {
                        result.tag = .unterminated_escape;
                        result.loc.start = escape_start;
                    } else {
                        continue :state .double_quote;
                    }
                },
                '\r' => {
                    if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        if (self.index == self.buffer.len) {
                            result.tag = .unterminated_escape;
                            result.loc.start = escape_start;
                        } else {
                            continue :state .double_quote;
                        }
                    } else {
                        self.index += 1;
                        continue :state .double_quote;
                    }
                },
                else => {
                    self.index += 1;
                    continue :state .double_quote;
                },
            },
            .semicolon => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    ';' => continue :state .semicolon_semicolon,
                    '&' => {
                        result.tag = .semicolon_ampersand;
                        self.index += 1;
                    },
                    else => result.tag = .semicolon,
                }
            },
            .semicolon_semicolon => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '&' => {
                        result.tag = .semicolon_semicolon_ampersand;
                        self.index += 1;
                    },
                    else => result.tag = .semicolon_semicolon,
                }
            },
            .ampersand => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '>' => continue :state .ampersand_gt,
                    '&' => {
                        result.tag = .ampersand_ampersand;
                        self.index += 1;
                    },
                    else => result.tag = .ampersand,
                }
            },
            .ampersand_gt => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '>' => {
                        result.tag = .ampersand_gt_gt;
                        self.index += 1;
                    },
                    else => result.tag = .ampersand_gt,
                }
            },
            .pipe => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '|' => {
                        result.tag = .pipe_pipe;
                        self.index += 1;
                    },
                    '&' => {
                        result.tag = .pipe_ampersand;
                        self.index += 1;
                    },
                    else => result.tag = .pipe,
                }
            },
            .lt => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '&' => {
                        result.tag = .lt_ampersand;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .lt_gt;
                        self.index += 1;
                    },
                    '<' => continue :state .lt_lt,
                    else => result.tag = .lt,
                }
            },
            .lt_lt => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '<' => {
                        result.tag = .lt_lt_lt;
                        self.index += 1;
                    },
                    '-' => {
                        result.tag = .lt_lt_minus;
                        self.index += 1;
                    },
                    else => result.tag = .lt_lt,
                }
            },
            .gt => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '&' => {
                        result.tag = .gt_ampersand;
                        self.index += 1;
                    },
                    '|' => {
                        result.tag = .gt_pipe;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .gt_gt;
                        self.index += 1;
                    },
                    else => result.tag = .gt,
                }
            },
            .invalid => {
                result.tag = .invalid;
                self.index += 1;
            },
        }
        if (result.tag == .word) {
            const word = self.buffer[result.loc.start..self.index];
            if (Token.getKeyword(word)) |keyword| {
                result.tag = keyword;
            }
        }
        result.loc.end = self.index;
        return result;
    }
};

test "keywords" {
    try testTokenize(
        \\if then elif else fi 'if' "then" i\f
    ,
        &.{
            .keyword_if,
            .keyword_then,
            .keyword_elif,
            .keyword_else,
            .keyword_fi,
            .word,
            .word,
            .word,
            .eof,
        },
    );
}

test "words" {
    try testTokenize("echo hello world", &.{
        .word,
        .word,
        .word,
        .eof,
    });
}

test "digits and word" {
    try testTokenize("echo 1 28 314pi", &.{
        .word,
        .digits,
        .digits,
        .word,
        .eof,
    });
}

test "words, digits and operators" {
    try testTokenize(
        \\echo foo 2>>bar ; ;; ;& ;;& & && &> &>> | || |&
        \\( ) < > << <<- <<< >> <& >& <> >|
        \\
    , &.{
        .word,
        .word,
        .digits,
        .gt_gt,
        .word,
        .semicolon,
        .semicolon_semicolon,
        .semicolon_ampersand,
        .semicolon_semicolon_ampersand,
        .ampersand,
        .ampersand_ampersand,
        .ampersand_gt,
        .ampersand_gt_gt,
        .pipe,
        .pipe_pipe,
        .pipe_ampersand,
        .newline,
        .l_paren,
        .r_paren,
        .lt,
        .gt,
        .lt_lt,
        .lt_lt_minus,
        .lt_lt_lt,
        .gt_gt,
        .lt_ampersand,
        .gt_ampersand,
        .lt_gt,
        .gt_pipe,
        .newline,
        .eof,
    });
}

test "comments end at LF or CRLF and preserve newline locations" {
    try testTokenize("# comment", &.{.eof});
    try testTokenize("# comment\nnext", &.{ .newline, .word, .eof });

    const source = "# comment\r\nnext";
    var tokenizer = Tokenizer.init(source);
    const newline = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.newline, newline.tag);
    try std.testing.expectEqual(@as(usize, 9), newline.loc.start);
    try std.testing.expectEqual(@as(usize, 11), newline.loc.end);
    try std.testing.expectEqual(Token.Tag.word, tokenizer.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, tokenizer.next().tag);
}

test "lone CR is part of a word while CRLF is a newline" {
    const lone_cr = "12\r>";
    var lone_cr_tokenizer = Tokenizer.init(lone_cr);
    const word = lone_cr_tokenizer.next();
    try std.testing.expectEqual(Token.Tag.word, word.tag);
    try std.testing.expectEqualStrings("12\r", lone_cr[word.loc.start..word.loc.end]);
    try std.testing.expectEqual(Token.Tag.gt, lone_cr_tokenizer.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lone_cr_tokenizer.next().tag);

    try testTokenize("foo\r\nbar", &.{ .word, .newline, .word, .eof });
}

test "quoted and escaped text stays in one word" {
    try testTokenize(
        \\echo "hello world" 'single quoted' escaped\ space
    ,
        &.{ .word, .word, .word, .word, .eof },
    );
}

test "unterminated quotes and escapes report their opening location" {
    var single = Tokenizer.init("prefix'hello");
    const single_issue = single.next();
    try std.testing.expectEqual(Token.Tag.unterminated_single_quote, single_issue.tag);
    try std.testing.expectEqual(@as(usize, 6), single_issue.loc.start);
    try std.testing.expectEqual(@as(usize, 12), single_issue.loc.end);

    var double = Tokenizer.init("prefix\"hello");
    const double_issue = double.next();
    try std.testing.expectEqual(Token.Tag.unterminated_double_quote, double_issue.tag);
    try std.testing.expectEqual(@as(usize, 6), double_issue.loc.start);
    try std.testing.expectEqual(@as(usize, 12), double_issue.loc.end);

    var escape = Tokenizer.init("foo\\");
    const escape_issue = escape.next();
    try std.testing.expectEqual(Token.Tag.unterminated_escape, escape_issue.tag);
    try std.testing.expectEqual(@as(usize, 3), escape_issue.loc.start);
    try std.testing.expectEqual(@as(usize, 4), escape_issue.loc.end);
}

test "LF and CRLF line continuations preserve a digits token" {
    try testTokenize("12\\\n34", &.{ .digits, .eof });
    try testTokenize("12\\\r\n34", &.{ .digits, .eof });
}

test "an internal NUL is invalid and points at the byte" {
    const source = "foo\x00bar";
    var tokenizer = Tokenizer.init(source);
    const invalid = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.invalid, invalid.tag);
    try std.testing.expectEqual(@as(usize, 3), invalid.loc.start);
    try std.testing.expectEqual(@as(usize, 4), invalid.loc.end);

    const comment_source = "# comment\x00after";
    var comment_tokenizer = Tokenizer.init(comment_source);
    const invalid_comment = comment_tokenizer.next();
    try std.testing.expectEqual(Token.Tag.invalid, invalid_comment.tag);
    try std.testing.expectEqual(@as(usize, 9), invalid_comment.loc.start);
    try std.testing.expectEqual(@as(usize, 10), invalid_comment.loc.end);
}

test "newline has no unique fixed lexeme" {
    try std.testing.expectEqual(@as(?[]const u8, null), Token.lexeme(.newline));
    try std.testing.expectEqualStrings("newline", Token.symbol(.newline));
}

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
}
