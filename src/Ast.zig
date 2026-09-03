//! Abstract Syntax Tree for habush source.
//!
//! This follows the shape of `std.zig.Ast`: tokens and nodes are stored in
//! `MultiArrayList` collections, nodes refer to one another by index, and
//! variable-length relationships are encoded in `extra_data`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Ast = @This();
const Parse = @import("Parse.zig");
const debug = @import("Ast/debug.zig");
const heredoc = @import("heredoc.zig");
const tokenizer = @import("tokenizer.zig");
const word = @import("word.zig");
const Token = tokenizer.Token;

/// Reference to externally-owned data.
source: [:0]const u8,

tokens: TokenList.Slice,
nodes: NodeList.Slice,
extra_data: []u32,
word_parts: WordPartList.Slice,
here_documents: HereDocumentList.Slice,
here_document_data: []u8,
ready_here_document_count: u32,
errors: []const Error,
status: Status,

pub const ByteOffset = u32;

pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);
pub const WordPartList = std.MultiArrayList(word.Part);
pub const HereDocumentList = std.MultiArrayList(struct {
    redirect: Node.Index,
    delimiter_start: u32,
    delimiter_end: u32,
    strip_tabs: bool,
    expand_body: bool,
    body: ?[]const u8,
});

pub const TokenIndex = u32;
pub const ParseError = Allocator.Error || error{SourceTooLarge};
pub const WordPart = word.Part;

pub const WordPartIndex = enum(u32) {
    _,
};

pub const WordPartRange = struct {
    start: WordPartIndex,
    end: WordPartIndex,
};
pub const ParseOptions = struct {
    /// The AST borrows the bodies for its lifetime.
    collected_here_documents: []const heredoc.Collected = &.{},
};

pub const HereDocumentIndex = enum(u32) {
    _,

    pub fn toOptional(index: HereDocumentIndex) Optional {
        const result: Optional = @enumFromInt(@intFromEnum(index));
        std.debug.assert(result != .none);
        return result;
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(index: Optional) ?HereDocumentIndex {
            return if (index == .none) null else @enumFromInt(@intFromEnum(index));
        }
    };
};

pub const HereDocument = struct {
    redirect: Node.Index,
    delimiter: []const u8,
    strip_tabs: bool,
    expand_body: bool,
    body: ?[]const u8,
};

pub const Status = union(enum) {
    complete,
    incomplete: Continuation,
};

pub const Continuation = union(enum) {
    lexical: TokenIndex,
    command_after: TokenIndex,
    redirect_target: TokenIndex,
    closing_paren: TokenIndex,
    closing_brace: TokenIndex,
    compound: CompoundContinuation,
};

pub const CompoundContinuation = struct {
    kind: Kind,
    expected: Expected,
    opened_by: TokenIndex,

    pub const Kind = enum {
        if_clause,
        elif_clause,
        else_clause,
        while_clause,
        until_clause,
        for_clause,
    };

    pub const Expected = enum {
        condition,
        name,
        then_keyword,
        in_or_do_keyword,
        do_keyword,
        body,
        fi_keyword,
        done_keyword,
    };
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
        expected_separator,
        expected_then_keyword,
        expected_fi_keyword,
        expected_do_keyword,
        expected_done_keyword,
        expected_name,
        here_document_mismatch,
    };
};

pub fn parse(allocator: Allocator, source_bytes: [:0]const u8) ParseError!Ast {
    return Parse.parse(allocator, source_bytes);
}

pub fn parseWithOptions(
    allocator: Allocator,
    source_bytes: [:0]const u8,
    options: ParseOptions,
) ParseError!Ast {
    return Parse.parseWithOptions(allocator, source_bytes, options);
}

pub fn deinit(tree: *Ast, allocator: Allocator) void {
    tree.tokens.deinit(allocator);
    tree.nodes.deinit(allocator);
    allocator.free(tree.extra_data);
    tree.word_parts.deinit(allocator);
    tree.here_documents.deinit(allocator);
    allocator.free(tree.here_document_data);
    allocator.free(tree.errors);
    tree.* = undefined;
}

pub fn tokenTag(tree: *const Ast, index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[index];
}

pub fn tokenStart(tree: *const Ast, index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[index];
}

pub fn tokenLocation(
    tree: *const Ast,
    start_offset: ByteOffset,
    token_index: TokenIndex,
) Location {
    var location: Location = .{
        .line = 0,
        .column = 0,
        .line_start = start_offset,
        .line_end = tree.source.len,
    };
    const token_start = tree.tokenStart(token_index);

    while (std.mem.findScalarPos(u8, tree.source, location.line_start, '\n')) |newline| {
        if (newline >= token_start) break;
        location.line += 1;
        location.line_start = newline + 1;
    }

    const line_start = location.line_start;
    for (tree.source[line_start..], 0..) |byte, offset| {
        const source_index = line_start + offset;
        if (source_index == token_start) {
            location.line_end = source_index;
            while (location.line_end < tree.source.len and
                tree.source[location.line_end] != '\n')
            {
                location.line_end += 1;
            }
            return location;
        }
        if (byte == '\n') {
            location.line += 1;
            location.column = 0;
            location.line_start = source_index + 1;
        } else {
            location.column += 1;
        }
    }
    return location;
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

pub fn renderError(tree: *const Ast, parse_error: Error, writer: *Writer) Writer.Error!void {
    const found = Token.symbol(tree.tokenTag(parse_error.token));
    return switch (parse_error.tag) {
        .invalid_token => writer.print("invalid token '{s}'", .{tree.tokenSlice(parse_error.token)}),
        .unexpected_token => writer.print("unexpected token '{s}'", .{found}),
        .expected_token => writer.print("expected '{s}', found '{s}'", .{
            Token.symbol(parse_error.extra.expected_tag),
            found,
        }),
        .expected_command => writer.print("expected command, found '{s}'", .{found}),
        .expected_redirect_target => writer.print(
            "expected redirection target, found '{s}'",
            .{found},
        ),
        .expected_separator => writer.print(
            "expected ';' or newline before '{s}'",
            .{found},
        ),
        .expected_then_keyword => writer.print("expected 'then', found '{s}'", .{found}),
        .expected_fi_keyword => writer.print("expected 'fi', found '{s}'", .{found}),
        .expected_do_keyword => writer.print("expected 'do', found '{s}'", .{found}),
        .expected_done_keyword => writer.print("expected 'done', found '{s}'", .{found}),
        .expected_name => writer.print("expected a name, found '{s}'", .{found}),
        .here_document_mismatch => writer.writeAll(
            "collected here-document does not match its parsed delimiter",
        ),
    };
}

pub fn dump(tree: *const Ast, writer: *Writer) Writer.Error!void {
    return debug.render(tree, writer);
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

pub fn wordPartCount(tree: *const Ast, index: Node.Index) usize {
    const range = tree.wordPartRange(index);
    return @intFromEnum(range.end) - @intFromEnum(range.start);
}

pub fn wordPart(tree: *const Ast, index: Node.Index, part_index: usize) WordPart {
    std.debug.assert(part_index < tree.wordPartCount(index));
    const range = tree.wordPartRange(index);
    const absolute_index = @intFromEnum(range.start) + part_index;
    return .{
        .tag = tree.word_parts.items(.tag)[absolute_index],
        .start = tree.word_parts.items(.start)[absolute_index],
        .end = tree.word_parts.items(.end)[absolute_index],
    };
}

pub fn assignment(tree: *const Ast, index: Node.Index) Node.Assignment {
    std.debug.assert(tree.nodeTag(index) == .assignment);
    return tree.extraData(tree.nodeData(index).extra, Node.Assignment);
}

pub fn assignmentName(tree: *const Ast, index: Node.Index) []const u8 {
    const info = tree.assignment(index);
    return tree.source[tree.tokenStart(tree.nodeMainToken(index))..info.name_end];
}

fn wordPartRange(tree: *const Ast, index: Node.Index) WordPartRange {
    return switch (tree.nodeTag(index)) {
        .word => tree.nodeData(index).word_parts,
        .assignment => blk: {
            const info = tree.assignment(index);
            break :blk .{
                .start = info.value_start,
                .end = info.value_end,
            };
        },
        else => unreachable,
    };
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

pub fn braceGroup(tree: *const Ast, index: Node.Index) Node.BraceGroup {
    std.debug.assert(tree.nodeTag(index) == .brace_group);
    return tree.extraData(tree.nodeData(index).extra, Node.BraceGroup);
}

pub fn negatedPipeline(tree: *const Ast, index: Node.Index) ?Node.Index {
    std.debug.assert(tree.nodeTag(index) == .negated_pipeline);
    return tree.nodeData(index).opt_node.unwrap();
}

pub fn ifClause(tree: *const Ast, index: Node.Index) Node.If {
    std.debug.assert(tree.nodeTag(index) == .if_clause);
    return tree.extraData(tree.nodeData(index).extra, Node.If);
}

pub fn loopClause(tree: *const Ast, index: Node.Index) Node.Loop {
    const tag = tree.nodeTag(index);
    std.debug.assert(tag == .while_clause or tag == .until_clause);
    return tree.extraData(tree.nodeData(index).extra, Node.Loop);
}

pub fn forClause(tree: *const Ast, index: Node.Index) Node.For {
    std.debug.assert(tree.nodeTag(index) == .for_clause);
    return tree.extraData(tree.nodeData(index).extra, Node.For);
}

pub fn forWords(tree: *const Ast, clause: Node.For) []const Node.Index {
    return tree.extraDataSlice(.{
        .start = clause.words_start,
        .end = clause.words_end,
    }, Node.Index);
}

pub fn redirect(tree: *const Ast, index: Node.Index) Node.Redirect {
    std.debug.assert(tree.nodeTag(index) == .redirect);
    return tree.extraData(tree.nodeData(index).extra, Node.Redirect);
}

pub fn hereDocument(tree: *const Ast, index: HereDocumentIndex) HereDocument {
    const item_index = @intFromEnum(index);
    std.debug.assert(item_index < tree.here_documents.len);

    const starts = tree.here_documents.items(.delimiter_start);
    const ends = tree.here_documents.items(.delimiter_end);
    return .{
        .redirect = tree.here_documents.items(.redirect)[item_index],
        .delimiter = tree.here_document_data[starts[item_index]..ends[item_index]],
        .strip_tabs = tree.here_documents.items(.strip_tabs)[item_index],
        .expand_body = tree.here_documents.items(.expand_body)[item_index],
        .body = tree.here_documents.items(.body)[item_index],
    };
}

pub fn elifBranchCount(tree: *const Ast, node: Node.If) usize {
    _ = tree;
    const raw_len = @intFromEnum(node.elif_end) - @intFromEnum(node.elif_start);
    const width = std.meta.fields(Node.ElifBranch).len;
    std.debug.assert(raw_len % width == 0);
    return raw_len / width;
}

pub fn elifBranch(tree: *const Ast, node: Node.If, index: usize) Node.ElifBranch {
    std.debug.assert(index < tree.elifBranchCount(node));
    const width = std.meta.fields(Node.ElifBranch).len;
    const offset = @intFromEnum(node.elif_start) + index * width;
    return tree.extraData(@enumFromInt(offset), Node.ElifBranch);
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
            HereDocumentIndex.Optional,
            WordPartIndex,
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

        /// `data.opt_node`: the pipeline following `!`, if present.
        negated_pipeline,

        /// `data.extra_range`: `Node.Index` values in source order.
        simple_command,

        /// `data.extra`: encoded `Subshell` data.
        subshell,

        /// `data.extra`: encoded `BraceGroup` data.
        brace_group,

        /// `data.extra`: encoded `If` data.
        if_clause,

        /// `data.extra`: encoded `Loop` data.
        while_clause,
        until_clause,

        /// `data.extra`: encoded `For` data.
        for_clause,

        /// `main_token` identifies the word; `data.word_parts` indexes its parts.
        word,

        /// `main_token` identifies `NAME=value`; `data.extra` encodes `Assignment`.
        assignment,

        /// `main_token` identifies the operator; `data.extra` encodes `Redirect`.
        redirect,
    };

    pub const Data = union {
        none: void,
        opt_node: OptionalIndex,
        node_and_node: struct { Index, Index },
        extra: ExtraIndex,
        extra_range: SubRange,
        word_parts: WordPartRange,
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

    pub const BraceGroup = struct {
        body: OptionalIndex,
        close_token: TokenIndex,
        redirects_start: ExtraIndex,
        redirects_end: ExtraIndex,
    };

    pub const If = struct {
        condition: OptionalIndex,
        then_token: OptionalTokenIndex,
        then_body: OptionalIndex,
        elif_start: ExtraIndex,
        elif_end: ExtraIndex,
        else_token: OptionalTokenIndex,
        else_body: OptionalIndex,
        fi_token: OptionalTokenIndex,
        redirects_start: ExtraIndex,
        redirects_end: ExtraIndex,
    };

    pub const ElifBranch = struct {
        elif_token: TokenIndex,
        condition: OptionalIndex,
        then_token: OptionalTokenIndex,
        body: OptionalIndex,
    };

    pub const Loop = struct {
        condition: OptionalIndex,
        do_token: OptionalTokenIndex,
        body: OptionalIndex,
        done_token: OptionalTokenIndex,
        redirects_start: ExtraIndex,
        redirects_end: ExtraIndex,
    };

    pub const For = struct {
        name_token: OptionalTokenIndex,
        in_token: OptionalTokenIndex,
        words_start: ExtraIndex,
        words_end: ExtraIndex,
        separator_token: OptionalTokenIndex,
        do_token: OptionalTokenIndex,
        body: OptionalIndex,
        done_token: OptionalTokenIndex,
        redirects_start: ExtraIndex,
        redirects_end: ExtraIndex,
    };

    pub const Redirect = struct {
        io_number: OptionalTokenIndex,
        target: OptionalIndex,
        here_document: HereDocumentIndex.Optional,
    };

    pub const Assignment = struct {
        name_end: ByteOffset,
        value_start: WordPartIndex,
        value_end: WordPartIndex,
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
    var here_documents: HereDocumentList = .empty;
    errdefer here_documents.deinit(allocator);
    var word_parts: WordPartList = .empty;
    errdefer word_parts.deinit(allocator);
    const here_document_data = try allocator.alloc(u8, 0);
    errdefer allocator.free(here_document_data);

    var tree: Ast = .{
        .source = "echo",
        .tokens = tokens.toOwnedSlice(),
        .nodes = nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .word_parts = word_parts.toOwnedSlice(),
        .here_documents = here_documents.toOwnedSlice(),
        .here_document_data = here_document_data,
        .ready_here_document_count = 0,
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
