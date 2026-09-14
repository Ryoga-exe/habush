const std = @import("std");
const CommandResolver = @import("CommandResolver.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");

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

test "pre-resolved resolver preserves host-specific executable forms" {
    const windows_path = "C:\\tools\\command.exe";
    const resolved = (try CommandResolver.preResolved().resolve(std.testing.allocator, .{
        .name = windows_path,
        .search_path = &.{},
        .cwd = null,
    })).?;
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(windows_path, resolved);
}
