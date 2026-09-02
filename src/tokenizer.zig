//! Tokenizer for habush source
//! Based on  https://codeberg.org/ziglang/zig/src/branch/master/lib/std/zig/tokenizer.zig

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{});

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        invalid,
        eof,
        word,
        digits,

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
            => null,

            .newline => "\n",
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
        return tag.lexeme() orelse switch (tag) {
            .invalid => "invalid token",
            .eof => "EOF",
            .word => "a word",
            .digits => "a digits literal",
            .unterminated_single_quote => "UNTERMINATED (')",
            .unterminated_double_quote => "UNTERMINATED (\")",
            .unterminated_escape => "UNTERMINATED (\\)",
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
        int,
        word,
        // word_escape,
        // single_quote,
        // double_quote,
        // double_quote_escape,
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
        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .{
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
                    continue :state .int;
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
                        if (self.index == self.buffer.len) {
                            continue :state .invalid;
                        } else return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    },
                    '\n' => continue :state .start,
                    else => continue :state .comment,
                }
            },
            .int => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        }
                    },
                    '0'...'9' => continue :state .int,
                    ' ', '\t', '\n', ';', '&', '|', '(', ')', '<', '>' => {},
                    '\r' => {
                        if (self.buffer[self.index + 1] != '\n') {
                            result.tag = .word;
                            self.index += 1;
                            continue :state .word;
                        }
                    },
                    else => {
                        result.tag = .word;
                        continue :state .word;
                    },
                }
            },
            .word => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        }
                    },
                    ' ', '\t', '\n', ';', '&', '|', '(', ')', '<', '>' => {},
                    '\r' => {
                        if (self.buffer[self.index + 1] != '\n') {
                            self.index += 1;
                            continue :state .word;
                        }
                    },
                    else => continue :state .word,
                }
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
        result.loc.end = self.index;
        return result;
    }
};

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

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
}
