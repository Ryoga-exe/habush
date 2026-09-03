//! In-progress parser state. Converted to an `Ast` after parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parse = @This();

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
tok_i: Ast.TokenIndex = 0,
errors: std.ArrayList(Ast.Error) = .empty,
nodes: Ast.NodeList = .empty,
extra_data: std.ArrayList(u32) = .empty,
scratch: std.ArrayList(Node.Index) = .empty,

pub fn parse(gpa: Allocator, source: [:0]const u8) Ast.ParseError!Ast {
    if (source.len > std.math.maxInt(Ast.ByteOffset)) return error.SourceTooLarge;

    var tokens: Ast.TokenList = .empty;
    defer tokens.deinit(gpa);

    var errors: std.ArrayList(Ast.Error) = .empty;
    defer errors.deinit(gpa);

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
            .invalid,
            .unterminated_single_quote,
            .unterminated_double_quote,
            .unterminated_escape,
            => try errors.append(gpa, .{
                .tag = .invalid_token,
                .token = token_index,
            }),
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
    };
    errors = .empty;
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);

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
    };
}

fn parseRoot(parser: *Parse) Ast.ParseError!void {
    try parser.nodes.append(parser.gpa, .{
        .tag = .root,
        .main_token = 0,
        .data = .{ .opt_node = .none },
    });

    // Lexical errors already identify the offending token. Syntax parsing is
    // deferred until the input can be tokenized without loss.
    if (parser.errors.items.len != 0) return;

    parser.skipNewlines();
    if (parser.tokenTag(parser.tok_i) == .eof) return;

    if (!parser.canStartSimpleCommand()) {
        try parser.warn(.{
            .tag = .expected_command,
            .token = parser.tok_i,
        });
        return;
    }

    const errors_before_command = parser.errors.items.len;
    const command = try parser.parseAndOr();

    var separator: Node.OptionalTokenIndex = .none;
    if (parser.tokenTag(parser.tok_i) == .newline) {
        separator = Node.OptionalTokenIndex.fromOptional(parser.nextToken());
        parser.skipNewlines();
    }

    if (parser.tokenTag(parser.tok_i) != .eof and parser.errors.items.len == errors_before_command) {
        try parser.warn(.{
            .tag = .unexpected_token,
            .token = parser.tok_i,
        });
    }

    const list_start = try parser.addListItem(.{
        .command = command,
        .separator = separator,
    });
    const list_end_value = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    const list_end: Ast.ExtraIndex = @enumFromInt(list_end_value);
    const list = try parser.addNode(.{
        .tag = .list,
        .main_token = parser.nodeMainToken(command),
        .data = .{ .extra_range = .{
            .start = list_start,
            .end = list_end,
        } },
    });

    parser.nodes.set(@intFromEnum(Node.Index.root), .{
        .tag = .root,
        .main_token = parser.nodeMainToken(list),
        .data = .{ .opt_node = list.toOptional() },
    });
}

fn parseAndOr(parser: *Parse) Ast.ParseError!Node.Index {
    var lhs = try parser.parsePipeline();

    while (isAndOr(parser.tokenTag(parser.tok_i))) {
        const operator = parser.nextToken();
        parser.skipNewlines();

        if (!parser.canStartSimpleCommand()) {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
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
    var lhs = try parser.parseSimpleCommand();

    while (isPipe(parser.tokenTag(parser.tok_i))) {
        const operator = parser.nextToken();
        parser.skipNewlines();

        if (!parser.canStartSimpleCommand()) {
            try parser.warn(.{
                .tag = .expected_command,
                .token = parser.tok_i,
            });
            return lhs;
        }

        const rhs = try parser.parseSimpleCommand();
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
        try parser.warn(.{
            .tag = .expected_redirect_target,
            .token = target,
        });
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

fn addListItem(
    parser: *Parse,
    item: Node.ListItem,
) Ast.ParseError!Ast.ExtraIndex {
    const start = std.math.cast(u32, parser.extra_data.items.len) orelse
        return error.SourceTooLarge;
    try parser.extra_data.append(parser.gpa, @intFromEnum(item.command));
    try parser.extra_data.append(parser.gpa, @intFromEnum(item.separator));
    return @enumFromInt(start);
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

fn canStartSimpleCommand(parser: *const Parse) bool {
    return isWord(parser.tokenTag(parser.tok_i)) or parser.startsRedirect();
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
    return tag == .word or tag == .digits;
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

test "preserves a tokenizer issue as an AST error" {
    var tree = try Ast.parse(std.testing.allocator, "echo 'open");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.invalid_token, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.unterminated_single_quote, tree.tokenTag(tree.errors[0].token));
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

test "records a missing redirection target" {
    var tree = try Ast.parse(std.testing.allocator, "echo >");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_redirect_target, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tree.tokenTag(tree.errors[0].token));
}

fn firstCommand(tree: *const Ast) Node.Index {
    const list = tree.nodeData(.root).opt_node.unwrap().?;
    const range = tree.nodeData(list).extra_range;
    return tree.extraData(range.start, Node.ListItem).command;
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

test "records a missing pipeline command once" {
    var tree = try Ast.parse(std.testing.allocator, "echo hi |");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tree.tokenTag(tree.errors[0].token));
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

test "records a missing and-or command once" {
    var tree = try Ast.parse(std.testing.allocator, "first ||");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tree.tokenTag(tree.errors[0].token));
}
