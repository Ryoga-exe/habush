const std = @import("std");
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Writer = std.Io.Writer;
const Dump = @This();

tree: *const Ast,
writer: *Writer,

pub fn render(tree: *const Ast, writer: *Writer) Writer.Error!void {
    var dump: Dump = .{ .tree = tree, .writer = writer };
    try dump.renderNode(.root, 0);
}

fn renderNode(
    dump: *Dump,
    node: Node.Index,
    depth: usize,
) Writer.Error!void {
    const tag = dump.tree.nodeTag(node);
    try dump.indent(depth);
    try dump.writer.writeAll(@tagName(tag));
    switch (tag) {
        .word, .assignment, .redirect, .negated_pipeline, .and_if, .or_if, .pipe, .pipe_and => {
            try dump.writer.print(" \"{f}\"", .{std.zig.fmtString(dump.tree.tokenSlice(dump.tree.nodeMainToken(node)))});
        },
        else => {},
    }
    try dump.writer.writeByte('\n');

    switch (tag) {
        .root => try dump.renderOptionalChild(
            "body",
            dump.tree.nodeData(node).opt_node,
            depth + 1,
        ),
        .list => {
            for (0..dump.tree.listItemCount(node)) |item_index| {
                const item = dump.tree.listItem(node, item_index);
                try dump.renderChild("item", item.command, depth + 1);
                if (item.separator.unwrap()) |separator| {
                    try dump.renderToken("separator", separator, depth + 1);
                }
            }
        },
        .and_if, .or_if, .pipe, .pipe_and => {
            const children = dump.tree.nodeData(node).node_and_node;
            try dump.renderChild("lhs", children[0], depth + 1);
            try dump.renderChild("rhs", children[1], depth + 1);
        },
        .negated_pipeline => try dump.renderOptionalChild(
            "pipeline",
            dump.tree.nodeData(node).opt_node,
            depth + 1,
        ),
        .simple_command => {
            for (dump.tree.simpleCommandParts(node)) |part| {
                try dump.renderChild("part", part, depth + 1);
            }
        },
        .subshell => {
            const subshell = dump.tree.subshell(node);
            try dump.renderOptionalChild("body", subshell.body, depth + 1);
            try dump.renderRedirects(
                subshell.redirects_start,
                subshell.redirects_end,
                depth + 1,
            );
        },
        .brace_group => {
            const group = dump.tree.braceGroup(node);
            try dump.renderOptionalChild("body", group.body, depth + 1);
            try dump.renderRedirects(
                group.redirects_start,
                group.redirects_end,
                depth + 1,
            );
        },
        .if_clause => {
            const clause = dump.tree.ifClause(node);
            try dump.renderOptionalChild("condition", clause.condition, depth + 1);
            try dump.renderOptionalChild("then", clause.then_body, depth + 1);
            for (0..dump.tree.elifBranchCount(clause)) |branch_index| {
                const branch = dump.tree.elifBranch(clause, branch_index);
                try dump.renderOptionalChild("elif condition", branch.condition, depth + 1);
                try dump.renderOptionalChild("elif body", branch.body, depth + 1);
            }
            try dump.renderOptionalChild("else", clause.else_body, depth + 1);
            try dump.renderRedirects(
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .while_clause, .until_clause => {
            const clause = dump.tree.loopClause(node);
            try dump.renderOptionalChild("condition", clause.condition, depth + 1);
            try dump.renderOptionalChild("body", clause.body, depth + 1);
            try dump.renderRedirects(
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .for_clause => {
            const clause = dump.tree.forClause(node);
            if (clause.name_token.unwrap()) |name| {
                try dump.renderToken("name", name, depth + 1);
            }
            for (dump.tree.forWords(clause)) |word| {
                try dump.renderChild("word", word, depth + 1);
            }
            try dump.renderOptionalChild("body", clause.body, depth + 1);
            try dump.renderRedirects(
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .word, .assignment => try dump.renderWordParts(node, depth + 1),
        .redirect => {
            const redirect = dump.tree.redirect(node);
            if (redirect.io_number.unwrap()) |io_number| {
                try dump.renderToken("io_number", io_number, depth + 1);
            }
            try dump.renderOptionalChild("target", redirect.target, depth + 1);
            if (redirect.here_document.unwrap()) |document_index| {
                const document = dump.tree.hereDocument(document_index);
                try dump.indent(depth + 1);
                try dump.writer.print("here_document \"{f}\" expand={any} strip_tabs={any}\n", .{
                    std.zig.fmtString(document.delimiter),
                    document.expand_body,
                    document.strip_tabs,
                });
            }
        },
    }
}

fn renderWordParts(
    dump: *Dump,
    node: Node.Index,
    depth: usize,
) Writer.Error!void {
    for (0..dump.tree.wordPartCount(node)) |part_index| {
        const part = dump.tree.wordPart(node, part_index);
        try dump.indent(depth);
        try dump.writer.print("{s} \"{f}\"\n", .{
            @tagName(part.tag),
            std.zig.fmtString(dump.tree.source[part.start..part.end]),
        });
    }
}

fn renderRedirects(
    dump: *Dump,
    start: Ast.ExtraIndex,
    end: Ast.ExtraIndex,
    depth: usize,
) Writer.Error!void {
    const redirects = dump.tree.extraDataSlice(.{ .start = start, .end = end }, Node.Index);
    for (redirects) |redirect| {
        try dump.renderChild("redirect", redirect, depth);
    }
}

fn renderOptionalChild(
    dump: *Dump,
    label: []const u8,
    child: Node.OptionalIndex,
    depth: usize,
) Writer.Error!void {
    if (child.unwrap()) |node| try dump.renderChild(label, node, depth);
}

fn renderChild(
    dump: *Dump,
    label: []const u8,
    child: Node.Index,
    depth: usize,
) Writer.Error!void {
    try dump.indent(depth);
    try dump.writer.print("{s}:\n", .{label});
    try dump.renderNode(child, depth + 1);
}

fn renderToken(
    dump: *Dump,
    label: []const u8,
    token: Ast.TokenIndex,
    depth: usize,
) Writer.Error!void {
    try dump.indent(depth);
    try dump.writer.print("{s} \"{f}\"\n", .{
        label,
        std.zig.fmtString(dump.tree.tokenSlice(token)),
    });
}

fn indent(dump: *Dump, depth: usize) Writer.Error!void {
    try dump.writer.splatByteAll(' ', depth * 2);
}
