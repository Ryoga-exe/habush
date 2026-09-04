const std = @import("std");
const Hir = @import("Hir.zig");
const Inst = Hir.Inst;

/// Write human-readable, debug-formatted HIR instructions.
pub fn renderAsText(hir: Hir, bw: *std.Io.Writer) std.Io.Writer.Error!void {
    var writer: Writer = .{ .code = hir };
    for (0..hir.instructions.len) |raw_index| {
        const index: Inst.Index = @enumFromInt(raw_index);
        try bw.print("%{d} ", .{raw_index});
        try writer.writeInstToStream(bw, index);
        try bw.writeByte('\n');
    }
}

pub fn renderSingleInstruction(
    hir: Hir,
    index: Inst.Index,
    bw: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var writer: Writer = .{ .code = hir };
    try bw.print("%{d} ", .{@intFromEnum(index)});
    try writer.writeInstToStream(bw, index);
}

const Writer = struct {
    code: Hir,

    fn writeInstToStream(
        writer: *Writer,
        stream: *std.Io.Writer,
        index: Inst.Index,
    ) std.Io.Writer.Error!void {
        const tag = writer.code.instructionTag(index);
        try stream.print("= {s}(", .{@tagName(tag)});
        switch (tag) {
            .root => try writer.writeOptionalInst(
                stream,
                writer.code.instructionData(index).un.operand,
            ),
            .list => try writer.writeList(stream, index),
            .simple_command => try writer.writeInstList(
                stream,
                writer.code.simpleCommandParts(index),
            ),
            .assignment => {
                const assignment = writer.code.assignment(index);
                try writer.writeString(stream, assignment.name);
                try stream.writeAll(", ");
                try writer.writeInst(stream, assignment.value);
            },
            .word => try writer.writeInstList(stream, writer.code.wordParts(index)),
            .redirect => try writer.writeRedirect(stream, index),
            .here_document => try writer.writeHereDocument(stream, index),
            .pipe, .pipe_and => {
                const operands = writer.code.pipeline(index);
                try writer.writeBin(stream, operands);
            },
            .negated_pipeline => try writer.writeInst(
                stream,
                writer.code.negatedPipeline(index),
            ),
            .and_if, .or_if => {
                const operands = writer.code.andOr(index);
                try writer.writeBin(stream, operands);
            },
            .subshell, .brace_group => try writer.writeGroup(stream, index),
            .if_clause => try writer.writeIf(stream, index),
            .while_clause, .until_clause => try writer.writeLoop(stream, index),
            .for_clause => try writer.writeFor(stream, index),
            .function_definition => try writer.writeFunction(stream, index),
            .literal,
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            .parameter,
            .braced_parameter,
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => try writer.writeString(stream, writer.code.wordPart(index)),
        }
        try stream.writeByte(')');
        try writer.writeSource(stream, index);
    }

    fn writeList(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        try stream.writeByte('{');
        for (0..writer.code.listItemCount(index)) |item_index| {
            if (item_index != 0) try stream.writeAll(", ");
            const item = writer.code.listItem(index, item_index);
            try writer.writeInst(stream, item.command);
            try stream.print(" {s}", .{@tagName(item.separator)});
        }
        try stream.writeByte('}');
    }

    fn writeRedirect(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const redirect = writer.code.redirect(index);
        try stream.print("{s}", .{@tagName(redirect.operator)});
        if (redirect.io_number) |io_number| {
            try stream.writeAll(", io_number=");
            try writer.writeString(stream, io_number);
        }
        try stream.writeAll(", target=");
        try writer.writeInst(stream, redirect.target);
        if (redirect.here_document.unwrap()) |document| {
            try stream.writeAll(", here_document=");
            try writer.writeInst(stream, document);
        }
    }

    fn writeHereDocument(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const document = writer.code.hereDocument(index);
        try writer.writeString(stream, document.delimiter);
        try stream.print(", expand={any}, strip_tabs={any}, body_len={d}", .{
            document.expand_body,
            document.strip_tabs,
            if (document.body) |body| body.len else 0,
        });
    }

    fn writeGroup(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const group = writer.code.groupedCommand(index);
        try stream.writeAll("body=");
        try writer.writeInst(stream, group.body);
        try stream.writeAll(", redirects=");
        try writer.writeInstList(stream, group.redirects);
    }

    fn writeIf(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const clause = writer.code.ifClause(index);
        try stream.writeAll("condition=");
        try writer.writeInst(stream, clause.condition);
        try stream.writeAll(", then=");
        try writer.writeInst(stream, clause.then_body);
        if (clause.else_body.unwrap()) |else_body| {
            try stream.writeAll(", else=");
            try writer.writeInst(stream, else_body);
        }
        try stream.writeAll(", redirects=");
        try writer.writeInstList(stream, clause.redirects);
    }

    fn writeLoop(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const clause = writer.code.loopClause(index);
        try stream.writeAll("condition=");
        try writer.writeInst(stream, clause.condition);
        try stream.writeAll(", body=");
        try writer.writeInst(stream, clause.body);
        try stream.writeAll(", redirects=");
        try writer.writeInstList(stream, clause.redirects);
    }

    fn writeFor(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const clause = writer.code.forClause(index);
        try writer.writeString(stream, clause.name);
        try stream.print(", implicit={any}, words=", .{
            clause.implicit_positional_parameters,
        });
        try writer.writeInstList(stream, clause.words);
        try stream.writeAll(", body=");
        try writer.writeInst(stream, clause.body);
        try stream.writeAll(", redirects=");
        try writer.writeInstList(stream, clause.redirects);
    }

    fn writeFunction(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const definition = writer.code.functionDefinition(index);
        try writer.writeString(stream, definition.name);
        try stream.writeAll(", body=");
        try writer.writeInst(stream, definition.body);
    }

    fn writeBin(writer: *Writer, stream: *std.Io.Writer, operands: Inst.Bin) !void {
        try writer.writeInst(stream, operands.lhs);
        try stream.writeAll(", ");
        try writer.writeInst(stream, operands.rhs);
    }

    fn writeInstList(
        writer: *Writer,
        stream: *std.Io.Writer,
        instructions: []const Inst.Index,
    ) !void {
        try stream.writeByte('{');
        for (instructions, 0..) |instruction, i| {
            if (i != 0) try stream.writeAll(", ");
            try writer.writeInst(stream, instruction);
        }
        try stream.writeByte('}');
    }

    fn writeOptionalInst(
        writer: *Writer,
        stream: *std.Io.Writer,
        instruction: Inst.OptionalIndex,
    ) !void {
        if (instruction.unwrap()) |index| try writer.writeInst(stream, index);
    }

    fn writeInst(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        _ = writer;
        try stream.print("%{d}", .{@intFromEnum(index)});
    }

    fn writeString(writer: *Writer, stream: *std.Io.Writer, bytes: []const u8) !void {
        _ = writer;
        try stream.print("\"{f}\"", .{std.zig.fmtString(bytes)});
    }

    fn writeSource(writer: *Writer, stream: *std.Io.Writer, index: Inst.Index) !void {
        const tag = writer.code.instructionTag(index);
        const start = switch (tag) {
            .root,
            .pipe,
            .pipe_and,
            .and_if,
            .or_if,
            .literal,
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            .parameter,
            .braced_parameter,
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => return,
            .negated_pipeline => writer.code.instructionData(index).un.src_start,
            .list,
            .simple_command,
            .assignment,
            .word,
            .redirect,
            .here_document,
            .subshell,
            .brace_group,
            .if_clause,
            .while_clause,
            .until_clause,
            .for_clause,
            .function_definition,
            => writer.code.instructionData(index).pl.src_start,
        };
        try stream.print(" src:{d}", .{start});
    }
};
