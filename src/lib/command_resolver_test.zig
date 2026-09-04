const std = @import("std");
const CommandResolver = @import("CommandResolver.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");

test "fake resolver records owned session inputs" {
    var fake = FakeResolver.init(std.testing.allocator);
    defer fake.deinit();
    fake.result = "/usr/bin/echo";

    var name = [_]u8{ 'e', 'c', 'h', 'o' };
    var first_path = [_]u8{ '/', 'b', 'i', 'n' };
    const search_path = [_][]const u8{ &first_path, "/usr/bin" };
    const resolved = (try fake.resolver().resolve(std.testing.allocator, .{
        .name = &name,
        .search_path = &search_path,
        .cwd = "/workspace",
    })).?;
    defer std.testing.allocator.free(resolved);

    name[0] = 'x';
    first_path[1] = 'x';

    try std.testing.expectEqualStrings("/usr/bin/echo", resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    const call = fake.calls.items[0];
    try std.testing.expectEqualStrings("echo", call.name);
    try std.testing.expectEqualStrings("/bin", call.search_path[0]);
    try std.testing.expectEqualStrings("/usr/bin", call.search_path[1]);
    try std.testing.expectEqualStrings("/workspace", call.cwd.?);
}

test "resolver skips empty command names" {
    var fake = FakeResolver.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expect(try fake.resolver().resolve(std.testing.allocator, .{
        .name = "",
        .search_path = &.{},
        .cwd = null,
    }) == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "fake resolver handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveWithAllocator,
        .{},
    );
}

fn resolveWithAllocator(gpa: std.mem.Allocator) !void {
    var fake = FakeResolver.init(gpa);
    defer fake.deinit();
    fake.result = "/usr/bin/command";

    const resolved = (try fake.resolver().resolve(gpa, .{
        .name = "command",
        .search_path = &.{ "/bin", "/usr/bin" },
        .cwd = "/workspace",
    })).?;
    defer gpa.free(resolved);
}
