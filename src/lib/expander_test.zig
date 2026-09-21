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
    try expectExpansionError("command ${#name}", error.ParameterExpansionUnsupported);
    try expectExpansionError("command *.zig", error.PathnameExpansionUnsupported);
    try expectExpansionError("command ~other/work", error.TildeExpansionUnsupported);
}

test "expands the shell process id" {
    var hir = try generate("command \"$$\"");
    defer hir.deinit(std.testing.allocator);
    const part = firstCommandParts(hir)[1];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"12345"}),
        try Expander.initWithContext(arena.allocator(), .{
            .shell_process_id = @enumFromInt(12345),
        }).expandArgument(hir, part),
    );
}

test "error parameter operators expose expanded failure details" {
    var hir = try generate("command \"${missing?custom $message}\"");
    defer hir.deinit(std.testing.allocator);
    const part = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("message", "message");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: Expander.Failure = undefined;

    try std.testing.expectError(
        error.ParameterExpansionFailed,
        Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
            .failure = &failure,
        }).expandArgument(hir, part),
    );
    defer failure.deinit(arena.allocator());
    try std.testing.expectEqualStrings("missing", failure.parameter);
    try std.testing.expectEqualStrings("custom message", failure.message);
}

test "colon error parameter operator rejects null values" {
    var hir = try generate("command \"${empty:?}\"");
    defer hir.deinit(std.testing.allocator);
    const part = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("empty", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: Expander.Failure = undefined;

    try std.testing.expectError(
        error.ParameterExpansionFailed,
        Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
            .failure = &failure,
        }).expandArgument(hir, part),
    );
    defer failure.deinit(arena.allocator());
    try std.testing.expectEqualStrings("empty", failure.parameter);
    try std.testing.expectEqualStrings("parameter null or not set", failure.message);
}

test "expands current user tilde without field splitting" {
    var hir = try generate("command ~ ~/work ${missing:-~/fallback}");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("HOME", "/home/test user");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    });
    const expected = [_][]const u8{
        "/home/test user",
        "/home/test user/work",
        "/home/test user/fallback",
    };

    for (parts[1..], expected) |part, value| {
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{value}),
            try expander.expandArgument(hir, part),
        );
    }
}

test "default parameter operators distinguish unset and null values" {
    var hir = try generate(
        "command \"${missing-fallback}\" \"${empty-fallback}\" " ++
            "\"${empty:-fallback}\" \"${present:-fallback}\"",
    );
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("empty", "");
    try variables.set("present", "value");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    });

    const expected = [_][]const u8{ "fallback", "", "fallback", "value" };
    for (parts[1..], expected) |part, value| {
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{value}),
            try expander.expandArgument(hir, part),
        );
    }
}

test "default parameter operators support positional parameters" {
    var hir = try generate("command \"${0:-habush}\" \"${1:-first}\" \"${2:-second}\"");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .invocation_name = "script.hb",
        .positional_parameters = &.{""},
    });

    const expected = [_][]const u8{ "script.hb", "first", "second" };
    for (parts[1..], expected) |part, value| {
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{value}),
            try expander.expandArgument(hir, part),
        );
    }
}

test "alternative parameter operators distinguish set and non-null values" {
    var hir = try generate(
        "command \"${missing+alternative}\" \"${empty+alternative}\" " ++
            "\"${empty:+alternative}\" \"${present:+alternative}\"",
    );
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("empty", "");
    try variables.set("present", "value");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    });

    const expected = [_][]const u8{ "", "alternative", "", "alternative" };
    for (parts[1..], expected) |part, value| {
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{value}),
            try expander.expandArgument(hir, part),
        );
    }
}

test "unquoted empty alternative expansions contribute no fields" {
    var hir = try generate("command ${missing+word} ${empty:+word}");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("empty", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    });

    for (parts[1..]) |part| {
        try std.testing.expectEqual(
            @as(usize, 0),
            (try expander.expandArgument(hir, part)).len,
        );
    }
}

test "assignment parameter operators update named variables" {
    var hir = try generate(
        "command \"${missing=default}\" \"${empty=other}\" " ++
            "\"${empty:=assigned}\"",
    );
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("empty", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.initWithContext(arena.allocator(), .{
        .variables = &variables,
    });

    const expected = [_][]const u8{ "default", "", "assigned" };
    for (parts[1..], expected) |part, value| {
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{value}),
            try expander.expandArgument(hir, part),
        );
    }
    try std.testing.expectEqualStrings("default", variables.get("missing").?);
    try std.testing.expectEqualStrings("assigned", variables.get("empty").?);
}

test "unquoted assigned values undergo field splitting after assignment" {
    var hir = try generate("command ${missing:=one two}");
    defer hir.deinit(std.testing.allocator);
    const part = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "one", "two" }),
        try Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
        }).expandArgument(hir, part),
    );
    try std.testing.expectEqualStrings("one two", variables.get("missing").?);
}

test "assignment parameter operators require mutable variable state" {
    var hir = try generate("command ${missing:=value}");
    defer hir.deinit(std.testing.allocator);
    const part = firstCommandParts(hir)[1];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.ParameterAssignmentUnavailable,
        Expander.init(arena.allocator()).expandArgument(hir, part),
    );
}

test "unquoted default words retain their own quoting during field splitting" {
    var hir = try generate(
        "command ${missing:-one two} ${missing:-\"three four\"} " ++
            "pre${missing:-five six}post",
    );
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.init(arena.allocator());

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "one", "two" }),
        try expander.expandArgument(hir, parts[1]),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"three four"}),
        try expander.expandArgument(hir, parts[2]),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "prefive", "sixpost" }),
        try expander.expandArgument(hir, parts[3]),
    );
}

test "default parameter words recursively expand parameters" {
    var hir = try generate("command \"${missing:-${other:-nested value}}\"");
    defer hir.deinit(std.testing.allocator);
    const word_inst = firstCommandParts(hir)[1];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"nested value"}),
        try Expander.init(arena.allocator()).expandArgument(hir, word_inst),
    );
}

test "quoted default words inherit double quote parsing rules" {
    var hir = try generate("command \"${missing:-'literal' a\\qb $name}\"");
    defer hir.deinit(std.testing.allocator);
    const word_inst = firstCommandParts(hir)[1];
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "value");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"'literal' a\\qb value"}),
        try Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
        }).expandArgument(hir, word_inst),
    );
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
        "command \"$0\" \"$1\" \"${2}\" \"${10}\" \"$#\" \"$?\" \"$*\" $# \"$-\" \"$!\"",
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
        "",
        "",
    };
    for (parts[1..], expected) |word, value| {
        const fields = try expander.expandArgument(hir, word);
        try std.testing.expectEqual(@as(usize, 1), fields.len);
        try std.testing.expectEqualStrings(value, fields[0]);
    }
}

test "conditional operators recognize inactive shell special parameters" {
    var hir = try generate("command \"${-:-options}\" \"${!-background}\"");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.init(arena.allocator());

    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"options"}),
        try expander.expandArgument(hir, parts[1]),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"background"}),
        try expander.expandArgument(hir, parts[2]),
    );
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

test "unquoted at splits each positional parameter independently" {
    var hir = try generate("command $@ pre$@post");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    const parameters = [_][]const u8{ "", "one two", "", "three", "" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expander = Expander.initWithContext(arena.allocator(), .{
        .positional_parameters = &parameters,
    });
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "one", "two", "three" }),
        try expander.expandArgument(hir, parts[1]),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "pre", "one", "two", "three", "post" }),
        try expander.expandArgument(hir, parts[2]),
    );
}

test "unquoted at with no positional parameters contributes no fields" {
    var hir = try generate("command $@ pre$@post");
    defer hir.deinit(std.testing.allocator);
    const parts = firstCommandParts(hir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expander = Expander.init(arena.allocator());

    try std.testing.expectEqual(
        @as(usize, 0),
        (try expander.expandArgument(hir, parts[1])).len,
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{"prepost"}),
        try expander.expandArgument(hir, parts[2]),
    );
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

test "default parameter words expand in assignment values without field splitting" {
    var hir = try generate("result=${missing:-pre\"$name\" post}");
    defer hir.deinit(std.testing.allocator);
    const assignment = hir.assignment(firstCommandParts(hir)[0]);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "middle value");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "premiddle value post",
        try Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
        }).expandAssignment(hir, assignment.value),
    );
}

test "classifies unsupported assignment expansion" {
    var hir = try generate("result=~other/work");
    defer hir.deinit(std.testing.allocator);
    const assignment = hir.assignment(firstCommandParts(hir)[0]);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TildeExpansionUnsupported,
        Expander.init(arena.allocator()).expandAssignment(hir, assignment.value),
    );
}

test "expands current user tilde in assignment values" {
    var hir = try generate("result=~/work");
    defer hir.deinit(std.testing.allocator);
    const assignment = hir.assignment(firstCommandParts(hir)[0]);
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("HOME", "/home/test user");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "/home/test user/work",
        try Expander.initWithContext(arena.allocator(), .{
            .variables = &variables,
        }).expandAssignment(hir, assignment.value),
    );
}

test "argument expansion handles every allocation failure" {
    var hir = try generate("command pre\"${missing:-mid value}\"'post'\\ end");
    defer hir.deinit(std.testing.allocator);
    const word = firstCommandParts(hir)[1];

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expandWithAllocator,
        .{ hir, word },
    );
}

test "parameter assignment handles every allocation failure" {
    var hir = try generate("command ${missing:=one two}");
    defer hir.deinit(std.testing.allocator);
    const word_inst = firstCommandParts(hir)[1];

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expandAssignmentParameterWithAllocator,
        .{ hir, word_inst },
    );
}

test "parameter failure handles every allocation failure" {
    var hir = try generate("command ${missing:?custom message}");
    defer hir.deinit(std.testing.allocator);
    const word_inst = firstCommandParts(hir)[1];

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expandFailureWithAllocator,
        .{ hir, word_inst },
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

fn expandAssignmentParameterWithAllocator(
    gpa: std.mem.Allocator,
    hir: Hir,
    word_inst: Hir.Inst.Index,
) !void {
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    const fields = try Expander.initWithContext(gpa, .{
        .variables = &variables,
    }).expandArgument(hir, word_inst);
    defer {
        for (fields) |field| gpa.free(field);
        gpa.free(fields);
    }
}

fn expandFailureWithAllocator(
    gpa: std.mem.Allocator,
    hir: Hir,
    word_inst: Hir.Inst.Index,
) !void {
    var failure: Expander.Failure = undefined;
    _ = Expander.initWithContext(gpa, .{
        .failure = &failure,
    }).expandArgument(hir, word_inst) catch |err| switch (err) {
        error.ParameterExpansionFailed => {
            failure.deinit(gpa);
            return;
        },
        else => |other| return other,
    };
    return error.ExpectedParameterExpansionFailure;
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
