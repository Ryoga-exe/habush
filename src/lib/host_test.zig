const std = @import("std");
const Host = @import("Host.zig");
const FakeHost = @import("Host/FakeHost.zig");

test "fake host records owned spawn options and wait calls" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    var command = [_]u8{ 'e', 'c', 'h', 'o' };
    var value = [_]u8{ 'b', 'a', 'r' };
    const argv = [_][]const u8{ &command, "hello" };
    const environment = [_]Host.EnvironmentVariable{
        .{ .name = "FOO", .value = &value },
    };

    const host = fake.host();
    const process = try host.spawn(.{
        .argv = &argv,
        .environment = &environment,
        .cwd = "/tmp/example",
    });

    command[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const call = fake.spawn_calls.items[0];
    try std.testing.expectEqualStrings("echo", call.argv[0]);
    try std.testing.expectEqualStrings("hello", call.argv[1]);
    try std.testing.expectEqualStrings("FOO", call.environment.?[0].name);
    try std.testing.expectEqualStrings("bar", call.environment.?[0].value);
    try std.testing.expectEqualStrings("/tmp/example", call.cwd.?);

    fake.termination = .{ .exited = 23 };
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 23 },
        try host.wait(process),
    );
    try std.testing.expectEqualSlices(
        Host.Process,
        &.{process},
        fake.wait_calls.items,
    );
}

test "host rejects an empty command before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{ .argv = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "fake host returns configured errors" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    fake.spawn_error = error.CommandNotFound;
    try std.testing.expectError(
        error.CommandNotFound,
        fake.host().spawn(.{ .argv = &.{"missing"} }),
    );
}
