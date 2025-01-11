const std = @import("std");
const Ast = @This();
const Allocator = std.mem.Allocator;
const Token = @import("token.zig");
const Lexer = @import("lexer.zig");

const Index = u32;

source: []const u8,
tokens: TokenList.Slice,
// errors: []const Error,
root: Root,

pub const TokenIndex = u32;
pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    token_type: Token.TokenType,
    start: ByteOffset,
    end: ByteOffset,
});

pub const Root = struct {
    commands: std.ArrayList(Command),

    pub fn init(allocator: Allocator) Root {
        return Root{
            .commands = std.ArrayList(Command).init(allocator),
        };
    }
    pub fn deinit(self: Root) void {
        for (self.commands.items) |c| {
            c.deinit();
        }
        self.commands.deinit();
    }
};

pub const Command = struct {
    argv: std.ArrayList(Index),
    redirection: std.ArrayList(Redirection),

    pub fn init(allocator: Allocator) Command {
        return Command{
            .argv = std.ArrayList(Index).init(allocator),
            .redirection = std.ArrayList(Redirection).init(allocator),
        };
    }
    pub fn deinit(self: Command) void {
        self.argv.deinit();
        self.redirection.deinit();
    }
};

pub const Redirection = union(enum) {
    in: struct {
        fd: ?Index,
        target: Index,
    },
    out: struct {
        fd: ?Index,
        target: Index,
    },
};

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(allocator);

    try tokens.ensureTotalCapacity(allocator, 128);
    var root = Root.init(allocator);
    var command = Command.init(allocator);

    var lexer = Lexer.init(source);
    while (true) {
        const token = lexer.next();
        try tokens.append(allocator, .{
            .token_type = token.token_type,
            .start = @as(ByteOffset, @intCast(token.loc.start)),
            .end = @as(ByteOffset, @intCast(token.loc.end)),
        });
        if (token.token_type == .eof) {
            break;
        }
    }

    var state: enum {
        start,
        word,
        number,
        redirection_output,
    } = .start;
    var pending: ?Index = null;
    for (0..tokens.len) |i| {
        const token_type = tokens.items(.token_type)[i];
        switch (state) {
            .start => {
                switch (token_type) {
                    .word,
                    .quoted_single,
                    .quoted_double,
                    => {
                        try command.argv.append(@intCast(i));
                        state = .word;
                    },
                    .number => {
                        state = .number;
                        pending = @intCast(i);
                    },
                    .whitespace => {
                        continue;
                    },
                    .redirection_output => {
                        state = .redirection_output;
                    },
                    .eof => {
                        break;
                    },
                    else => {
                        // not implemented yet
                        unreachable;
                    },
                }
            },
            .word => {
                switch (token_type) {
                    .word,
                    .quoted_single,
                    .quoted_double,
                    .number,
                    => {
                        continue;
                    },
                    .whitespace => {
                        state = .start;
                    },
                    .redirection_output => {
                        state = .redirection_output;
                    },
                    .eof => {
                        break;
                    },
                    else => {
                        // not implemented yet
                        unreachable;
                    },
                }
            },
            .number => {
                switch (token_type) {
                    .word,
                    .quoted_single,
                    .quoted_double,
                    .number,
                    => {
                        try command.argv.append(@intCast(pending.?));
                        pending = null;
                        state = .word;
                    },
                    .whitespace => {
                        try command.argv.append(@intCast(pending.?));
                        pending = null;
                        state = .start;
                    },
                    .redirection_output => {
                        state = .redirection_output;
                    },
                    .eof => {
                        try command.argv.append(@intCast(pending.?));
                        break;
                    },
                    else => {
                        // not implemented yet
                        unreachable;
                    },
                }
            },
            .redirection_output => {
                switch (token_type) {
                    .word,
                    .quoted_single,
                    .quoted_double,
                    .number,
                    => {
                        try command.redirection.append(Redirection{ .out = .{
                            .fd = pending,
                            .target = @intCast(i),
                        } });
                        pending = null;
                        state = .word;
                    },
                    .whitespace => {
                        continue;
                    },
                    .redirection_output => {
                        // error
                        unreachable;
                    },
                    .eof => {
                        // error
                        unreachable;
                    },
                    else => {
                        // not implemented yet
                        unreachable;
                    },
                }
            },
        }
    }

    try root.commands.append(command);

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .root = root,
    };
}

pub fn deinit(tree: *Ast, allocator: Allocator) void {
    tree.tokens.deinit(allocator);
    tree.root.deinit();
}

test parse {
    const allocator = std.testing.allocator;
    const input = "echo hello >file";
    var tree = try Ast.parse(allocator, input);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(tree.root.commands.items[0].argv.items[0], @as(Index, 0));
    try std.testing.expectEqual(tree.root.commands.items[0].argv.items[1], @as(Index, 2));
    const redirection = tree.root.commands.items[0].redirection.items[0];

    try std.testing.expectEqual(null, redirection.out.fd);
    try std.testing.expectEqual(5, redirection.out.target);
}
