const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Executor = @import("Executor.zig");
const FakeHost = @import("Host/FakeHost.zig");

test "executes static simple commands through the host" {
    var hir = try generate("echo 'hello world' x\\ y \"\"");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 7 };

    const status = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 7), status);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const argv = fake.spawn_calls.items[0].argv;
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("echo", argv[0]);
    try std.testing.expectEqualStrings("hello world", argv[1]);
    try std.testing.expectEqualStrings("x y", argv[2]);
    try std.testing.expectEqualStrings("", argv[3]);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
}

test "executes sequential lists and returns the last status" {
    var hir = try generate("first; second\nthird");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .signal = 9 };

    const status = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 137), status);
    try std.testing.expectEqual(@as(usize, 3), fake.spawn_calls.items.len);
    try std.testing.expectEqualStrings("first", fake.spawn_calls.items[0].argv[0]);
    try std.testing.expectEqualStrings("second", fake.spawn_calls.items[1].argv[0]);
    try std.testing.expectEqualStrings("third", fake.spawn_calls.items[2].argv[0]);
}

test "empty HIR succeeds without host calls" {
    var hir = try generate("");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const status = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "unsupported expansion has no host side effects" {
    var hir = try generate("echo $name");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.UnsupportedInstruction,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "pathname expansion is not executed as a literal argument" {
    var hir = try generate("echo *.zig");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.UnsupportedInstruction,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "background execution has no host side effects" {
    var hir = try generate("sleep &");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.UnsupportedInstruction,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

fn generate(source: [:0]const u8) !@import("Hir.zig") {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}
