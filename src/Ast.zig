//! Abstract Syntax Tree for habush source.
//!
//! This follows the shape of `std.zig.Ast`: tokens and nodes are stored in
//! `MultiArrayList` collections, nodes refer to one another by index, and
//! variable-length relationships are encoded in `extra_data`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @This();
const Parse = @import("Parse.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;

/// Reference to externally-owned data.
source: [:0]const u8,

tokens: TokenList.Slice,
nodes: NodeList.Slice,
extra_data: []u32,
errors: []const Error,
status: Status,

pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const TokenIndex = u32;
pub const ParseError = Allocator.Error || error{SourceTooLarge};

pub const Status = union(enum) {
    complete,
    incomplete: Continuation,
};

pub const Continuation = union(enum) {
    lexical: TokenIndex,
    command_after: TokenIndex,
    redirect_target: TokenIndex,
    closing_paren: TokenIndex,
};

/// Index into `extra_data`.
pub const ExtraIndex = enum(u32) {
    _,
};

pub const Error = struct {
    tag: Tag,
    token: TokenIndex,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
    } = .{ .none = {} },

    pub const Tag = enum {
        invalid_token,
        unexpected_token,
        expected_token,
        expected_command,
        expected_redirect_target,
    };
};

pub fn parse(allocator: Allocator, source_bytes: [:0]const u8) ParseError!Ast {
    return Parse.parse(allocator, source_bytes);
}

pub fn deinit(tree: *Ast, allocator: Allocator) void {
    tree.tokens.deinit(allocator);
    tree.nodes.deinit(allocator);
    allocator.free(tree.extra_data);
    allocator.free(tree.errors);
    tree.* = undefined;
}

pub fn tokenTag(tree: *const Ast, index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[index];
}

pub fn tokenStart(tree: *const Ast, index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[index];
}

pub fn tokenSlice(tree: *const Ast, index: TokenIndex) []const u8 {
    const tag = tree.tokenTag(index);
    if (Token.lexeme(tag)) |lexeme| return lexeme;

    var scanner: tokenizer.Tokenizer = .{
        .buffer = tree.source,
        .index = tree.tokenStart(index),
    };
    const token = scanner.next();
    std.debug.assert(token.tag == tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn nodeTag(tree: *const Ast, index: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@intFromEnum(index)];
}

pub fn nodeMainToken(tree: *const Ast, index: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@intFromEnum(index)];
}

pub fn nodeData(tree: *const Ast, index: Node.Index) Node.Data {
    return tree.nodes.items(.data)[@intFromEnum(index)];
}

pub fn simpleCommandParts(tree: *const Ast, index: Node.Index) []const Node.Index {
    std.debug.assert(tree.nodeTag(index) == .simple_command);
    return tree.extraDataSlice(tree.nodeData(index).extra_range, Node.Index);
}

pub fn listItemCount(tree: *const Ast, index: Node.Index) usize {
    std.debug.assert(tree.nodeTag(index) == .list);
    const range = tree.nodeData(index).extra_range;
    const raw_len = @intFromEnum(range.end) - @intFromEnum(range.start);
    const width = std.meta.fields(Node.ListItem).len;
    std.debug.assert(raw_len % width == 0);
    return raw_len / width;
}

pub fn listItem(tree: *const Ast, index: Node.Index, item_index: usize) Node.ListItem {
    std.debug.assert(item_index < tree.listItemCount(index));
    const range = tree.nodeData(index).extra_range;
    const width = std.meta.fields(Node.ListItem).len;
    const offset = @intFromEnum(range.start) + item_index * width;
    return tree.extraData(@enumFromInt(offset), Node.ListItem);
}

pub fn subshell(tree: *const Ast, index: Node.Index) Node.Subshell {
    std.debug.assert(tree.nodeTag(index) == .subshell);
    return tree.extraData(tree.nodeData(index).extra, Node.Subshell);
}

pub fn extraDataSlice(
    tree: *const Ast,
    range: Node.SubRange,
    comptime T: type,
) []const T {
    comptime std.debug.assert(@sizeOf(T) == @sizeOf(u32));
    return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn extraData(tree: *const Ast, index: ExtraIndex, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields, 0..) |field, offset| {
        @field(result, field.name) = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            Node.OptionalTokenIndex,
            ExtraIndex,
            => @enumFromInt(tree.extra_data[@intFromEnum(index) + offset]),
            TokenIndex => tree.extra_data[@intFromEnum(index) + offset],
            else => @compileError("unexpected extra_data field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(index: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(index));
            std.debug.assert(result != .none);
            return result;
        }
    };

    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(index: OptionalIndex) ?Index {
            return if (index == .none) null else @enumFromInt(@intFromEnum(index));
        }

        pub fn fromOptional(index: ?Index) OptionalIndex {
            return if (index) |value| value.toOptional() else .none;
        }
    };

    pub const OptionalTokenIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(index: OptionalTokenIndex) ?TokenIndex {
            return if (index == .none) null else @intFromEnum(index);
        }

        pub fn fromOptional(index: ?TokenIndex) OptionalTokenIndex {
            return if (index) |value| @enumFromInt(value) else .none;
        }
    };

    /// The interpretation of `data` is determined by the node tag.
    pub const Tag = enum(u8) {
        /// `data.opt_node`: the top-level command list, if any.
        root,

        /// `data.extra_range`: encoded `ListItem` values.
        list,

        /// `data.node_and_node`: left- and right-hand command nodes.
        and_if,
        or_if,
        pipe,
        pipe_and,

        /// `data.extra_range`: `Node.Index` values in source order.
        simple_command,

        /// `data.extra`: encoded `Subshell` data.
        subshell,

        /// `main_token` identifies the word; `data.none`.
        word,

        /// `main_token` identifies the operator;
        /// `data.opt_token_and_token` stores the optional I/O number and target.
        redirect,
    };

    pub const Data = union {
        none: void,
        opt_node: OptionalIndex,
        node_and_node: struct { Index, Index },
        extra: ExtraIndex,
        extra_range: SubRange,
        opt_token_and_token: struct { OptionalTokenIndex, TokenIndex },
    };

    pub const SubRange = struct {
        start: ExtraIndex,
        end: ExtraIndex,
    };

    pub const ListItem = struct {
        command: Index,
        separator: OptionalTokenIndex,
    };

    pub const Subshell = struct {
        body: OptionalIndex,
        close_token: TokenIndex,
        redirects_start: ExtraIndex,
        redirects_end: ExtraIndex,
    };
};

test "MultiArrayList stores node fields and index relationships" {
    const allocator = std.testing.allocator;

    var tokens: TokenList = .empty;
    errdefer tokens.deinit(allocator);
    try tokens.append(allocator, .{
        .tag = .word,
        .start = 0,
    });
    try tokens.append(allocator, .{
        .tag = .eof,
        .start = 4,
    });

    var nodes: NodeList = .empty;
    errdefer nodes.deinit(allocator);
    try nodes.append(allocator, .{
        .tag = .root,
        .main_token = 0,
        .data = .{ .opt_node = @as(Node.Index, @enumFromInt(1)).toOptional() },
    });
    try nodes.append(allocator, .{
        .tag = .word,
        .main_token = 0,
        .data = .{ .none = {} },
    });

    const extra_data = try allocator.alloc(u32, 0);
    errdefer allocator.free(extra_data);
    const errors = try allocator.alloc(Error, 0);
    errdefer allocator.free(errors);

    var tree: Ast = .{
        .source = "echo",
        .tokens = tokens.toOwnedSlice(),
        .nodes = nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = errors,
        .status = .complete,
    };
    defer tree.deinit(allocator);

    try std.testing.expectEqual(Node.Tag.root, tree.nodeTag(.root));
    try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(@enumFromInt(1)));

    const root_data = tree.nodeData(.root);
    try std.testing.expectEqual(@as(Node.Index, @enumFromInt(1)), root_data.opt_node.unwrap().?);
    try std.testing.expectEqual(Token.Tag.word, tree.tokenTag(0));
    try std.testing.expectEqual(@as(ByteOffset, 0), tree.tokenStart(0));
    try std.testing.expectEqualStrings("echo", tree.tokenSlice(0));
}
