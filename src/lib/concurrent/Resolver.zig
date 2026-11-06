//! Serializes calls to a resolver shared by concurrent pipeline stages.
//!
//! The wrapped resolver must be used exclusively through this adapter while
//! stages run. The caller's result allocator has its own thread-safety contract.

const std = @import("std");
const CommandResolver = @import("../CommandResolver.zig");
const ConcurrentResolver = @This();

inner: CommandResolver,
io: std.Io,
mutex: std.Io.Mutex = .init,

pub fn resolver(self: *ConcurrentResolver) CommandResolver {
    return .{ .userdata = self, .vtable = &vtable };
}

const vtable: CommandResolver.VTable = .{ .resolve = resolve };

fn resolve(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: CommandResolver.Request,
) CommandResolver.Error!?[]u8 {
    const self: *ConcurrentResolver = @ptrCast(@alignCast(userdata.?));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.resolve(allocator, request);
}

test "delegates command resolution through a shared lock" {
    const FakeResolver = @import("../CommandResolver/FakeResolver.zig");
    var fake = FakeResolver.init(std.testing.allocator);
    defer fake.deinit();
    fake.result = "/bin/hello";
    var adapter: ConcurrentResolver = .{ .inner = fake.resolver(), .io = std.testing.io };

    const result = (try adapter.resolver().resolve(std.testing.allocator, .{
        .name = "hello",
        .search_path = &.{"/bin"},
        .cwd = "/work",
    })).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/bin/hello", result);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expectEqualStrings("hello", fake.calls.items[0].name);
}
