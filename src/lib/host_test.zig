const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const FakeHost = @import("Host/FakeHost.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");

test "host rejects an empty executable before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{ .executable = "", .argv = &.{"command"} }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "host rejects an invalid portable sandbox policy before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const rules = [_]SandboxPolicy.NetworkRule{.{
        .protocol = .tcp,
        .operation = .connect,
        .ports = .{ .first = 9000, .last = 8000 },
    }};

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{
            .executable = "/bin/client",
            .argv = &.{"client"},
            .sandbox = .{ .restrict = .{
                .network = .{ .allow = &rules },
            } },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "host rejects invalid environment variables before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const environment = [_]CommandPlan.EnvironmentVariable{
        .{ .name = "INVALID=NAME", .value = "value" },
    };

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{
            .executable = "/bin/command",
            .argv = &.{"command"},
            .environment = .{ .overlay = &environment },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "host rejects empty working directory paths before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().resolveWorkingDirectory(std.testing.allocator, .{
            .current = null,
            .path = "",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.resolve_working_directory_calls.items.len);
}
