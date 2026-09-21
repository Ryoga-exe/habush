const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Expander = @import("Expander.zig");
const Hir = @import("Hir.zig");
const VariableStore = @import("VariableStore.zig");

test "expands and joins static argument parts" {
    var hir = try generate("command pre\"mid\"'post'\\ end \"\" \\* '*' \"*\"");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.init(arena.allocator());

    const joined = try expander.expandArgument(hir, parts[1]);
    try std.testing.expectEqual(@as(usize, 1), joined.len);
    try std.testing.expectEqualStrings("premidpost end", joined[0]);

    const empty = try expander.expandArgument(hir, parts[2]);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqualStrings("", empty[0]);

    for (parts[3..]) |word| {
        const quoted_pattern = try expander.expandArgument(hir, word);
        try std.testing.expectEqualStrings("*", quoted_pattern[0]);
    }
}

test "classifies unsupported argument expansions" {
    try expectExpansionError("command $@", error.FieldSplittingUnsupported);
    try expectExpansionError("command \"${name:-fallback}\"", error.ParameterExpansionUnsupported);
    try expectExpansionError("command *.zig", error.PathnameExpansionUnsupported);
    try expectExpansionError("command ~/work", error.TildeExpansionUnsupported);
}

test "expands named parameters inside double quotes" {
    var hir = try generate("command \"pre:$name:${missing}:post\"");
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];

    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "value with spaces");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = try Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    }).expandArgument(hir, word);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("pre:value with spaces::post", fields[0]);
}

test "expands scalar positional and special parameters" {
    var hir = try generate(
        "command \"$0\" \"$1\" \"${2}\" \"${10}\" \"$#\" \"$?\" \"$*\" $#",
    );
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    const parameters = [_][]const u8{
        "one", "two words", "three", "four", "five",
        "six", "seven",     "eight", "nine", "ten",
    };
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("IFS", ":");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
        .invocation_name = "script.hb",
        .positional_parameters = &parameters,
        .last_status = 23,
    });
    const expected = [_][]const u8{
        "script.hb",
        "one",
        "two words",
        "ten",
        "10",
        "23",
        "one:two words:three:four:five:six:seven:eight:nine:ten",
        "10",
    };
    for (parts[1..], expected) |word, value| {
        const fields = try expander.expandArgument(hir, word);
        try std.testing.expectEqual(@as(usize, 1), fields.len);
        try std.testing.expectEqualStrings(value, fields[0]);
    }
}

test "double-quoted at preserves positional parameter fields" {
    var hir = try generate("command pre\"$@\"post \"$@\" \"$@\"suffix");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    const parameters = [_][]const u8{ "one", "two words", "" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expander = Expander.initWithContext(arena.allocator(), .{
        .positional_parameters = &parameters,
    });
    const prefixed = try expander.expandArgument(hir, parts[1]);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "preone", "two words", "post" }),
        prefixed,
    );
    const standalone = try expander.expandArgument(hir, parts[2]);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "one", "two words", "" }),
        standalone,
    );
    const suffixed = try expander.expandArgument(hir, parts[3]);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "one", "two words", "suffix" }),
        suffixed,
    );

    const empty = try Expander.init(arena.allocator()).expandArgument(hir, parts[2]);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "splits unquoted parameters on default IFS whitespace" {
    var hir = try generate("command pre$name\"post\" $missing \"$name\" $1");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", " one  two ");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
        .positional_parameters = &.{"three four"},
    });

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "pre", "one", "two", "post" }),
        try expander.expandArgument(hir, parts[1]),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try expander.expandArgument(hir, parts[2])).len,
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{" one  two "}),
        try expander.expandArgument(hir, parts[3]),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "three", "four" }),
        try expander.expandArgument(hir, parts[4]),
    );
}

test "non-whitespace IFS delimiters preserve interior empty fields" {
    var hir = try generate("command pre$name\"post\"");
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("IFS", ":");
    try variables.set("name", ":a::b:");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fields = try Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    }).expandArgument(hir, word);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "pre", "a", "", "b", "post" }),
        fields,
    );
}

test "empty IFS disables field splitting" {
    var hir = try generate("command $name $missing");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("IFS", "");
    try variables.set("name", "one two");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{ .variables = &variables });

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"one two"}),
        try expander.expandArgument(hir, parts[1]),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try expander.expandArgument(hir, parts[2])).len,
    );
}

test "unquoted expansion defers generated patterns to pathname expansion" {
    var hir = try generate("command $pattern");
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("pattern", "*.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.PathnameExpansionUnsupported,
        Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
        }).expandArgument(hir, word),
    );
}

test "expands special parameters in assignment values" {
    var hir = try generate("result=$1 count=$# status=$? joined=$*");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .positional_parameters = &.{ "one", "two words" },
        .last_status = 7,
    });
    const expected = [_][]const u8{ "one", "2", "7", "one two words" };
    for (parts, expected) |part, value| {
        const assignment = hir.assignment(part);
        try std.testing.expectEqualStrings(
            value,
            try expander.expandAssignment(hir, assignment.value),
        );
    }
}

test "expands assignment values without field or pathname expansion" {
    var hir = try generate("result=pre$name:${missing}:*.zig");
    defer hir.deinit(std.testing.allocator);
    const assignment = hir.assignment(firstCommandParts(hir)[0]);

    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "value with spaces");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    }).expandAssignment(hir, assignment.value);

    try std.testing.expectEqualStrings("prevalue with spaces::*.zig", value);
}

test "classifies unsupported assignment expansion" {
    var hir = try generate("result=~/work");
    defer hir.deinit(std.testing.allocator);
    const assignment = hir.assignment(firstCommandParts(hir)[0]);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TildeExpansionUnsupported,
        Expander.init(arena.allocator()).expandAssignment(hir, assignment.value),
    );
}

test "argument expansion handles every allocation failure" {
    var hir = try generate("command pre\"mid\"'post'\\ end");
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expandWithAllocator,
        .{ hir, word },
    );
}

fn expectExpansionError(source: [:0]const u8, expected: anyerror) !void {
    var hir = try generate(source);
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        expected,
        Expander.init(arena.allocator()).expandArgument(hir, word),
    );
}

fn expandWithAllocator(
    gpa: std.mem.Allocator,
    hir: Hir,
    word: Hir.Inst.Index,
) !void {
    const fields = try Expander.init(gpa).expandArgument(hir, word);
    defer {
        for (fields) |field| gpa.free(field);
        gpa.free(fields);
    }
}

fn firstCommandParts(hir: Hir) []const Hir.Inst.Index {
    const list = hir.root().?;
    return hir.simpleCommandParts(hir.listItem(list, 0).command);
}

fn generate(source: [:0]const u8) !Hir {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}
