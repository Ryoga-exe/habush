//! In-progress parser state. Converted to an `Ast` after parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const heredoc = @import("heredoc.zig");
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

const LoopBuilder = struct {
    condition: Node.OptionalIndex = .none,
    do_token: Node.OptionalTokenIndex = .none,
    body: Node.OptionalIndex = .none,
    done_token: Node.OptionalTokenIndex = .none,
    redirects: ?Node.SubRange = null,
};

const HereDocumentBuilder = struct {
    index: Ast.HereDocumentIndex,
    delimiter_start: u32,
    delimiter_end: u32,
    strip_tabs: bool,
    expand_body: bool,
    body: ?[]const u8,
};

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
tok_i: Ast.TokenIndex = 0,
errors: std.ArrayList(Ast.Error) = .empty,
status: Ast.Status = .complete,
nodes: Ast.NodeList = .empty,
extra_data: std.ArrayList(u32) = .empty,
here_documents: Ast.HereDocumentList = .empty,
here_document_data: std.ArrayList(u8) = .empty,
ready_here_document_count: u32 = 0,
collected_here_documents: []const heredoc.Collected,
scratch: std.ArrayList(Node.Index) = .empty,
list_scratch: std.ArrayList(Node.ListItem) = .empty,
elif_scratch: std.ArrayList(Node.ElifBranch) = .empty,

pub fn parse(gpa: Allocator, source: [:0]const u8) Ast.ParseError!Ast {
    return parseWithOptions(gpa, source, .{});
}

pub fn parseWithOptions(
    gpa: Allocator,
    source: [:0]const u8,
    options: Ast.ParseOptions,
) Ast.ParseError!Ast {
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
        .collected_here_documents = options.collected_here_documents,
    };
    errors = .empty;
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.here_documents.deinit(gpa);
    defer parser.here_document_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);
    defer parser.list_scratch.deinit(gpa);
    defer parser.elif_scratch.deinit(gpa);

    try parser.parseRoot();

    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    var here_documents = parser.here_documents.toOwnedSlice();
    errdefer here_documents.deinit(gpa);
    const here_document_data = try parser.here_document_data.toOwnedSlice(gpa);
    errdefer gpa.free(here_document_data);
    const parse_errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(parse_errors);

    return .{
        .source = source,
        .tokens = token_slice,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .here_documents = here_documents,
        .here_document_data = here_document_data,
        .ready_here_document_count = parser.ready_here_document_count,
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
                separator = Node.OptionalTokenIndex.fromOptional(parser.consumeNewline());
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
        .keyword_while => parser.parseLoopClause(.while_clause),
        .keyword_until => parser.parseLoopClause(.until_clause),
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

fn parseLoopClause(
    parser: *Parse,
    node_tag: Node.Tag,
) Ast.ParseError!Node.Index {
    const kind: Ast.CompoundContinuation.Kind = switch (node_tag) {
        .while_clause => .while_clause,
        .until_clause => .until_clause,
        else => unreachable,
    };
    const open_token = parser.nextToken();
    var builder: LoopBuilder = .{};

    parser.skipNewlines();
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(kind, .condition, open_token);
        return parser.finishLoop(node_tag, open_token, builder);
    }

    const condition_errors = parser.errors.items.len;
    const condition = try parser.parseList(.{
        .reserved_words = &.{.keyword_do},
    });
    if (condition) |node| {
        builder.condition = node.toOptional();
    } else {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return parser.finishLoop(node_tag, open_token, builder);
    }
    if (parser.failedSince(condition_errors)) {
        return parser.finishLoop(node_tag, open_token, builder);
    }
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(kind, .do_keyword, open_token);
        return parser.finishLoop(node_tag, open_token, builder);
    }
    if (parser.tokenTag(parser.tok_i) != .keyword_do) {
        try parser.warn(.{
            .tag = .expected_do_keyword,
            .token = parser.tok_i,
        });
        return parser.finishLoop(node_tag, open_token, builder);
    }

    const do_token = parser.nextToken();
    builder.do_token = Node.OptionalTokenIndex.fromOptional(do_token);
    parser.skipNewlines();
    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(kind, .body, do_token);
        return parser.finishLoop(node_tag, open_token, builder);
    }

    const body_errors = parser.errors.items.len;
    const body = try parser.parseList(.{
        .reserved_words = &.{.keyword_done},
    });
    if (body) |node| {
        builder.body = node.toOptional();
    } else {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return parser.finishLoop(node_tag, open_token, builder);
    }
    if (parser.failedSince(body_errors)) {
        return parser.finishLoop(node_tag, open_token, builder);
    }

    if (parser.tokenTag(parser.tok_i) == .eof) {
        parser.setCompoundIncomplete(kind, .done_keyword, open_token);
        return parser.finishLoop(node_tag, open_token, builder);
    }
    if (parser.tokenTag(parser.tok_i) != .keyword_done) {
        try parser.warn(.{
            .tag = .expected_done_keyword,
            .token = parser.tok_i,
        });
        return parser.finishLoop(node_tag, open_token, builder);
    }
    builder.done_token = Node.OptionalTokenIndex.fromOptional(parser.nextToken());

    const redirect_start = parser.scratch.items.len;
    defer parser.scratch.shrinkRetainingCapacity(redirect_start);
    while (parser.startsRedirect()) {
        try parser.scratch.append(parser.gpa, try parser.parseRedirect());
    }
    builder.redirects = try parser.listToSpan(parser.scratch.items[redirect_start..]);

    return parser.finishLoop(node_tag, open_token, builder);
}

fn finishLoop(
    parser: *Parse,
    node_tag: Node.Tag,
    open_token: Ast.TokenIndex,
    builder: LoopBuilder,
) Ast.ParseError!Node.Index {
    const redirects = builder.redirects orelse try parser.emptySpan();
    const extra = try parser.addExtra(Node.Loop{
        .condition = builder.condition,
        .do_token = builder.do_token,
        .body = builder.body,
        .done_token = builder.done_token,
        .redirects_start = redirects.start,
        .redirects_end = redirects.end,
    });
    return parser.addNode(.{
        .tag = node_tag,
        .main_token = open_token,
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
    const has_target = isWord(parser.tokenTag(target));
    if (!has_target) {
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

    const document = if (has_target and isHereDocument(parser.tokenTag(operator)))
        try parser.prepareHereDocument(operator, target)
    else
        null;
    const redirect_extra = try parser.addExtra(Node.Redirect{
        .io_number = io_number,
        .target = target,
        .here_document = if (document) |value| value.index.toOptional() else .none,
    });
    const redirect = try parser.addNode(.{
        .tag = .redirect,
        .main_token = operator,
        .data = .{ .extra = redirect_extra },
    });
    if (document) |value| {
        try parser.here_documents.append(parser.gpa, .{
            .redirect = redirect,
            .delimiter_start = value.delimiter_start,
            .delimiter_end = value.delimiter_end,
            .strip_tabs = value.strip_tabs,
            .expand_body = value.expand_body,
            .body = value.body,
        });
    }
    return redirect;
}

fn prepareHereDocument(
    parser: *Parse,
    operator: Ast.TokenIndex,
    target: Ast.TokenIndex,
) Ast.ParseError!HereDocumentBuilder {
    var delimiter = try heredoc.decodeDelimiter(parser.gpa, parser.rawTokenSlice(target));
    defer delimiter.deinit(parser.gpa);

    const document_index = std.math.cast(u32, parser.here_documents.len) orelse
        return error.SourceTooLarge;
    const delimiter_start = std.math.cast(u32, parser.here_document_data.items.len) orelse
        return error.SourceTooLarge;
    try parser.here_document_data.appendSlice(parser.gpa, delimiter.text);
    const delimiter_end = std.math.cast(u32, parser.here_document_data.items.len) orelse
        return error.SourceTooLarge;

    const strip_tabs = parser.tokenTag(operator) == .lt_lt_minus;
    const expand_body = !delimiter.quoted;
    var body: ?[]const u8 = null;
    if (document_index < parser.collected_here_documents.len) {
        const collected = parser.collected_here_documents[document_index];
        if (!std.mem.eql(u8, delimiter.text, collected.delimiter) or
            strip_tabs != collected.strip_tabs or
            expand_body != collected.expand_body)
        {
            try parser.warn(.{
                .tag = .here_document_mismatch,
                .token = target,
            });
        } else {
            body = collected.body;
        }
    }

    return .{
        .index = @enumFromInt(document_index),
        .delimiter_start = delimiter_start,
        .delimiter_end = delimiter_end,
        .strip_tabs = strip_tabs,
        .expand_body = expand_body,
        .body = body,
    };
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
            Ast.HereDocumentIndex.Optional,
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
    while (parser.tokenTag(parser.tok_i) == .newline) _ = parser.consumeNewline();
}

fn consumeNewline(parser: *Parse) Ast.TokenIndex {
    const newline = parser.nextToken();
    parser.ready_here_document_count = @intCast(parser.here_documents.len);
    return newline;
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
    if (isReservedWord(tag)) {
        return tag == .keyword_if or tag == .keyword_while or tag == .keyword_until;
    }
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

fn rawTokenSlice(parser: *const Parse, token_index: Ast.TokenIndex) []const u8 {
    const start = parser.tokens.items(.start)[token_index];
    return parser.source[start..parser.tokenEnd(token_index)];
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
        .keyword_while,
        .keyword_until,
        .keyword_do,
        .keyword_done,
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

fn isHereDocument(tag: Token.Tag) bool {
    return tag == .lt_lt or tag == .lt_lt_minus;
}

fn supportsIoNumber(tag: Token.Tag) bool {
    return isRedirect(tag) and tag != .ampersand_gt and tag != .ampersand_gt_gt;
}

test {
    _ = @import("parser_test.zig");
}
