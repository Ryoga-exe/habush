const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Hir = @import("Hir.zig");

test "generates empty input" {
    var tree = try Ast.parse(std.testing.allocator, "");
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    try std.testing.expect(hir.root() == null);
}

test "generates a simple command while preserving part order" {
    const source = "A=one >out echo \"$name\" 2>>log";
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const root_list = hir.root().?;
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(root_list));
    try std.testing.expectEqual(@as(usize, 1), hir.listItemCount(root_list));
    const root_item = hir.listItem(root_list, 0);
    try std.testing.expectEqual(Hir.List.Item.Separator.none, root_item.separator);

    const parts = hir.simpleCommandParts(root_item.command);
    try std.testing.expectEqual(@as(usize, 5), parts.len);

    try std.testing.expectEqual(Hir.Inst.Tag.assignment, hir.instructionTag(parts[0]));
    const assignment = hir.assignment(parts[0]);
    try std.testing.expectEqualStrings("A", assignment.name);
    const assignment_parts = hir.wordParts(assignment.value);
    try std.testing.expectEqualStrings("one", hir.wordPart(assignment_parts[0]));

    const first_redirect = hir.redirect(parts[1]);
    try std.testing.expectEqual(Hir.Redirect.Operator.output, first_redirect.operator);
    try std.testing.expect(first_redirect.io_number == null);

    const argument_parts = hir.wordParts(parts[3]);
    try std.testing.expectEqual(
        Hir.Inst.Tag.double_quoted_parameter,
        hir.instructionTag(argument_parts[0]),
    );
    try std.testing.expectEqualStrings("name", hir.wordPart(argument_parts[0]));

    const second_redirect = hir.redirect(parts[4]);
    try std.testing.expectEqual(Hir.Redirect.Operator.append, second_redirect.operator);
    try std.testing.expectEqualStrings("2", second_redirect.io_number.?);
}

test "HIR owns source-derived and here-document strings" {
    var hir = try generateOwnedHereDocument(std.testing.allocator);
    defer hir.deinit(std.testing.allocator);

    const command_parts = hir.simpleCommandParts(firstCommand(hir));
    const redirect = hir.redirect(command_parts[1]);
    const document = hir.hereDocument(redirect.here_document.unwrap().?);
    try std.testing.expectEqualStrings("EOF", document.delimiter);
    try std.testing.expect(!document.expand_body);
    try std.testing.expectEqualStrings("contents\x00\n", document.body.?);
    try std.testing.expectEqualStrings("cat", hir.wordPart(hir.wordParts(command_parts[0])[0]));
}

test "generates pipelines and pipeline negation" {
    var tree = try Ast.parse(std.testing.allocator, "! echo hi | grep h |& count");
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const negation = firstCommand(hir);
    try std.testing.expectEqual(Hir.Inst.Tag.negated_pipeline, hir.instructionTag(negation));

    const outer = hir.negatedPipeline(negation);
    try std.testing.expectEqual(Hir.Inst.Tag.pipe_and, hir.instructionTag(outer));
    const outer_operands = hir.pipeline(outer);
    try std.testing.expectEqual(Hir.Inst.Tag.pipe, hir.instructionTag(outer_operands.lhs));
    try std.testing.expectEqual(
        Hir.Inst.Tag.simple_command,
        hir.instructionTag(outer_operands.rhs),
    );

    const inner_operands = hir.pipeline(outer_operands.lhs);
    try std.testing.expectEqual(
        Hir.Inst.Tag.simple_command,
        hir.instructionTag(inner_operands.lhs),
    );
    try std.testing.expectEqual(
        Hir.Inst.Tag.simple_command,
        hir.instructionTag(inner_operands.rhs),
    );
}

test "generates and-or commands with pipeline precedence" {
    var tree = try Ast.parse(std.testing.allocator, "a | b && c || d | e");
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const outer = firstCommand(hir);
    try std.testing.expectEqual(Hir.Inst.Tag.or_if, hir.instructionTag(outer));
    const outer_operands = hir.andOr(outer);
    try std.testing.expectEqual(Hir.Inst.Tag.and_if, hir.instructionTag(outer_operands.lhs));
    try std.testing.expectEqual(Hir.Inst.Tag.pipe, hir.instructionTag(outer_operands.rhs));

    const and_operands = hir.andOr(outer_operands.lhs);
    try std.testing.expectEqual(Hir.Inst.Tag.pipe, hir.instructionTag(and_operands.lhs));
    try std.testing.expectEqual(
        Hir.Inst.Tag.simple_command,
        hir.instructionTag(and_operands.rhs),
    );
}

test "normalizes list separators" {
    var tree = try Ast.parse(std.testing.allocator, "first; second\nthird & fourth");
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const list = hir.root().?;
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(list));
    try std.testing.expectEqual(@as(usize, 4), hir.listItemCount(list));
    try std.testing.expectEqual(
        Hir.List.Item.Separator.sequential,
        hir.listItem(list, 0).separator,
    );
    try std.testing.expectEqual(
        Hir.List.Item.Separator.sequential,
        hir.listItem(list, 1).separator,
    );
    try std.testing.expectEqual(
        Hir.List.Item.Separator.background,
        hir.listItem(list, 2).separator,
    );
    try std.testing.expectEqual(
        Hir.List.Item.Separator.none,
        hir.listItem(list, 3).separator,
    );
}

test "generates subshell and brace group bodies with redirects" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "(prepare; run) 2>log | { consume; finish; } >out",
    );
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const operands = hir.pipeline(firstCommand(hir));
    try std.testing.expectEqual(Hir.Inst.Tag.subshell, hir.instructionTag(operands.lhs));
    try std.testing.expectEqual(Hir.Inst.Tag.brace_group, hir.instructionTag(operands.rhs));

    const subshell = hir.groupedCommand(operands.lhs);
    try std.testing.expectEqual(@as(usize, 2), hir.listItemCount(subshell.body));
    try std.testing.expectEqual(@as(usize, 1), subshell.redirects.len);
    const subshell_redirect = hir.redirect(subshell.redirects[0]);
    try std.testing.expectEqualStrings("2", subshell_redirect.io_number.?);
    try std.testing.expectEqualStrings("log", firstWordPart(hir, subshell_redirect.target));

    const brace_group = hir.groupedCommand(operands.rhs);
    try std.testing.expectEqual(@as(usize, 2), hir.listItemCount(brace_group.body));
    try std.testing.expectEqual(
        Hir.List.Item.Separator.sequential,
        hir.listItem(brace_group.body, 1).separator,
    );
    try std.testing.expectEqual(@as(usize, 1), brace_group.redirects.len);
    const brace_redirect = hir.redirect(brace_group.redirects[0]);
    try std.testing.expectEqualStrings("out", firstWordPart(hir, brace_redirect.target));
}

test "rejects invalid and unsupported ASTs" {
    var invalid = try Ast.parse(std.testing.allocator, "echo |");
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidAst,
        AstGen.generate(std.testing.allocator, invalid),
    );

    var unsupported = try Ast.parse(std.testing.allocator, "if condition; then result; fi");
    defer unsupported.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedSyntax,
        AstGen.generate(std.testing.allocator, unsupported),
    );
}

test "AST generation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        generateWithAllocator,
        .{"! (A=value command 2>>log; notify) | { consume && fallback; } &"},
    );
}

fn generateOwnedHereDocument(gpa: std.mem.Allocator) !Hir {
    const source = try gpa.dupeZ(u8, "cat <<'EOF'\n");
    defer gpa.free(source);
    const body = try gpa.dupe(u8, "contents\x00\n");
    defer gpa.free(body);

    const collected = [_]@import("heredoc.zig").Collected{.{
        .delimiter = "EOF",
        .strip_tabs = false,
        .expand_body = false,
        .body = body,
    }};
    var tree = try Ast.parseWithOptions(gpa, source, .{
        .collected_here_documents = &collected,
    });
    defer tree.deinit(gpa);

    return AstGen.generate(gpa, tree);
}

fn generateWithAllocator(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    var hir = try AstGen.generate(gpa, tree);
    defer hir.deinit(gpa);
}

fn firstCommand(hir: Hir) Hir.Inst.Index {
    const list = hir.root().?;
    return hir.listItem(list, 0).command;
}

fn firstWordPart(hir: Hir, word: Hir.Inst.Index) []const u8 {
    return hir.wordPart(hir.wordParts(word)[0]);
}
