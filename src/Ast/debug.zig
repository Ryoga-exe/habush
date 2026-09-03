const std = @import("std");
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Writer = std.Io.Writer;

pub fn render(tree: *const Ast, writer: *Writer) Writer.Error!void {
    try renderNode(tree, writer, .root, 0);
}

fn renderNode(
    tree: *const Ast,
    writer: *Writer,
    node: Node.Index,
    depth: usize,
) Writer.Error!void {
    const tag = tree.nodeTag(node);
    try indent(writer, depth);
    try writer.writeAll(@tagName(tag));
    switch (tag) {
        .word, .assignment, .redirect, .negated_pipeline, .and_if, .or_if, .pipe, .pipe_and => {
            try writer.print(" \"{f}\"", .{std.zig.fmtString(tree.tokenSlice(tree.nodeMainToken(node)))});
        },
        else => {},
    }
    try writer.writeByte('\n');

    switch (tag) {
        .root => try renderOptionalChild(
            tree,
            writer,
            "body",
            tree.nodeData(node).opt_node,
            depth + 1,
        ),
        .list => {
            for (0..tree.listItemCount(node)) |item_index| {
                const item = tree.listItem(node, item_index);
                try renderChild(tree, writer, "item", item.command, depth + 1);
                if (item.separator.unwrap()) |separator| {
                    try renderToken(tree, writer, "separator", separator, depth + 1);
                }
            }
        },
        .and_if, .or_if, .pipe, .pipe_and => {
            const children = tree.nodeData(node).node_and_node;
            try renderChild(tree, writer, "lhs", children[0], depth + 1);
            try renderChild(tree, writer, "rhs", children[1], depth + 1);
        },
        .negated_pipeline => try renderOptionalChild(
            tree,
            writer,
            "pipeline",
            tree.nodeData(node).opt_node,
            depth + 1,
        ),
        .simple_command => {
            for (tree.simpleCommandParts(node)) |part| {
                try renderChild(tree, writer, "part", part, depth + 1);
            }
        },
        .subshell => {
            const subshell = tree.subshell(node);
            try renderOptionalChild(tree, writer, "body", subshell.body, depth + 1);
            try renderRedirects(
                tree,
                writer,
                subshell.redirects_start,
                subshell.redirects_end,
                depth + 1,
            );
        },
        .brace_group => {
            const group = tree.braceGroup(node);
            try renderOptionalChild(tree, writer, "body", group.body, depth + 1);
            try renderRedirects(
                tree,
                writer,
                group.redirects_start,
                group.redirects_end,
                depth + 1,
            );
        },
        .if_clause => {
            const clause = tree.ifClause(node);
            try renderOptionalChild(tree, writer, "condition", clause.condition, depth + 1);
            try renderOptionalChild(tree, writer, "then", clause.then_body, depth + 1);
            for (0..tree.elifBranchCount(clause)) |branch_index| {
                const branch = tree.elifBranch(clause, branch_index);
                try renderOptionalChild(tree, writer, "elif condition", branch.condition, depth + 1);
                try renderOptionalChild(tree, writer, "elif body", branch.body, depth + 1);
            }
            try renderOptionalChild(tree, writer, "else", clause.else_body, depth + 1);
            try renderRedirects(
                tree,
                writer,
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .while_clause, .until_clause => {
            const clause = tree.loopClause(node);
            try renderOptionalChild(tree, writer, "condition", clause.condition, depth + 1);
            try renderOptionalChild(tree, writer, "body", clause.body, depth + 1);
            try renderRedirects(
                tree,
                writer,
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .for_clause => {
            const clause = tree.forClause(node);
            if (clause.name_token.unwrap()) |name| {
                try renderToken(tree, writer, "name", name, depth + 1);
            }
            for (tree.forWords(clause)) |word| {
                try renderChild(tree, writer, "word", word, depth + 1);
            }
            try renderOptionalChild(tree, writer, "body", clause.body, depth + 1);
            try renderRedirects(
                tree,
                writer,
                clause.redirects_start,
                clause.redirects_end,
                depth + 1,
            );
        },
        .word, .assignment => try renderWordParts(tree, writer, node, depth + 1),
        .redirect => {
            const redirect = tree.redirect(node);
            if (redirect.io_number.unwrap()) |io_number| {
                try renderToken(tree, writer, "io_number", io_number, depth + 1);
            }
            try renderOptionalChild(tree, writer, "target", redirect.target, depth + 1);
            if (redirect.here_document.unwrap()) |document_index| {
                const document = tree.hereDocument(document_index);
                try indent(writer, depth + 1);
                try writer.print("here_document \"{f}\" expand={any} strip_tabs={any}\n", .{
                    std.zig.fmtString(document.delimiter),
                    document.expand_body,
                    document.strip_tabs,
                });
            }
        },
    }
}

fn renderWordParts(
    tree: *const Ast,
    writer: *Writer,
    node: Node.Index,
    depth: usize,
) Writer.Error!void {
    for (0..tree.wordPartCount(node)) |part_index| {
        const part = tree.wordPart(node, part_index);
        try indent(writer, depth);
        try writer.print("{s} \"{f}\"\n", .{
            @tagName(part.tag),
            std.zig.fmtString(tree.source[part.start..part.end]),
        });
    }
}

fn renderRedirects(
    tree: *const Ast,
    writer: *Writer,
    start: Ast.ExtraIndex,
    end: Ast.ExtraIndex,
    depth: usize,
) Writer.Error!void {
    const redirects = tree.extraDataSlice(.{ .start = start, .end = end }, Node.Index);
    for (redirects) |redirect| {
        try renderChild(tree, writer, "redirect", redirect, depth);
    }
}

fn renderOptionalChild(
    tree: *const Ast,
    writer: *Writer,
    label: []const u8,
    child: Node.OptionalIndex,
    depth: usize,
) Writer.Error!void {
    if (child.unwrap()) |node| try renderChild(tree, writer, label, node, depth);
}

fn renderChild(
    tree: *const Ast,
    writer: *Writer,
    label: []const u8,
    child: Node.Index,
    depth: usize,
) Writer.Error!void {
    try indent(writer, depth);
    try writer.print("{s}:\n", .{label});
    try renderNode(tree, writer, child, depth + 1);
}

fn renderToken(
    tree: *const Ast,
    writer: *Writer,
    label: []const u8,
    token: Ast.TokenIndex,
    depth: usize,
) Writer.Error!void {
    try indent(writer, depth);
    try writer.print("{s} \"{f}\"\n", .{
        label,
        std.zig.fmtString(tree.tokenSlice(token)),
    });
}

fn indent(writer: *Writer, depth: usize) Writer.Error!void {
    try writer.splatByteAll(' ', depth * 2);
}
