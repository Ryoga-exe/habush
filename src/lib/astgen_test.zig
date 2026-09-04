const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Hir = @import("Hir.zig");
const print_hir = @import("print_hir.zig");

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

test "generates if branches and lowers elif to nested if" {
    const source =
        \\if check primary; then
        \\  use primary
        \\elif check secondary; then
        \\  use secondary
        \\elif check tertiary; then
        \\  use tertiary
        \\else
        \\  use fallback
        \\fi >result
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const outer_index = firstCommand(hir);
    try std.testing.expectEqual(Hir.Inst.Tag.if_clause, hir.instructionTag(outer_index));
    const outer = hir.ifClause(outer_index);
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(outer.condition));
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(outer.then_body));
    try std.testing.expectEqual(@as(usize, 1), outer.redirects.len);
    try std.testing.expectEqualStrings(
        "result",
        firstWordPart(hir, hir.redirect(outer.redirects[0]).target),
    );

    const elif_index = outer.else_body.unwrap().?;
    try std.testing.expectEqual(Hir.Inst.Tag.if_clause, hir.instructionTag(elif_index));
    const elif_clause = hir.ifClause(elif_index);
    try std.testing.expectEqual(@as(usize, 0), elif_clause.redirects.len);
    const second_elif_index = elif_clause.else_body.unwrap().?;
    try std.testing.expectEqual(Hir.Inst.Tag.if_clause, hir.instructionTag(second_elif_index));
    const second_elif = hir.ifClause(second_elif_index);
    const else_body = second_elif.else_body.unwrap().?;
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(else_body));
}

test "generates while and until clauses" {
    const source =
        \\while outer; do
        \\  until inner; do
        \\    step
        \\  done
        \\done 2>log
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const outer_index = firstCommand(hir);
    try std.testing.expectEqual(Hir.Inst.Tag.while_clause, hir.instructionTag(outer_index));
    const outer = hir.loopClause(outer_index);
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(outer.condition));
    try std.testing.expectEqual(@as(usize, 1), outer.redirects.len);
    const redirect = hir.redirect(outer.redirects[0]);
    try std.testing.expectEqualStrings("2", redirect.io_number.?);
    try std.testing.expectEqualStrings("log", firstWordPart(hir, redirect.target));

    const inner_index = firstListCommand(hir, outer.body);
    try std.testing.expectEqual(Hir.Inst.Tag.until_clause, hir.instructionTag(inner_index));
    const inner = hir.loopClause(inner_index);
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(inner.condition));
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(inner.body));
    try std.testing.expectEqual(@as(usize, 0), inner.redirects.len);
}

test "generates for clause words, body, and redirects" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "for item in one \"$two\"; do consume $item; done >log",
    );
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const for_index = firstCommand(hir);
    try std.testing.expectEqual(Hir.Inst.Tag.for_clause, hir.instructionTag(for_index));
    const clause = hir.forClause(for_index);
    try std.testing.expectEqualStrings("item", clause.name);
    try std.testing.expect(!clause.implicit_positional_parameters);
    try std.testing.expectEqual(@as(usize, 2), clause.words.len);
    try std.testing.expectEqualStrings("one", firstWordPart(hir, clause.words[0]));
    const quoted_part = hir.wordParts(clause.words[1])[0];
    try std.testing.expectEqual(
        Hir.Inst.Tag.double_quoted_parameter,
        hir.instructionTag(quoted_part),
    );
    try std.testing.expectEqualStrings("two", hir.wordPart(quoted_part));
    try std.testing.expectEqual(Hir.Inst.Tag.list, hir.instructionTag(clause.body));
    try std.testing.expectEqual(@as(usize, 1), clause.redirects.len);
    try std.testing.expectEqualStrings(
        "log",
        firstWordPart(hir, hir.redirect(clause.redirects[0]).target),
    );
}

test "distinguishes implicit parameters from an explicit empty for list" {
    var implicit_tree = try Ast.parse(
        std.testing.allocator,
        "for item; do consume $item; done",
    );
    defer implicit_tree.deinit(std.testing.allocator);
    var implicit_hir = try AstGen.generate(std.testing.allocator, implicit_tree);
    defer implicit_hir.deinit(std.testing.allocator);

    const implicit = implicit_hir.forClause(firstCommand(implicit_hir));
    try std.testing.expect(implicit.implicit_positional_parameters);
    try std.testing.expectEqual(@as(usize, 0), implicit.words.len);

    var empty_tree = try Ast.parse(
        std.testing.allocator,
        "for item in; do consume $item; done",
    );
    defer empty_tree.deinit(std.testing.allocator);
    var empty_hir = try AstGen.generate(std.testing.allocator, empty_tree);
    defer empty_hir.deinit(std.testing.allocator);

    const empty = empty_hir.forClause(firstCommand(empty_hir));
    try std.testing.expect(!empty.implicit_positional_parameters);
    try std.testing.expectEqual(@as(usize, 0), empty.words.len);
}

test "generates function definitions with compound bodies" {
    const source =
        \\build() { produce | consume; } >log
        \\check()
        \\(verify)
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    const root_list = hir.root().?;
    try std.testing.expectEqual(@as(usize, 2), hir.listItemCount(root_list));

    const build_index = hir.listItem(root_list, 0).command;
    try std.testing.expectEqual(
        Hir.Inst.Tag.function_definition,
        hir.instructionTag(build_index),
    );
    const build = hir.functionDefinition(build_index);
    try std.testing.expectEqualStrings("build", build.name);
    try std.testing.expectEqual(Hir.Inst.Tag.brace_group, hir.instructionTag(build.body));
    const build_body = hir.groupedCommand(build.body);
    try std.testing.expectEqual(@as(usize, 1), build_body.redirects.len);
    try std.testing.expectEqualStrings(
        "log",
        firstWordPart(hir, hir.redirect(build_body.redirects[0]).target),
    );

    const check_index = hir.listItem(root_list, 1).command;
    const check = hir.functionDefinition(check_index);
    try std.testing.expectEqualStrings("check", check.name);
    try std.testing.expectEqual(Hir.Inst.Tag.subshell, hir.instructionTag(check.body));
}

test "renders HIR instructions as text" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "! A=one echo \"$name\" | consume 2>log &",
    );
    defer tree.deinit(std.testing.allocator);
    var hir = try AstGen.generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print_hir.renderAsText(hir, &output.writer);

    try std.testing.expectEqualStrings(
        \\%0 = root(%17)
        \\%1 = literal("one")
        \\%2 = word({%1}) src:2
        \\%3 = assignment("A", %2) src:2
        \\%4 = literal("echo")
        \\%5 = word({%4}) src:8
        \\%6 = double_quoted_parameter("name")
        \\%7 = word({%6}) src:13
        \\%8 = simple_command({%3, %5, %7}) src:2
        \\%9 = literal("consume")
        \\%10 = word({%9}) src:23
        \\%11 = literal("log")
        \\%12 = word({%11}) src:33
        \\%13 = redirect(output, io_number="2", target=%12) src:32
        \\%14 = simple_command({%10, %13}) src:23
        \\%15 = pipe(%8, %14)
        \\%16 = negated_pipeline(%15) src:0
        \\%17 = list({%16 background}) src:0
        \\
    , output.written());
}

test "rejects invalid ASTs" {
    var invalid = try Ast.parse(std.testing.allocator, "echo |");
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidAst,
        AstGen.generate(std.testing.allocator, invalid),
    );
}

test "AST generation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        generateWithAllocator,
        .{"build() { for item in first \"$second\"; do use $item; done; } >log"},
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
    return firstListCommand(hir, list);
}

fn firstListCommand(hir: Hir, list: Hir.Inst.Index) Hir.Inst.Index {
    return hir.listItem(list, 0).command;
}

fn firstWordPart(hir: Hir, word: Hir.Inst.Index) []const u8 {
    return hir.wordPart(hir.wordParts(word)[0]);
}
