const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Expander = @import("Expander.zig");
const Hir = @import("Hir.zig");

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
    try expectExpansionError("command $name", error.ParameterExpansionUnsupported);
    try expectExpansionError("command *.zig", error.PathnameExpansionUnsupported);
    try expectExpansionError("command ~/work", error.TildeExpansionUnsupported);
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
