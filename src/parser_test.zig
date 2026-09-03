const std = @import("std");
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const heredoc = @import("heredoc.zig");
const Token = @import("tokenizer.zig").Token;

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

test "preserves an unfinished lexical token as a continuation" {
    var tree = try Ast.parse(std.testing.allocator, "echo 'open");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .lexical);
    try std.testing.expectEqual(
        Token.Tag.unterminated_single_quote,
        tree.tokenTag(tree.status.incomplete.lexical),
    );
    try std.testing.expect(tree.nodeData(.root).opt_node.unwrap() == null);
}

test "parses redirections in simple command source order" {
    var tree = try Ast.parse(std.testing.allocator, "echo 2>>error.log <input");
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.extraDataSlice(tree.nodeData(command).extra_range, Node.Index);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(parts[0]));

    const output = tree.redirect(parts[1]);
    try std.testing.expectEqualStrings("2", tree.tokenSlice(output.io_number.unwrap().?));
    try std.testing.expectEqualStrings(">>", tree.tokenSlice(tree.nodeMainToken(parts[1])));
    try std.testing.expectEqualStrings("error.log", tree.tokenSlice(output.target));

    const input = tree.redirect(parts[2]);
    try std.testing.expect(input.io_number.unwrap() == null);
    try std.testing.expectEqualStrings("<", tree.tokenSlice(tree.nodeMainToken(parts[2])));
    try std.testing.expectEqualStrings("input", tree.tokenSlice(input.target));
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
    const redirect = tree.redirect(parts[2]);
    try std.testing.expect(redirect.io_number.unwrap() == null);
}

test "requests continuation for a missing redirection target at EOF" {
    var tree = try Ast.parse(std.testing.allocator, "echo >");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .redirect_target);
    try std.testing.expectEqualStrings(
        ">",
        tree.tokenSlice(tree.status.incomplete.redirect_target),
    );
}

test "records a missing redirection target before a newline" {
    var tree = try Ast.parse(std.testing.allocator, "echo >\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_redirect_target, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.newline, tree.tokenTag(tree.errors[0].token));
}

test "records a ready here-document after newline" {
    var tree = try Ast.parse(std.testing.allocator, "cat <<EOF\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.here_documents.len);
    try std.testing.expectEqual(@as(u32, 1), tree.ready_here_document_count);

    const command = firstCommand(&tree);
    const parts = tree.simpleCommandParts(command);
    const redirect = tree.redirect(parts[1]);
    const document_index = redirect.here_document.unwrap().?;
    const document = tree.hereDocument(document_index);
    try std.testing.expectEqual(parts[1], document.redirect);
    try std.testing.expectEqualStrings("EOF", document.delimiter);
    try std.testing.expect(!document.strip_tabs);
    try std.testing.expect(document.expand_body);
}

test "records multiple here-documents in lexical order" {
    var tree = try Ast.parse(std.testing.allocator, "cat <<A <<-'B'\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), tree.here_documents.len);
    try std.testing.expectEqual(@as(u32, 2), tree.ready_here_document_count);

    const first = tree.hereDocument(@enumFromInt(0));
    try std.testing.expectEqualStrings("A", first.delimiter);
    try std.testing.expect(!first.strip_tabs);
    try std.testing.expect(first.expand_body);

    const second = tree.hereDocument(@enumFromInt(1));
    try std.testing.expectEqualStrings("B", second.delimiter);
    try std.testing.expect(second.strip_tabs);
    try std.testing.expect(!second.expand_body);
}

test "attaches a collected here-document body" {
    const collected = [_]heredoc.Collected{.{
        .delimiter = "EOF",
        .strip_tabs = false,
        .expand_body = true,
        .body = "hello\nworld\n",
    }};
    var tree = try Ast.parseWithOptions(std.testing.allocator, "cat <<EOF\n", .{
        .collected_here_documents = &collected,
    });
    defer tree.deinit(std.testing.allocator);

    const document = tree.hereDocument(@enumFromInt(0));
    try std.testing.expectEqualStrings("hello\nworld\n", document.body.?);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "keeps uncollected here-documents pending after collected ones" {
    const collected = [_]heredoc.Collected{.{
        .delimiter = "A",
        .strip_tabs = false,
        .expand_body = true,
        .body = "first\n",
    }};
    var tree = try Ast.parseWithOptions(std.testing.allocator, "cat <<A <<B\n", .{
        .collected_here_documents = &collected,
    });
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), tree.ready_here_document_count);
    try std.testing.expectEqualStrings("first\n", tree.hereDocument(@enumFromInt(0)).body.?);
    try std.testing.expect(tree.hereDocument(@enumFromInt(1)).body == null);
}

test "reports a collected here-document mismatch" {
    const collected = [_]heredoc.Collected{.{
        .delimiter = "OTHER",
        .strip_tabs = false,
        .expand_body = true,
        .body = "body\n",
    }};
    var tree = try Ast.parseWithOptions(std.testing.allocator, "cat <<EOF\n", .{
        .collected_here_documents = &collected,
    });
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.here_document_mismatch, tree.errors[0].tag);
    try std.testing.expect(tree.hereDocument(@enumFromInt(0)).body == null);
}

test "makes here-document ready before pipeline continuation" {
    var tree = try Ast.parse(std.testing.allocator, "cat <<EOF |\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), tree.ready_here_document_count);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .command_after);
}

fn firstCommand(tree: *const Ast) Node.Index {
    const list = tree.nodeData(.root).opt_node.unwrap().?;
    return tree.listItem(list, 0).command;
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

test "requests continuation for a missing pipeline command" {
    var tree = try Ast.parse(std.testing.allocator, "echo hi |");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .command_after);
    try std.testing.expectEqualStrings(
        "|",
        tree.tokenSlice(tree.status.incomplete.command_after),
    );
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

test "requests continuation for a missing and-or command" {
    var tree = try Ast.parse(std.testing.allocator, "first ||");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .command_after);
    try std.testing.expectEqualStrings(
        "||",
        tree.tokenSlice(tree.status.incomplete.command_after),
    );
}

test "parses semicolon newline and background list separators" {
    var tree = try Ast.parse(std.testing.allocator, "first; second\nthird &");
    defer tree.deinit(std.testing.allocator);

    const list = tree.nodeData(.root).opt_node.unwrap().?;
    try std.testing.expectEqual(@as(usize, 3), tree.listItemCount(list));

    const first = tree.listItem(list, 0);
    const second = tree.listItem(list, 1);
    const third = tree.listItem(list, 2);
    try std.testing.expectEqual(Token.Tag.semicolon, tree.tokenTag(first.separator.unwrap().?));
    try std.testing.expectEqual(Token.Tag.newline, tree.tokenTag(second.separator.unwrap().?));
    try std.testing.expectEqual(Token.Tag.ampersand, tree.tokenTag(third.separator.unwrap().?));
}

test "parses a subshell body and trailing redirection" {
    var tree = try Ast.parse(std.testing.allocator, "(echo; cat) 2>log");
    defer tree.deinit(std.testing.allocator);

    const subshell_node = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.subshell, tree.nodeTag(subshell_node));

    const subshell = tree.subshell(subshell_node);
    try std.testing.expectEqualStrings(")", tree.tokenSlice(subshell.close_token));
    const body = subshell.body.unwrap().?;
    try std.testing.expectEqual(@as(usize, 2), tree.listItemCount(body));

    const redirects = tree.extraDataSlice(.{
        .start = subshell.redirects_start,
        .end = subshell.redirects_end,
    }, Node.Index);
    try std.testing.expectEqual(@as(usize, 1), redirects.len);
    try std.testing.expectEqual(Node.Tag.redirect, tree.nodeTag(redirects[0]));
}

test "parses a subshell as a pipeline command" {
    var tree = try Ast.parse(std.testing.allocator, "producer | (filter; sink)");
    defer tree.deinit(std.testing.allocator);

    const pipeline = firstCommand(&tree);
    const children = tree.nodeData(pipeline).node_and_node;
    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(children[0]));
    try std.testing.expectEqual(Node.Tag.subshell, tree.nodeTag(children[1]));
}

test "requests continuation for an unclosed subshell" {
    var tree = try Ast.parse(std.testing.allocator, "(echo; cat");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .closing_paren);
    try std.testing.expectEqualStrings(
        "(",
        tree.tokenSlice(tree.status.incomplete.closing_paren),
    );
}

test "rejects an empty subshell" {
    var tree = try Ast.parse(std.testing.allocator, "()");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.r_paren, tree.tokenTag(tree.errors[0].token));
}

test "parses if elif else and trailing redirection" {
    const source =
        \\if test -f file; then
        \\  echo file
        \\elif test -d file; then
        \\  echo directory
        \\else
        \\  echo missing
        \\fi >result
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    const if_node = firstCommand(&tree);
    try std.testing.expectEqual(Node.Tag.if_clause, tree.nodeTag(if_node));
    const clause = tree.ifClause(if_node);
    try std.testing.expect(clause.condition.unwrap() != null);
    try std.testing.expect(clause.then_token.unwrap() != null);
    try std.testing.expect(clause.then_body.unwrap() != null);
    try std.testing.expectEqual(@as(usize, 1), tree.elifBranchCount(clause));
    try std.testing.expect(tree.elifBranch(clause, 0).body.unwrap() != null);
    try std.testing.expect(clause.else_token.unwrap() != null);
    try std.testing.expect(clause.else_body.unwrap() != null);
    try std.testing.expectEqualStrings("fi", tree.tokenSlice(clause.fi_token.unwrap().?));

    const redirects = tree.extraDataSlice(.{
        .start = clause.redirects_start,
        .end = clause.redirects_end,
    }, Node.Index);
    try std.testing.expectEqual(@as(usize, 1), redirects.len);
    try std.testing.expectEqual(Node.Tag.redirect, tree.nodeTag(redirects[0]));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .complete);
}

test "keyword candidates remain words in argument position" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "echo if then elif else fi while until do done",
    );
    defer tree.deinit(std.testing.allocator);

    const command = firstCommand(&tree);
    const parts = tree.simpleCommandParts(command);
    try std.testing.expectEqual(@as(usize, 10), parts.len);
    for (parts) |part| {
        try std.testing.expectEqual(Node.Tag.word, tree.nodeTag(part));
    }
}

test "quoted if remains a simple command word" {
    var tree = try Ast.parse(std.testing.allocator, "'if' true");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(Node.Tag.simple_command, tree.nodeTag(firstCommand(&tree)));
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "parses nested if clauses" {
    const source =
        \\if outer; then
        \\  if inner; then
        \\    echo nested
        \\  fi
        \\fi
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    const outer = tree.ifClause(firstCommand(&tree));
    const outer_body = outer.then_body.unwrap().?;
    const inner = tree.listItem(outer_body, 0).command;
    try std.testing.expectEqual(Node.Tag.if_clause, tree.nodeTag(inner));
    try std.testing.expect(tree.ifClause(inner).fi_token.unwrap() != null);
}

test "reports each incomplete if stage" {
    try expectCompoundContinuation(
        "if",
        .if_clause,
        .condition,
    );
    try expectCompoundContinuation(
        "if true",
        .if_clause,
        .then_keyword,
    );
    try expectCompoundContinuation(
        "if true; then",
        .if_clause,
        .body,
    );
    try expectCompoundContinuation(
        "if true; then echo yes",
        .if_clause,
        .fi_keyword,
    );
    try expectCompoundContinuation(
        "if true; then echo yes; elif",
        .elif_clause,
        .condition,
    );
    try expectCompoundContinuation(
        "if true; then echo yes; else",
        .else_clause,
        .body,
    );
}

test "rejects a reserved word at command start" {
    var tree = try Ast.parse(std.testing.allocator, "then");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.errors.len);
    try std.testing.expectEqual(Ast.Error.Tag.expected_command, tree.errors[0].tag);
    try std.testing.expectEqual(Token.Tag.keyword_then, tree.tokenTag(tree.errors[0].token));
}

test "parses while and until clauses" {
    var while_tree = try Ast.parse(
        std.testing.allocator,
        "while check; do work; done >log",
    );
    defer while_tree.deinit(std.testing.allocator);

    const while_node = firstCommand(&while_tree);
    try std.testing.expectEqual(Node.Tag.while_clause, while_tree.nodeTag(while_node));
    const while_clause = while_tree.loopClause(while_node);
    try std.testing.expect(while_clause.condition.unwrap() != null);
    try std.testing.expect(while_clause.do_token.unwrap() != null);
    try std.testing.expect(while_clause.body.unwrap() != null);
    try std.testing.expectEqualStrings("done", while_tree.tokenSlice(while_clause.done_token.unwrap().?));
    const redirects = while_tree.extraDataSlice(.{
        .start = while_clause.redirects_start,
        .end = while_clause.redirects_end,
    }, Node.Index);
    try std.testing.expectEqual(@as(usize, 1), redirects.len);

    var until_tree = try Ast.parse(
        std.testing.allocator,
        "until ready; do wait; done",
    );
    defer until_tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(Node.Tag.until_clause, until_tree.nodeTag(firstCommand(&until_tree)));
    try std.testing.expectEqual(@as(usize, 0), until_tree.errors.len);
}

test "parses a nested loop clause" {
    const source =
        \\while outer; do
        \\  until inner; do
        \\    step
        \\  done
        \\done
        \\
    ;
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    const outer = tree.loopClause(firstCommand(&tree));
    const inner = tree.listItem(outer.body.unwrap().?, 0).command;
    try std.testing.expectEqual(Node.Tag.until_clause, tree.nodeTag(inner));
    try std.testing.expect(tree.loopClause(inner).done_token.unwrap() != null);
}

test "reports each incomplete loop stage" {
    try expectCompoundContinuation("while", .while_clause, .condition);
    try expectCompoundContinuation("while check", .while_clause, .do_keyword);
    try expectCompoundContinuation("while check; do", .while_clause, .body);
    try expectCompoundContinuation("while check; do work", .while_clause, .done_keyword);

    try expectCompoundContinuation("until", .until_clause, .condition);
    try expectCompoundContinuation("until ready", .until_clause, .do_keyword);
    try expectCompoundContinuation("until ready; do", .until_clause, .body);
    try expectCompoundContinuation("until ready; do wait", .until_clause, .done_keyword);
}

test "makes a loop here-document ready before syntax continuation" {
    var tree = try Ast.parse(std.testing.allocator, "while read <<EOF\n");
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), tree.ready_here_document_count);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .compound);
    try std.testing.expectEqual(
        Ast.CompoundContinuation.Expected.do_keyword,
        tree.status.incomplete.compound.expected,
    );
}

fn expectCompoundContinuation(
    source: [:0]const u8,
    kind: Ast.CompoundContinuation.Kind,
    expected: Ast.CompoundContinuation.Expected,
) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(tree.status == .incomplete);
    try std.testing.expect(tree.status.incomplete == .compound);
    try std.testing.expectEqual(kind, tree.status.incomplete.compound.kind);
    try std.testing.expectEqual(expected, tree.status.incomplete.compound.expected);
}
