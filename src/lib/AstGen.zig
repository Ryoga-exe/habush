//! Ingests an AST and produces HIR instructions.

const AstGen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Hir = @import("Hir.zig");
const Token = @import("tokenizer.zig").Token;

pub const Error = Allocator.Error || error{
    SourceTooLarge,
    InvalidAst,
    UnsupportedSyntax,
};

gpa: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Hir.Inst) = .empty,
extra: std.ArrayList(u32) = .empty,
string_bytes: std.ArrayList(u8) = .empty,
/// Temporary storage for instruction trailers.
scratch: std.ArrayList(u32) = .empty,

pub fn generate(gpa: Allocator, tree: Ast) Error!Hir {
    if (tree.errors.len != 0 or tree.status != .complete) return error.InvalidAst;

    var astgen: AstGen = .{ .gpa = gpa, .tree = &tree };
    defer astgen.deinit();

    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);
    try astgen.instructions.append(gpa, .{
        .tag = .root,
        .data = .{ .un = .{ .operand = .none } },
    });

    if (tree.nodeData(.root).opt_node.unwrap()) |list| {
        if (tree.nodeTag(list) != .list or tree.listItemCount(list) != 1) {
            return error.UnsupportedSyntax;
        }
        const item = tree.listItem(list, 0);
        if (item.separator.unwrap()) |separator| {
            switch (tree.tokenTag(separator)) {
                .semicolon, .newline => {},
                else => return error.UnsupportedSyntax,
            }
        }

        const root_command = try astgen.command(item.command);
        astgen.instructions.set(@intFromEnum(Hir.Inst.Index.root), .{
            .tag = .root,
            .data = .{ .un = .{ .operand = root_command.toOptional() } },
        });
    }

    return astgen.finish();
}

fn deinit(astgen: *AstGen) void {
    astgen.instructions.deinit(astgen.gpa);
    astgen.extra.deinit(astgen.gpa);
    astgen.string_bytes.deinit(astgen.gpa);
    astgen.scratch.deinit(astgen.gpa);
}

fn finish(astgen: *AstGen) Error!Hir {
    var instructions = astgen.instructions.toOwnedSlice();
    errdefer instructions.deinit(astgen.gpa);
    const string_bytes = try astgen.string_bytes.toOwnedSlice(astgen.gpa);
    errdefer astgen.gpa.free(string_bytes);
    const extra = try astgen.extra.toOwnedSlice(astgen.gpa);
    errdefer astgen.gpa.free(extra);

    return .{
        .instructions = instructions,
        .string_bytes = string_bytes,
        .extra = extra,
    };
}

fn command(astgen: *AstGen, node: Ast.Node.Index) Error!Hir.Inst.Index {
    return switch (astgen.tree.nodeTag(node)) {
        .simple_command => astgen.simpleCommand(node),
        else => error.UnsupportedSyntax,
    };
}

fn simpleCommand(astgen: *AstGen, node: Ast.Node.Index) Error!Hir.Inst.Index {
    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.items.len = scratch_top;

    for (astgen.tree.simpleCommandParts(node)) |part| {
        const instruction = switch (astgen.tree.nodeTag(part)) {
            .assignment => try astgen.assignment(part),
            .word => try astgen.word(part),
            .redirect => try astgen.redirect(part),
            else => unreachable,
        };
        try astgen.scratch.append(astgen.gpa, @intFromEnum(instruction));
    }

    const parts = astgen.scratch.items[scratch_top..];
    const payload_index = try astgen.addExtra(Hir.SimpleCommand{
        .parts_len = try index(u32, parts.len),
    });
    try astgen.extra.appendSlice(astgen.gpa, parts);

    return astgen.addInstruction(.{
        .tag = .simple_command,
        .data = .{ .pl = .{
            .src_start = astgen.sourceStart(node),
            .payload_index = payload_index,
        } },
    });
}

fn assignment(astgen: *AstGen, node: Ast.Node.Index) Error!Hir.Inst.Index {
    const name = try astgen.addString(astgen.tree.assignmentName(node));
    const value = try astgen.word(node);
    const payload_index = try astgen.addExtra(Hir.Assignment{
        .name_start = name.start,
        .name_len = name.len,
        .value = value,
    });
    return astgen.addInstruction(.{
        .tag = .assignment,
        .data = .{ .pl = .{
            .src_start = astgen.tree.tokenStart(astgen.tree.nodeMainToken(node)),
            .payload_index = payload_index,
        } },
    });
}

fn word(astgen: *AstGen, node: Ast.Node.Index) Error!Hir.Inst.Index {
    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.items.len = scratch_top;

    for (0..astgen.tree.wordPartCount(node)) |part_index| {
        const part = astgen.tree.wordPart(node, part_index);
        const value = try astgen.addString(astgen.tree.source[part.start..part.end]);
        const instruction = try astgen.addInstruction(.{
            .tag = switch (part.tag) {
                inline else => |tag| @field(Hir.Inst.Tag, @tagName(tag)),
            },
            .data = .{ .str = value },
        });
        try astgen.scratch.append(astgen.gpa, @intFromEnum(instruction));
    }

    const parts = astgen.scratch.items[scratch_top..];
    const payload_index = try astgen.addExtra(Hir.Word{
        .parts_len = try index(u32, parts.len),
    });
    try astgen.extra.appendSlice(astgen.gpa, parts);

    return astgen.addInstruction(.{
        .tag = .word,
        .data = .{ .pl = .{
            .src_start = astgen.sourceStart(node),
            .payload_index = payload_index,
        } },
    });
}

fn redirect(astgen: *AstGen, node: Ast.Node.Index) Error!Hir.Inst.Index {
    const redirect_info = astgen.tree.redirect(node);
    const target = redirect_info.target.unwrap() orelse return error.InvalidAst;

    var io_number_start: Hir.StringIndex.OptionalIndex = .none;
    var io_number_len: u32 = 0;
    if (redirect_info.io_number.unwrap()) |token| {
        const io_number = try astgen.addString(astgen.tree.tokenSlice(token));
        io_number_start = io_number.start.toOptional();
        io_number_len = io_number.len;
    }

    var here_document: Hir.Inst.OptionalIndex = .none;
    if (redirect_info.here_document.unwrap()) |document_index| {
        here_document = (try astgen.hereDocument(document_index)).toOptional();
    }

    const payload_index = try astgen.addExtra(Hir.Redirect{
        .operator = redirectOperator(astgen.tree.tokenTag(astgen.tree.nodeMainToken(node))),
        .io_number_start = io_number_start,
        .io_number_len = io_number_len,
        .target = try astgen.word(target),
        .here_document = here_document,
    });
    return astgen.addInstruction(.{
        .tag = .redirect,
        .data = .{ .pl = .{
            .src_start = astgen.sourceStart(node),
            .payload_index = payload_index,
        } },
    });
}

fn hereDocument(astgen: *AstGen, ast_index: Ast.HereDocumentIndex) Error!Hir.Inst.Index {
    const document = astgen.tree.hereDocument(ast_index);
    const delimiter = try astgen.addString(document.delimiter);

    var body_start: Hir.StringIndex.OptionalIndex = .none;
    var body_len: u32 = 0;
    if (document.body) |body_bytes| {
        const body = try astgen.addString(body_bytes);
        body_start = body.start.toOptional();
        body_len = body.len;
    }

    const payload_index = try astgen.addExtra(Hir.HereDocument{
        .delimiter_start = delimiter.start,
        .delimiter_len = delimiter.len,
        .body_start = body_start,
        .body_len = body_len,
        .flags = .{
            .strip_tabs = document.strip_tabs,
            .expand_body = document.expand_body,
        },
    });
    return astgen.addInstruction(.{
        .tag = .here_document,
        .data = .{ .pl = .{
            .src_start = astgen.sourceStart(document.redirect),
            .payload_index = payload_index,
        } },
    });
}

fn addInstruction(astgen: *AstGen, instruction: Hir.Inst) Error!Hir.Inst.Index {
    if (astgen.instructions.len == std.math.maxInt(u32)) return error.SourceTooLarge;
    const instruction_index = try index(Hir.Inst.Index, astgen.instructions.len);
    try astgen.instructions.append(astgen.gpa, instruction);
    return instruction_index;
}

fn addString(astgen: *AstGen, bytes: []const u8) Error!Hir.String {
    if (astgen.string_bytes.items.len == std.math.maxInt(u32)) return error.SourceTooLarge;
    const start = try index(Hir.StringIndex, astgen.string_bytes.items.len);
    const len = try index(u32, bytes.len);
    if (bytes.len > std.math.maxInt(u32) - astgen.string_bytes.items.len) {
        return error.SourceTooLarge;
    }
    try astgen.string_bytes.appendSlice(astgen.gpa, bytes);
    return .{ .start = start, .len = len };
}

fn addExtra(astgen: *AstGen, extra: anytype) Error!Hir.ExtraIndex {
    const fields = std.meta.fields(@TypeOf(extra));
    if (fields.len > std.math.maxInt(u32) - astgen.extra.items.len) {
        return error.SourceTooLarge;
    }
    try astgen.extra.ensureUnusedCapacity(astgen.gpa, fields.len);

    const extra_index = try index(Hir.ExtraIndex, astgen.extra.items.len);
    inline for (fields) |field| {
        const value = @field(extra, field.name);
        astgen.extra.appendAssumeCapacity(switch (@typeInfo(field.type)) {
            .int => value,
            .@"enum" => @intFromEnum(value),
            .@"struct" => @bitCast(value),
            else => @compileError("unsupported HIR extra field: " ++
                @typeName(@TypeOf(extra)) ++ "." ++ field.name ++ ": " ++
                @typeName(field.type)),
        });
    }
    return extra_index;
}

fn sourceStart(astgen: *const AstGen, node: Ast.Node.Index) Hir.ByteOffset {
    return astgen.tree.tokenStart(astgen.tree.nodeMainToken(node));
}

fn redirectOperator(tag: Token.Tag) Hir.Redirect.Operator {
    return switch (tag) {
        .lt => .input,
        .gt => .output,
        .gt_gt => .append,
        .lt_lt => .here_document,
        .lt_lt_minus => .here_document_strip_tabs,
        .lt_lt_lt => .here_string,
        .lt_ampersand => .duplicate_input,
        .gt_ampersand => .duplicate_output,
        .lt_gt => .input_output,
        .gt_pipe => .clobber,
        .ampersand_gt => .output_both,
        .ampersand_gt_gt => .append_both,
        else => unreachable,
    };
}

fn index(comptime T: type, value: usize) Error!T {
    const raw = std.math.cast(u32, value) orelse return error.SourceTooLarge;
    return if (T == u32) raw else @enumFromInt(raw);
}

test {
    _ = @import("astgen_test.zig");
}
