const std = @import("std");
const VariableStore = @import("VariableStore.zig");

test "variable store owns names and values" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try variables.set(&name, &value);
    name[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqualStrings("value", variables.get("name").?);
    try std.testing.expect(variables.get("xame") == null);
}

test "variable store replaces and removes values" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    try variables.set("name", "first");
    try variables.set("name", "second");
    try std.testing.expectEqualStrings("second", variables.get("name").?);
    try std.testing.expect(variables.unset("name"));
    try std.testing.expect(!variables.unset("name"));
    try std.testing.expect(variables.get("name") == null);
}

test "failed replacement preserves the previous value" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var variables = VariableStore.init(failing.allocator());
    defer variables.deinit();
    try variables.set("name", "previous");

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, variables.set("name", "replacement"));
    try std.testing.expectEqualStrings("previous", variables.get("name").?);
}

test "variable store rejects invalid names" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const invalid_names = [_][]const u8{ "", "1name", "not-valid" };
    for (invalid_names) |name| {
        try std.testing.expectError(error.InvalidName, variables.set(name, "value"));
    }
}

test "variable store handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        setWithAllocator,
        .{},
    );
}

fn setWithAllocator(gpa: std.mem.Allocator) !void {
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    try variables.set("first", "one");
    try variables.set("second", "two");
    try variables.set("first", "replacement");
}
