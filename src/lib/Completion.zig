//! Pure completion context and literal candidate insertion for the shell language.
//! Inspection never expands words, reads a Session, or invokes a command.
const std = @import("std");
const word_syntax = @import("word.zig");
const Completion = @This();

pub const Provider = @import("Completion/Provider.zig");
pub const Native = @import("Completion/Native.zig");
pub const Registry = @import("Completion/Registry.zig");
pub const Registered = @import("Completion/Registered.zig");

pub const Range = struct { start: usize, end: usize };
pub const Quote = enum { unquoted, single, double };
pub const Kind = enum { command, argument, redirection, parameter, comment };

/// Borrows this exact source revision. Offsets count bytes, including invalid
/// UTF-8. A caller retaining the context must retain or copy its source too.
source: []const u8,
source_hash: u64,
revision: u64,
cursor: usize,
replace: Range,
quote: Quote,
kind: Kind,
dynamic: bool,
command_start: ?usize,

/// Removes literal quoting for candidate matching. Dynamic words are left
/// to richer providers; completion never evaluates their expansions.
pub fn literalPrefix(context: Completion, gpa: std.mem.Allocator) (std.mem.Allocator.Error || error{UnsupportedContext})![]u8 {
    if (context.dynamic or context.kind == .parameter or context.kind == .comment)
        return error.UnsupportedContext;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var quote: Quote = .unquoted;
    var index = context.replace.start;
    while (index < context.cursor) : (index += 1) {
        const byte = context.source[index];
        if (quote == .single) {
            if (byte == '\'') quote = .unquoted else try output.append(gpa, byte);
        } else if (byte == '\\') {
            if (index + 1 == context.cursor) return error.UnsupportedContext;
            const next = context.source[index + 1];
            if (quote == .unquoted or next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                index += 1;
                if (next != '\n') try output.append(gpa, next);
            } else try output.append(gpa, byte);
        } else if (byte == '"') {
            quote = if (quote == .double) .unquoted else .double;
        } else if (quote == .unquoted and byte == '\'') {
            quote = .single;
        } else try output.append(gpa, byte);
    }
    return output.toOwnedSlice(gpa);
}

/// Command and completed argument values before the current word. No expansion
/// is evaluated. All allocations belong to the caller's scratch arena.
pub fn literalArguments(context: Completion, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnsupportedContext})![]const []const u8 {
    const start = context.command_start orelse return error.UnsupportedContext;
    if (start > context.replace.start) return error.UnsupportedContext;
    const source = try arena.dupeSentinel(u8, context.source[start..context.replace.start], 0);
    var tree = @import("Ast.zig").parse(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceTooLarge => return error.UnsupportedContext,
    };
    defer tree.deinit(arena);
    if (tree.errors.len != 0 or tree.status != .complete) return error.UnsupportedContext;
    const list = tree.nodeData(.root).opt_node.unwrap() orelse return error.UnsupportedContext;
    if (tree.listItemCount(list) != 1) return error.UnsupportedContext;
    const command = tree.listItem(list, 0).command;
    if (tree.nodeTag(command) != .simple_command) return error.UnsupportedContext;
    var args: std.ArrayList([]const u8) = .empty;
    for (tree.simpleCommandParts(command)) |part| {
        if (tree.nodeTag(part) != .word) continue;
        const token = tree.nodeMainToken(part);
        const word = tree.tokenSlice(token);
        var word_context = context;
        word_context.source = source;
        word_context.replace = .{ .start = tree.tokenStart(token), .end = tree.tokenStart(token) + word.len };
        word_context.cursor = word_context.replace.end;
        word_context.dynamic = dynamicWord(word);
        try args.append(arena, try word_context.literalPrefix(arena));
    }
    return args.toOwnedSlice(arena);
}

pub const Edit = struct {
    range: Range,
    /// Owned shell source containing exactly one literal word.
    text: []u8,

    pub fn deinit(edit: *Edit, gpa: std.mem.Allocator) void {
        gpa.free(edit.text);
        edit.* = undefined;
    }
};

const Frame = struct {
    quote: Quote = .unquoted,
    word: ?usize = null,
    command: bool = true,
    redirection: bool = false,
    comment: bool = false,
    escaped: bool = false,
    parameter_depth: usize = 0,
    dynamic: bool = false,
    command_start: ?usize = null,
};

pub fn inspect(source: []const u8, cursor: usize, revision: u64) error{ InvalidCursor, InputTooDeep }!Completion {
    if (cursor > source.len) return error.InvalidCursor;
    var frames: [64]Frame = @splat(.{});
    var substitutions: [64]?usize = @splat(null);
    var depth: usize = 0;
    var index: usize = 0;
    while (index < cursor) : (index += 1) {
        const frame = &frames[depth];
        const byte = source[index];
        if (frame.comment) {
            if (byte == '\n') frame.* = .{};
            continue;
        }
        if (frame.escaped) {
            frame.escaped = false;
            continue;
        }
        if (frame.quote == .single) {
            if (byte == '\'') frame.quote = .unquoted;
            continue;
        }
        if (byte == '\\') {
            if (frame.word == null) frame.word = index;
            frame.escaped = true;
            continue;
        }
        if (byte == '$' and index + 1 < cursor and source[index + 1] == '(') {
            if (frame.word == null) frame.word = index;
            frame.dynamic = true;
            if (index + 2 < cursor and source[index + 2] == '(') {
                // Arithmetic expansion is intentionally not interpreted as an
                // inner command, even while its source is incomplete.
                frame.parameter_depth += 1;
                index += 1;
                continue;
            }
            if (depth + 1 == frames.len) return error.InputTooDeep;
            depth += 1;
            frames[depth] = .{};
            substitutions[depth] = index;
            index += 1;
            continue;
        }
        if (byte == '$' or byte == '`') {
            if (frame.word == null) frame.word = index;
            frame.dynamic = true;
            if (byte == '$' and index + 1 < cursor and source[index + 1] == '{') {
                frame.parameter_depth += 1;
                index += 1;
            }
            continue;
        }
        if (frame.parameter_depth != 0) {
            if (byte == '}') frame.parameter_depth -= 1;
            continue;
        }
        if (byte == '"') {
            if (frame.word == null) frame.word = index;
            frame.quote = if (frame.quote == .double) .unquoted else .double;
            continue;
        }
        if (frame.quote == .double) continue;
        if (byte == '\'') {
            if (frame.word == null) frame.word = index;
            frame.quote = .single;
        } else if (byte == '#' and frame.word == null) {
            frame.comment = true;
        } else if (byte == ')') {
            if (depth != 0 and (substitutions[depth] == null or word_syntax.commandSubstitutionEnd(source, substitutions[depth].?) == index)) {
                depth -= 1;
            } else frame.* = .{};
        } else if (byte == '(') {
            finishWord(frame, source, index);
            if (depth + 1 == frames.len) return error.InputTooDeep;
            depth += 1;
            frames[depth] = .{};
            substitutions[depth] = null;
        } else if (byte == '<' or byte == '>') {
            if (frame.word) |start| {
                if (allDigits(source[start..index])) frame.word = null else finishWord(frame, source, index);
            }
            frame.redirection = true;
            frame.dynamic = false;
        } else if (byte == '|' or byte == '&' or byte == ';' or byte == '\n' or byte == '{' or byte == '}') {
            frame.* = .{};
        } else if (std.ascii.isWhitespace(byte)) {
            finishWord(frame, source, index);
        } else if (frame.word == null) frame.word = index;
    }
    const frame = frames[depth];
    const start = frame.word orelse cursor;
    const end = wordEnd(source, start);
    return .{
        .source = source,
        .source_hash = std.hash.Wyhash.hash(0, source),
        .revision = revision,
        .cursor = cursor,
        .replace = .{ .start = start, .end = end },
        .quote = frame.quote,
        .kind = if (frame.comment) .comment else if (frame.parameter_depth != 0) .parameter else if (frame.redirection) .redirection else if (frame.command) .command else .argument,
        .dynamic = frame.dynamic or dynamicWord(source[start..end]),
        .command_start = frame.command_start,
    };
}

/// Rejects stale contexts before constructing an edit. Replacing a complete
/// lexical word lets a literal candidate repair an unfinished quote safely.
pub fn makeEdit(
    gpa: std.mem.Allocator,
    context: Completion,
    source: []const u8,
    revision: u64,
    value: []const u8,
) (std.mem.Allocator.Error || error{ StaleContext, UnsupportedContext, InvalidCandidate })!Edit {
    if (revision != context.revision or !std.mem.eql(u8, source, context.source) or
        std.hash.Wyhash.hash(0, source) != context.source_hash or
        context.replace.start > context.cursor or context.cursor > context.replace.end or
        context.replace.end > source.len) return error.StaleContext;
    if (context.kind == .comment or context.kind == .parameter or context.dynamic) return error.UnsupportedContext;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidCandidate;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.append(gpa, '\'');
    for (value) |byte| {
        if (byte == '\'') try text.appendSlice(gpa, "'\\''") else try text.append(gpa, byte);
    }
    try text.append(gpa, '\'');
    return .{ .range = context.replace, .text = try text.toOwnedSlice(gpa) };
}

fn finishWord(frame: *Frame, source: []const u8, end: usize) void {
    const start = frame.word orelse return;
    const word = source[start..end];
    if (frame.redirection) {
        frame.redirection = false;
    } else if (frame.command and !assignment(word) and !commandKeyword(word)) {
        frame.command = false;
        frame.command_start = start;
    }
    frame.word = null;
    frame.dynamic = false;
}

fn assignment(word: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equal == 0 or (!std.ascii.isAlphabetic(word[0]) and word[0] != '_')) return false;
    for (word[1..equal]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn commandKeyword(word: []const u8) bool {
    for ([_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!" }) |keyword|
        if (std.mem.eql(u8, word, keyword)) return true;
    return false;
}

fn allDigits(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

test "literal arguments use the active command without evaluating expansions" {
    var storage: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    for ([_][]const u8{
        "FOO=bar demo 'a b' 2>out next",
        "echo $(demo 'a b' next",
        "true && demo 'a b' next",
        "case x in x) demo 'a b' next",
        "echo $(case x in x) demo 'a b' next",
    }) |source| {
        const context = try inspect(source, source.len, 1);
        const args = try context.literalArguments(arena);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("demo", args[0]);
        try std.testing.expectEqualStrings("a b", args[1]);
    }
    const source = "demo $secret next";
    const dynamic_context = try inspect(source, source.len, 1);
    try std.testing.expectError(error.UnsupportedContext, dynamic_context.literalArguments(arena));
}

fn wordEnd(source: []const u8, start: usize) usize {
    var quote: Quote = .unquoted;
    var escaped = false;
    var index = start;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote == .single) {
            if (byte == '\'') quote = .unquoted;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '$' and index + 1 < source.len and source[index + 1] == '(') {
            index = word_syntax.commandSubstitutionEnd(source, index) orelse return source.len;
        } else if (byte == '"') {
            quote = if (quote == .double) .unquoted else .double;
        } else if (quote == .unquoted) {
            if (byte == '\'') quote = .single else if (std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, "|&;()<>\n", byte) != null) return index;
        }
    }
    return index;
}

fn dynamicWord(source: []const u8) bool {
    var quote: Quote = .unquoted;
    var escaped = false;
    for (source) |byte| {
        if (escaped) {
            escaped = false;
        } else if (quote == .single) {
            if (byte == '\'') quote = .unquoted;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '$' or byte == '`') {
            return true;
        } else if (byte == '"') {
            quote = if (quote == .double) .unquoted else .double;
        } else if (quote == .unquoted and byte == '\'') quote = .single;
    }
    return false;
}

test "unfinished quoted words and nested commands retain byte context" {
    const quoted = try inspect("echo '日本 f", "echo '日本 f".len, 7);
    try std.testing.expectEqual(Quote.single, quoted.quote);
    try std.testing.expectEqual(Kind.argument, quoted.kind);
    try std.testing.expectEqual(@as(usize, 5), quoted.replace.start);
    const prefix = try quoted.literalPrefix(std.testing.allocator);
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqualStrings("日本 f", prefix);
    const inner = try inspect("echo \"$(ec", "echo \"$(ec".len, 8);
    try std.testing.expectEqual(Kind.command, inner.kind);
    try std.testing.expectEqual(@as(usize, 8), inner.replace.start);
    try std.testing.expectEqual(Quote.unquoted, inner.quote);
    try std.testing.expectEqual(Kind.parameter, (try inspect("echo ${HO", 9, 9)).kind);
    try std.testing.expectEqual(Kind.comment, (try inspect("echo # hi", 9, 9)).kind);
}

test "candidate edits are literal and reject stale input" {
    const source = "echo 'unfin";
    const context = try inspect(source, source.len, 3);
    var edit = try makeEdit(std.testing.allocator, context, source, 3, "a'b $(false);\n");
    defer edit.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("'a'\\''b $(false);\n'", edit.text);
    try std.testing.expectEqual(Range{ .start = 5, .end = source.len }, edit.range);
    try std.testing.expectError(error.StaleContext, makeEdit(std.testing.allocator, context, source, 4, "other"));
    try std.testing.expectError(error.InvalidCandidate, makeEdit(std.testing.allocator, context, source, 3, "bad\x00value"));
    var mutable = [_]u8{ 'e', 'c' };
    const borrowed = try inspect(&mutable, mutable.len, 1);
    mutable[0] = 'x';
    try std.testing.expectError(error.StaleContext, makeEdit(std.testing.allocator, borrowed, &mutable, 1, "echo"));
}

test {
    std.testing.refAllDecls(@This());
}
