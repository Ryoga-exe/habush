//! In-progress parser state. Converted to an `Ast` after parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parse = @This();

const StopSet = struct {
    token_tag: ?Token.Tag = null,
    reserved_words: []const Token.Tag = &.{},

    fn matches(stop: StopSet, parser: *const Parse) bool {
        if (stop.token_tag) |tag| {
            if (parser.tokenTag(parser.tok_i) == tag) return true;
        }
        return stop.matchesReserved(parser);
    }

    fn matchesReserved(stop: StopSet, parser: *const Parse) bool {
        const actual = parser.tokenTag(parser.tok_i);
        for (stop.reserved_words) |expected| {
            if (actual == expected) return true;
        }
        return false;
    }
};

const IfBuilder = struct {
    condition: Node.OptionalIndex = .none,
    then_token: Node.OptionalTokenIndex = .none,
    then_body: Node.OptionalIndex = .none,
    else_token: Node.OptionalTokenIndex = .none,
    else_body: Node.OptionalIndex = .none,
    fi_token: Node.OptionalTokenIndex = .none,
    redirects: ?Node.SubRange = null,
};

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
tok_i: Ast.TokenIndex = 0,
errors: std.ArrayList(Ast.Error) = .empty,
status: Ast.Status = .complete,
nodes: Ast.NodeList = .empty,
extra_data: std.ArrayList(u32) = .empty,
scratch: std.ArrayList(Node.Index) = .empty,
list_scratch: std.ArrayList(Node.ListItem) = .empty,
elif_scratch: std.ArrayList(Node.ElifBranch) = .empty,

pub fn parse(gpa: Allocator, source: [:0]const u8) Ast.ParseError!Ast {
    if (source.len > std.math.maxInt(Ast.ByteOffset)) return error.SourceTooLarge;

    var tokens: Ast.TokenList = .empty;
    defer tokens.deinit(gpa);

    var errors: std.ArrayList(Ast.Error) = .empty;
    defer errors.deinit(gpa);
    var status: Ast.Status = .complete;

    var scanner = Tokenizer.init(source);
    while (true) {
        const item = scanner.next();
        const token_index = std.math.cast(Ast.TokenIndex, tokens.len) orelse
            return error.SourceTooLarge;

        try tokens.append(gpa, .{
            .tag = item.tag,
            .start = @intCast(item.loc.start),
        });

        switch (item.tag) {
            .invalid => try errors.append(gpa, .{
                .tag = .invalid_token,
                .token = token_index,
            }),
            .unterminated_single_quote,
            .unterminated_double_quote,
            .unterminated_escape,
            => status = .{ .incomplete = .{ .lexical = token_index } },
            else => {},
        }

        if (item.tag == .eof) break;
    }

    var token_slice = tokens.toOwnedSlice();
    errdefer token_slice.deinit(gpa);

    var parser: Parse = .{
        .gpa = gpa,
        .source = source,
        .tokens = token_slice,
        .errors = errors,
        .status = status,
    };
    errors = .empty;
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);
    defer parser.list_scratch.deinit(gpa);
    defer parser.elif_scratch.deinit(gpa);

    try parser.parseRoot();

    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    const parse_errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(parse_errors);

    return .{
        .source = source,
        .tokens = token_slice,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = parse_errors,
        .status = parser.status,
    };
}

fn parseRoot(parser: *Parse) Ast.ParseError!void {
    try parser.nodes.append(parser.gpa, .{
        .tag = .root,
        .main_token = 0,
        .data = .{ .opt_node = .none },
    });

    // Invalid or incomplete lexical input cannot be parsed without losing
    // source structure.
    if (parser.errors.items.len != 0 or parser.status == .incomplete) return;

    const list = try parser.parseList(.{}) orelse return;

    parser.nodes.set(@intFromEnum(Node.Index.root), .{
        .tag = .root,
        .main_token = parser.nodeMainToken(list),
        .data = .{ .opt_node = list.toOptional() },
    });
}

fn parseList(
    parser: *Parse,
    stop: StopSet,
) Ast.ParseError!?Node.Index {
    const scratch_start = parser.list_scratch.items.len;
    defer parser.list_scratch.shrinkRetainingCapacity(scratch_start);

    parser.skipNewlines();
    if (parser.atListEnd(stop)) return null;

    if (!parser.canStartCommand()) {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return null;
    }

    const main_token = parser.tok_i;
    while (true) {
        const errors_before_command = parser.errors.items.len;
        const command = try parser.parseAndOr();

        var separator: Node.OptionalTokenIndex = .none;
        switch (parser.tokenTag(parser.tok_i)) {
            .semicolon, .ampersand => {
                separator = Node.OptionalTokenIndex.fromOptional(parser.nextToken());
                parser.skipNewlines();
            },
            .newline => {
                separator = Node.OptionalTokenIndex.fromOptional(parser.nextToken());
                parser.skipNewlines();
            },
            else => {},
        }

        try parser.list_scratch.append(parser.gpa, .{
            .command = command,
            .separator = separator,
        });

        if (parser.atListEnd(stop)) {
            if (stop.matchesReserved(parser) and separator == .none) {
                try parser.warn(.{
                    .tag = .expected_separator,
                    .token = parser.tok_i,
                });
            }
            break;
        }
        if (parser.errors.items.len != errors_before_command or
            parser.status == .incomplete)
        {
            break;
        }
        if (separator == .none) {
            try parser.warn(.{
                .tag = .unexpected_token,
                .token = parser.tok_i,
            });
            break;
        }
        if (!parser.canStartCommand()) {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
            break;
        }
    }

    const items = try parser.addListItems(parser.list_scratch.items[scratch_start..]);
    return @as(?Node.Index, try parser.addNode(.{
        .tag = .list,
        .main_token = main_token,
        .data = .{ .extra_range = items },
    }));
}

fn parseAndOr(parser: *Parse) Ast.ParseError!Node.Index {
    var lhs = try parser.parsePipeline();

    while (isAndOr(parser.tokenTag(parser.tok_i))) {
        const operator = parser.nextToken();
        parser.skipNewlines();

        if (!parser.canStartCommand()) {
            if (parser.tokenTag(parser.tok_i) == .eof) {
                parser.setIncomplete(.{ .command_after = operator });
            } else {
                try parser.warn(.{
                    .tag = .expected_command,
                    .token = parser.tok_i,
                });
            }
            return lhs;
        }

        const rhs = try parser.parsePipeline();
        lhs = try parser.addNode(.{
            .tag = switch (parser.tokenTag(operator)) {
                .ampersand_ampersand => .and_if,
                .pipe_pipe => .or_if,
                else => unreachable,
            },
            .main_token = operator,
            .data = .{ .node_and_node = .{ lhs, rhs } },
        });
    }

    return lhs;
}

fn parsePipeline(parser: *Parse) Ast.ParseError!Node.Index {
    var lhs = try parser.parseCommand();

    while (isPipe(parser.tokenTag(parser.tok_i))) {
        const operator = parser.nextToken();
        parser.skipNewlines();

        if (!parser.canStartCommand()) {
            if (parser.tokenTag(parser.tok_i) == .eof) {
                parser.setIncomplete(.{ .command_after = operator });
            } else {
                try parser.warn(.{
                    .tag = .expected_command,
                    .token = parser.tok_i,
                });
            }
            return lhs;
        }

        const rhs = try parser.parseCommand();
        lhs = try parser.addNode(.{
            .tag = switch (parser.tokenTag(operator)) {
                .pipe => .pipe,
                .pipe_ampersand => .pipe_and,
                else => unreachable,
            },
            .main_token = operator,
            .data = .{ .node_and_node = .{ lhs, rhs } },
        });
    }

    return lhs;
}

fn parseCommand(parser: *Parse) Ast.ParseError!Node.Index {
    return switch (parser.tokenTag(parser.tok_i)) {
        .keyword_if => parser.parseIfClause(),
        .l_paren => parser.parseSubshell(),
        else => parser.parseSimpleCommand(),
    };
}

fn parseIfClause(parser: *Parse) Ast.ParseError!Node.Index {
    const if_token = parser.nextToken();
    var builder: IfBuilder = .{};
    const elif_start = parser.elif_scratch.items.len;
    defer parser.elif_scratch.shrinkRetainingCapacity(elif_start);

    parser.skipNewlines();
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(.if_clause, .condition, if_token);
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }

    const condition_errors = parser.errors.items.len;
    const condition = try parser.parseList(.{
        .reserved_words = &.{.keyword_then},
    });
    if (condition) |node| {
        builder.condition = node.toOptional();
    } else {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    if (parser.failedSince(condition_errors)) {
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(.if_clause, .then_keyword, if_token);
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    if (parser.tokenTag(parser.tok_i) != .keyword_then) {
        try parser.warn(.{
            .tag = .expected_then_keyword,
            .token = parser.tok_i,
        });
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }

    const then_token = parser.nextToken();
    builder.then_token = Node.OptionalTokenIndex.fromOptional(then_token);
    parser.skipNewlines();
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(.if_clause, .body, then_token);
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }

    const body_errors = parser.errors.items.len;
    const then_body = try parser.parseList(.{
        .reserved_words = &.{ .keyword_elif, .keyword_else, .keyword_fi },
    });
    if (then_body) |node| {
        builder.then_body = node.toOptional();
    } else {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    if (parser.failedSince(body_errors)) {
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }

    while (parser.tokenTag(parser.tok_i) == .keyword_elif) {
        var branch: Node.ElifBranch = .{
            .elif_token = parser.nextToken(),
            .condition = .none,
            .then_token = .none,
            .body = .none,
        };
        parser.skipNewlines();

        if (parser.tokenTag(parser.tok_i) == .eof) {
            parser.setCompoundIncomplete(.elif_clause, .condition, branch.elif_token);
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }

        const elif_condition_errors = parser.errors.items.len;
        const elif_condition = try parser.parseList(.{
            .reserved_words = &.{.keyword_then},
        });
        if (elif_condition) |node| {
            branch.condition = node.toOptional();
        } else {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
        if (parser.failedSince(elif_condition_errors)) {
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
        if (parser.tokenTag(parser.tok_i) == .eof) {
            parser.setCompoundIncomplete(.elif_clause, .then_keyword, branch.elif_token);
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
        if (parser.tokenTag(parser.tok_i) != .keyword_then) {
            try parser.warn(.{
                .tag = .expected_then_keyword,
                .token = parser.tok_i,
            });
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }

        const elif_then = parser.nextToken();
        branch.then_token = Node.OptionalTokenIndex.fromOptional(elif_then);
        parser.skipNewlines();
        if (parser.tokenTag(parser.tok_i) == .eof) {
            parser.setCompoundIncomplete(.elif_clause, .body, elif_then);
            try parser.elif_scratch.append(parser.gpa, branch);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }

        const elif_body_errors = parser.errors.items.len;
        const elif_body = try parser.parseList(.{
            .reserved_words = &.{ .keyword_elif, .keyword_else, .keyword_fi },
        });
        if (elif_body) |node| {
            branch.body = node.toOptional();
        } else {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
        }
        try parser.elif_scratch.append(parser.gpa, branch);
        if (parser.failedSince(elif_body_errors) or elif_body == null) {
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
    }

    if (parser.tokenTag(parser.tok_i) == .keyword_else) {
        const else_token = parser.nextToken();
        builder.else_token = Node.OptionalTokenIndex.fromOptional(else_token);
        parser.skipNewlines();
        if (parser.tokenTag(parser.tok_i) == .eof) {
            parser.setCompoundIncomplete(.else_clause, .body, else_token);
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }

        const else_errors = parser.errors.items.len;
        const else_body = try parser.parseList(.{
            .reserved_words = &.{.keyword_fi},
        });
        if (else_body) |node| {
            builder.else_body = node.toOptional();
        } else {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
        if (parser.failedSince(else_errors)) {
            return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
        }
    }

    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(.if_clause, .fi_keyword, if_token);
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    if (parser.tokenTag(parser.tok_i) != .keyword_fi) {
        try parser.warn(.{
            .tag = .expected_fi_keyword,
            .token = parser.tok_i,
        });
        return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
    }
    builder.fi_token = Node.OptionalTokenIndex.fromOptional(parser.nextToken());

    const redirect_start = parser.scratch.items.len;
    defer parser.scratch.shrinkRetainingCapacity(redirect_start);
    while (parser.startsRedirect()) {
        try parser.scratch.append(parser.gpa, try parser.parseRedirect());
    }
    builder.redirects = try parser.listToSpan(parser.scratch.items[redirect_start..]);

    return parser.finishIf(if_token, builder, parser.elif_scratch.items[elif_start..]);
}

fn finishIf(
    parser: *Parse,
    if_token: Ast.TokenIndex,
    builder: IfBuilder,
    elif_branches: []const Node.ElifBranch,
) Ast.ParseError!Node.Index {
    const elif_range = try parser.addElifBranches(elif_branches);
    const redirects = builder.redirects orelse try parser.emptySpan();
    const extra = try parser.addExtra(Node.If{
        .condition = builder.condition,
        .then_token = builder.then_token,
        .then_body = builder.then_body,
        .elif_start = elif_range.start,
        .elif_end = elif_range.end,
        .else_token = builder.else_token,
        .else_body = builder.else_body,
        .fi_token = builder.fi_token,
        .redirects_start = redirects.start,
        .redirects_end = redirects.end,
    });
    return parser.addNode(.{
        .tag = .if_clause,
        .main_token = if_token,
        .data = .{ .extra = extra },
    });
}

fn parseSubshell(parser: *Parse) Ast.ParseError!Node.Index {
    const open = parser.nextToken();
    const body = try parser.parseList(.{ .token_tag = .r_paren });

    var close_token = parser.tok_i;
    if (parser.tokenTag(parser.tok_i) == .r_paren) {
        if (body == null) {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
        }
        close_token = parser.nextToken();
    } else if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setIncomplete(.{ .closing_paren = open });
    } else {
        try parser.warn(.{
            .tag = .expected_token,
            .token = parser.tok_i,
            .extra = .{ .expected_tag = .r_paren },
        });
    }

    const scratch_start = parser.scratch.items.len;
    defer parser.scratch.shrinkRetainingCapacity(scratch_start);
    while (parser.startsRedirect()) {
        try parser.scratch.append(parser.gpa, try parser.parseRedirect());
    }
    const redirects = try parser.listToSpan(parser.scratch.items[scratch_start..]);

    const extra = try parser.addSubshell(.{
        .body = Node.OptionalIndex.fromOptional(body),
        .close_token = close_token,
        .redirects_start = redirects.start,
        .redirects_end = redirects.end,
    });
    return parser.addNode(.{
        .tag = .subshell,
        .main_token = open,
        .data = .{ .extra = extra },
    });
}

fn parseSimpleCommand(parser: *Parse) Ast.ParseError!Node.Index {
    const scratch_start = parser.scratch.items.len;
    defer parser.scratch.shrinkRetainingCapacity(scratch_start);

    const main_token = parser.tok_i;
    while (true) {
        const part = if (parser.startsRedirect())
            try parser.parseRedirect()
        else if (isWord(parser.tokenTag(parser.tok_i)))
            try parser.parseWord()
        else
            break;
        try parser.scratch.append(parser.gpa, part);
    }

    const parts = try parser.listToSpan(parser.scratch.items[scratch_start..]);
    return parser.addNode(.{
        .tag = .simple_command,
        .main_token = main_token,
        .data = .{ .extra_range = parts },
    });
}

fn parseWord(parser: *Parse) Ast.ParseError!Node.Index {
    const word_token = parser.nextToken();
    return parser.addNode(.{
        .tag = .word,
        .main_token = word_token,
        .data = .{ .none = {} },
    });
}

fn parseRedirect(parser: *Parse) Ast.ParseError!Node.Index {
    var io_number: Node.OptionalTokenIndex = .none;
    if (parser.hasIoNumber()) {
        io_number = Node.OptionalTokenIndex.fromOptional(parser.nextToken());
    }

    const operator = parser.nextToken();
    const target = parser.tok_i;
    if (!isWord(parser.tokenTag(target))) {
        if (parser.tokenTag(target) == .eof) {
            parser.setIncomplete(.{ .redirect_target = operator });
        } else {
            try parser.warn(.{
                .tag = .expected_redirect_target,
                .token = target,
            });
        }
    } else {
        _ = parser.nextToken();
    }

    return parser.addNode(.{
        .tag = .redirect,
        .main_token = operator,
        .data = .{ .opt_token_and_token = .{ io_number, target } },
    });
}

fn listToSpan(
    parser: *Parse,
    items: []const Node.Index,
) Ast.ParseError!Node.SubRange {
    const start = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    for (items) |item| {
        try parser.extra_data.append(parser.gpa, @intFromEnum(item));
    }
    const end = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    return .{
        .start = @enumFromInt(start),
        .end = @enumFromInt(end),
    };
}

fn addListItems(
    parser: *Parse,
    items: []const Node.ListItem,
) Ast.ParseError!Node.SubRange {
    const start = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    for (items) |item| {
        try parser.extra_data.append(parser.gpa, @intFromEnum(item.command));
        try parser.extra_data.append(parser.gpa, @intFromEnum(item.separator));
    }
    const end = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    return .{
        .start = @enumFromInt(start),
        .end = @enumFromInt(end),
    };
}

fn addSubshell(
    parser: *Parse,
    subshell: Node.Subshell,
) Ast.ParseError!Ast.ExtraIndex {
    return parser.addExtra(subshell);
}

fn addElifBranches(
    parser: *Parse,
    branches: []const Node.ElifBranch,
) Ast.ParseError!Node.SubRange {
    const start = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    for (branches) |branch| {
        _ = try parser.addExtra(branch);
    }
    const end = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    return .{
        .start = @enumFromInt(start),
        .end = @enumFromInt(end),
    };
}

fn addExtra(parser: *Parse, extra: anytype) Ast.ParseError!Ast.ExtraIndex {
    const start = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    inline for (std.meta.fields(@TypeOf(extra))) |field| {
        const value = @field(extra, field.name);
        const raw: u32 = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            Node.OptionalTokenIndex,
            Ast.ExtraIndex,
            => @intFromEnum(value),
            Ast.TokenIndex => value,
            else => @compileError("unexpected extra_data field type: " ++ @typeName(field.type)),
        };
        try parser.extra_data.append(parser.gpa, raw);
    }
    return @enumFromInt(start);
}

fn emptySpan(parser: *const Parse) Ast.ParseError!Node.SubRange {
    const index = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    return .{
        .start = @enumFromInt(index),
        .end = @enumFromInt(index),
    };
}

fn addNode(parser: *Parse, node: Node) Ast.ParseError!Node.Index {
    const index = std.math.cast(u32, parser.nodes.len) orelse
        return error.SourceTooLarge;
    try parser.nodes.append(parser.gpa, node);
    return @enumFromInt(index);
}

fn warn(parser: *Parse, parse_error: Ast.Error) Allocator.Error!void {
    try parser.errors.append(parser.gpa, parse_error);
}

fn skipNewlines(parser: *Parse) void {
    while (parser.tokenTag(parser.tok_i) == .newline) _ = parser.nextToken();
}

fn tokenTag(parser: *const Parse, token_index: Ast.TokenIndex) Token.Tag {
    return parser.tokens.items(.tag)[token_index];
}

fn nodeMainToken(parser: *const Parse, node: Node.Index) Ast.TokenIndex {
    return parser.nodes.items(.main_token)[@intFromEnum(node)];
}

fn nextToken(parser: *Parse) Ast.TokenIndex {
    const result = parser.tok_i;
    parser.tok_i += 1;
    return result;
}

fn canStartCommand(parser: *const Parse) bool {
    const tag = parser.tokenTag(parser.tok_i);
    if (isReservedWord(tag)) return tag == .keyword_if;
    return tag == .l_paren or isWord(tag) or parser.startsRedirect();
}

fn atListEnd(parser: *const Parse, stop: StopSet) bool {
    const tag = parser.tokenTag(parser.tok_i);
    return tag == .eof or stop.matches(parser);
}

fn setIncomplete(parser: *Parse, continuation: Ast.Continuation) void {
    if (parser.status == .complete) {
        parser.status = .{ .incomplete = continuation };
    }
}

fn setCompoundIncomplete(
    parser: *Parse,
    kind: Ast.CompoundContinuation.Kind,
    expected: Ast.CompoundContinuation.Expected,
    opened_by: Ast.TokenIndex,
) void {
    parser.setIncomplete(.{ .compound = .{
        .kind = kind,
        .expected = expected,
        .opened_by = opened_by,
    } });
}

fn failedSince(parser: *const Parse, error_count: usize) bool {
    return parser.errors.items.len != error_count or parser.status == .incomplete;
}

fn startsRedirect(parser: *const Parse) bool {
    return isRedirect(parser.tokenTag(parser.tok_i)) or parser.hasIoNumber();
}

fn hasIoNumber(parser: *const Parse) bool {
    if (parser.tokenTag(parser.tok_i) != .digits) return false;

    const operator_index = parser.tok_i + 1;
    if (!supportsIoNumber(parser.tokenTag(operator_index))) return false;

    return parser.tokenEnd(parser.tok_i) == parser.tokens.items(.start)[operator_index];
}

fn tokenEnd(parser: *const Parse, token_index: Ast.TokenIndex) usize {
    var scanner: Tokenizer = .{
        .buffer = parser.source,
        .index = parser.tokens.items(.start)[token_index],
    };
    return scanner.next().loc.end;
}

fn isWord(tag: Token.Tag) bool {
    return tag == .word or tag == .digits or isReservedWord(tag);
}

fn isReservedWord(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_if,
        .keyword_then,
        .keyword_elif,
        .keyword_else,
        .keyword_fi,
        => true,
        else => false,
    };
}

fn isPipe(tag: Token.Tag) bool {
    return tag == .pipe or tag == .pipe_ampersand;
}

fn isAndOr(tag: Token.Tag) bool {
    return tag == .ampersand_ampersand or tag == .pipe_pipe;
}

fn isRedirect(tag: Token.Tag) bool {
    return switch (tag) {
        .ampersand_gt,
        .ampersand_gt_gt,
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
        => true,
        else => false,
    };
}

fn supportsIoNumber(tag: Token.Tag) bool {
    return isRedirect(tag) and tag != .ampersand_gt and tag != .ampersand_gt_gt;
}

test "parses empty input" {
    var tree = try Ast.parse(std.testing.allocator, "");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.tokens.len);
    try std.testing.expectEqual(Token.Tag.eof, tree.tokenTag(0));
    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try std.testing.expect(tree.nodeData(.root).opt_node.unwrap() == null);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "parses a simple command into indexed nodes" {
    var tree = try Ast.parse(std.testing.allocator, "echo hello");
    defer tree.deinit(std.testing.allocator);

    const list = tree.nodeData(.root).opt_node.unwrap().?;
    try std.testing.expectEqual(Node.Tag.list, tree.nodeTag(list));

    const list_range = tree.nodeData(list).extra_range;
    const item = tree.extraData(list_range.start, Node.ListItem);
    try std.testing.expect(item.separator.unwrap() == null);

    const command = item.command;
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(command));
    const parts = tree.extraDataSlice(tree.nodeData(command).extra_range, Node.Index);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("echo", tree.tokenSlice(tree.nodeMainToken(parts[0])));
    try std.testing.expectEqualStrings("hello", tree.tokenSlice(tree.nodeMainToken(parts[1])));
}

test "records an unexpected leading operator" {
    var tree = try Ast.parse(std.testing.allocator, "|");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(@as(Ast.TokenIndex, 0), tree.errors[0].token);
}

test "preserves an unfinished lexical token as a continuation" {
    var tree = try Ast.parse(std.testing.allocator, "echo 'open");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .lexical);
    try std.testing.expectEqual(
        Token.Tag.unterminated_single_quote,
        tree.tokenTag(tree.status.incomplete.lexical),
    );
    try std.testing.expect(tree.nodeData(.root).opt_node.unwrap() == null);
}

test "parses redirections in simple command source order" {
    var tree = try Ast.parse(std.testing.allocator, "echo 2>>error.log <input");
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.extraDataSlice(tree.nodeData(command).extra_range, Node.Index);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(parts[0]));

    const output = tree.nodeData(parts[1]).opt_token_and_token;
    try std.testing.expectEqualStrings("2", tree.tokenSlice(output[0].unwrap().?));
    try std.testing.expectEqualStrings(">>", tree.tokenSlice(tree.nodeMainToken(parts[1])));
    try std.testing.expectEqualStrings("error.log", tree.tokenSlice(output[1]));

    const input = tree.nodeData(parts[2]).opt_token_and_token;
    try std.testing.expect(input[0].unwrap() == null);
    try std.testing.expectEqualStrings("<", tree.tokenSlice(tree.nodeMainToken(parts[2])));
    try std.testing.expectEqualStrings("input", tree.tokenSlice(input[1]));
}

test "digits separated from redirect remain a word" {
    var tree = try Ast.parse(std.testing.allocator, "echo 2 >out");
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.extraDataSlice(tree.nodeData(command).extra_range, Node.Index);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(parts[1]));
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.nodeMainToken(parts[1])));
    try std.testing.expectEqual(Node.Tag.redirect, tree.nodeTag(parts[2]));
}

test "digits before a both-stream redirect remain a word" {
    var tree = try Ast.parse(std.testing.allocator, "echo 2&>out");
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.extraDataSlice(tree.nodeData(command).extra_range, Node.Index);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.nodeMainToken(parts[1])));
    const redirect = tree.nodeData(parts[2]).opt_token_and_token;
    try std.testing.expect(redirect[0].unwrap() == null);
}

test "requests continuation for a missing redirection target at EOF" {
    var tree = try Ast.parse(std.testing.allocator, "echo >");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .redirect_target);
    try std.testing.expectEqualStrings(
        ">",
        tree.tokenSlice(tree.status.incomplete.redirect_target),
    );
}

test "records a missing redirection target before a newline" {
    var tree = try Ast.parse(std.testing.allocator, "echo >\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_redirect_target, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.newline, tree.tokenTag(tree.errors[0].token));
}

fn firstCommand(tree: *const Ast) Node.Index {
    const list = tree.nodeData(.root).opt_node.unwrap().?;
    return tree.listItem(list, 0).command;
}

test "parses pipe and pipe-and left associatively" {
    var tree = try Ast.parse(std.testing.allocator, "echo hi | grep h |& count");
    defer tree.deinit(std.testing.allocator);

    const outer = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.pipe_and, tree.nodeTag(outer));
    try std.testing.expectEqualStrings("|&", tree.tokenSlice(tree.nodeMainToken(outer)));

    const outer_data = tree.nodeData(outer).node_and_node;
    try std.testing.expectEqual(Node.Tag.pipe, tree.nodeTag(outer_data[0]));
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(outer_data[1]));

    const inner_data = tree.nodeData(outer_data[0]).node_and_node;
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(inner_data[0]));
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(inner_data[1]));
}

test "allows newlines after a pipe operator" {
    var tree = try Ast.parse(std.testing.allocator, "echo hi |\ngrep hi");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(Node.Tag.pipe, tree.nodeTag(firstCommand(&tree)));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "requests continuation for a missing pipeline command" {
    var tree = try Ast.parse(std.testing.allocator, "echo hi |");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .command_after);
    try std.testing.expectEqualStrings(
        "|",
        tree.tokenSlice(tree.status.incomplete.command_after),
    );
}

test "records a repeated pipe once" {
    var tree = try Ast.parse(std.testing.allocator, "echo | | cat");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.pipe, tree.tokenTag(tree.errors[0].token));
}

test "parses and-or after pipelines with the correct precedence" {
    var tree = try Ast.parse(std.testing.allocator, "a | b && c || d | e");
    defer tree.deinit(std.testing.allocator);

    const outer = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.or_if, tree.nodeTag(outer));

    const outer_data = tree.nodeData(outer).node_and_node;
    try std.testing.expectEqual(Node.Tag.and_if, tree.nodeTag(outer_data[0]));
    try std.testing.expectEqual(Node.Tag.pipe, tree.nodeTag(outer_data[1]));

    const and_data = tree.nodeData(outer_data[0]).node_and_node;
    try std.testing.expectEqual(Node.Tag.pipe, tree.nodeTag(and_data[0]));
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(and_data[1]));
}

test "allows newlines after an and-or operator" {
    var tree = try Ast.parse(std.testing.allocator, "first &&\nsecond");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(Node.Tag.and_if, tree.nodeTag(firstCommand(&tree)));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "requests continuation for a missing and-or command" {
    var tree = try Ast.parse(std.testing.allocator, "first ||");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .command_after);
    try std.testing.expectEqualStrings(
        "||",
        tree.tokenSlice(tree.status.incomplete.command_after),
    );
}

test "parses semicolon newline and background list separators" {
    var tree = try Ast.parse(std.testing.allocator, "first; second\nthird &");
    defer tree.deinit(std.testing.allocator);

    const list = tree.nodeData(.root).opt_node.unwrap().?;
    try std.testing.expectEqual(@as(usize, 3), tree.listItemCount(list));

    const first = tree.listItem(list, 0);
    const second = tree.listItem(list, 1);
    const third = tree.listItem(list, 2);
    try std.testing.expectEqual(Token.Tag.semicolon, tree.tokenTag(first.separator.unwrap().?));
    try std.testing.expectEqual(Token.Tag.newline, tree.tokenTag(second.separator.unwrap().?));
    try std.testing.expectEqual(Token.Tag.ampersand, tree.tokenTag(third.separator.unwrap().?));
}

test "parses a subshell body and trailing redirection" {
    var tree = try Ast.parse(std.testing.allocator, "(echo; cat) 2>log");
    defer tree.deinit(std.testing.allocator);

    const subshell_node = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.subshell, tree.nodeTag(subshell_node));

    const subshell = tree.subshell(subshell_node);
    try std.testing.expectEqualStrings(")", tree.tokenSlice(subshell.close_token));
    const body = subshell.body.unwrap().?;
    try std.testing.expectEqual(@as(usize, 2), tree.listItemCount(body));

    const redirects = tree.extraDataSlice(.{
        .start = subshell.redirects_start,
        .end = subshell.redirects_end,
    }, Node.Index);
    try std.testing.expectEqual(@as(usize, 1), redirects.len);
    try std.testing.expectEqual(Node.Tag.redirect, tree.nodeTag(redirects[0]));
}

test "parses a subshell as a pipeline command" {
    var tree = try Ast.parse(std.testing.allocator, "producer | (filter; sink)");
    defer tree.deinit(std.testing.allocator);

    const pipeline = firstCommand(&tree);
    const children = tree.nodeData(pipeline).node_and_node;
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(children[0]));
    try std.testing.expectEqual(Node.Tag.subshell, tree.nodeTag(children[1]));
}

test "requests continuation for an unclosed subshell" {
    var tree = try Ast.parse(std.testing.allocator, "(echo; cat");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .closing_paren);
    try std.testing.expectEqualStrings(
        "(",
        tree.tokenSlice(tree.status.incomplete.closing_paren),
    );
}

test "rejects an empty subshell" {
    var tree = try Ast.parse(std.testing.allocator, "()");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.r_paren, tree.tokenTag(tree.errors[0].token));
}

test "parses if elif else and trailing redirection" {
    const source =
        \\if test -f file; then
        \\  echo file
        \\elif test -d file; then
        \\  echo directory
        \\else
        \\  echo missing
        \\fi >result
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    const if_node = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.if_clause, tree.nodeTag(if_node));
    const clause = tree.ifClause(if_node);
    try std.testing.expect(clause.condition.unwrap() != null);
    try std.testing.expect(clause.then_token.unwrap() != null);
    try std.testing.expect(clause.then_body.unwrap() != null);
    try std.testing.expectEqual(@as(usize, 1), tree.elifBranchCount(clause));
    try std.testing.expect(tree.elifBranch(clause, 0).body.unwrap() != null);
    try std.testing.expect(clause.else_token.unwrap() != null);
    try std.testing.expect(clause.else_body.unwrap() != null);
    try std.testing.expectEqualStrings("fi", tree.tokenSlice(clause.fi_token.unwrap().?));

    const redirects = tree.extraDataSlice(.{
        .start = clause.redirects_start,
        .end = clause.redirects_end,
    }, Node.Index);
    try std.testing.expectEqual(@as(usize, 1), redirects.len);
    try std.testing.expectEqual(Node.Tag.redirect, tree.nodeTag(redirects[0]));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .complete);
}

test "keyword candidates remain words in argument position" {
    var tree = try Ast.parse(std.testing.allocator, "echo if then elif else fi");
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.simpleCommandParts(command);
    try std.testing.expectEqual(@as(usize, 6), parts.len);
    for (parts) |part| {
        try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(part));
    }
}

test "quoted if remains a simple command word" {
    var tree = try Ast.parse(std.testing.allocator, "'if' true");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(firstCommand(&tree)));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "parses nested if clauses" {
    const source =
        \\if outer; then
        \\  if inner; then
        \\    echo nested
        \\  fi
        \\fi
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    const outer = tree.ifClause(firstCommand(&tree));
    const outer_body = outer.then_body.unwrap().?;
    const inner = tree.listItem(outer_body, 0).command;
    try std.testing.expectEqual(Node.Tag.if_clause, tree.nodeTag(inner));
    try std.testing.expect(tree.ifClause(inner).fi_token.unwrap() != null);
}

test "reports each incomplete if stage" {
    try expectCompoundContinuation(
        "if",
        .if_clause,
        .condition,
    );
    try expectCompoundContinuation(
        "if true",
        .if_clause,
        .then_keyword,
    );
    try expectCompoundContinuation(
        "if true; then",
        .if_clause,
        .body,
    );
    try expectCompoundContinuation(
        "if true; then echo yes",
        .if_clause,
        .fi_keyword,
    );
    try expectCompoundContinuation(
        "if true; then echo yes; elif",
        .elif_clause,
        .condition,
    );
    try expectCompoundContinuation(
        "if true; then echo yes; else",
        .else_clause,
        .body,
    );
}

test "rejects a reserved word at command start" {
    var tree = try Ast.parse(std.testing.allocator, "then");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.keyword_then, tree.tokenTag(tree.errors[0].token));
}

fn expectCompoundContinuation(
    source: [:0]const u8,
    kind: Ast.CompoundContinuation.Kind,
    expected: Ast.CompoundContinuation.Expected,
) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .compound);
    try std.testing.expectEqual(kind, tree.status.incomplete.compound.kind);
    try std.testing.expectEqual(expected, tree.status.incomplete.compound.expected);
}
