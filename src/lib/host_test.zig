const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const Host = @import("Host.zig");
const FakeHost = @import("Host/FakeHost.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");

test "fake host records owned spawn options and wait calls" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    var command = [_]u8{ 'e', 'c', 'h', 'o' };
    var value = [_]u8{ 'b', 'a', 'r' };
    var output_path = [_]u8{ 'o', 'u', 't' };
    var allowed_path = [_]u8{ '/', 'u', 's', 'r' };
    const argv = [_][]const u8{ &command, "hello" };
    const environment = [_]CommandPlan.EnvironmentVariable{
        .{ .name = "FOO", .value = &value },
    };
    const actions = [_]CommandPlan.FileAction{
        .{ .duplicate = .{ .source = .stdout, .target = .stderr } },
        .{ .open = .{
            .path = &output_path,
            .target = .stdout,
            .access = .write,
            .disposition = .create_or_truncate,
        } },
    };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = &allowed_path, .access = .{ .read = true } },
    };

    const host = fake.host();
    const spawned = try host.spawn(.{
        .executable = "/bin/echo",
        .argv = &argv,
        .environment = .{ .overlay = &environment },
        .cwd = .{ .path = "/tmp/example" },
        .file_actions = &actions,
        .process_group = .create,
        .sandbox = .{ .restrict = .{
            .file_system = .{ .allow = &rules },
        } },
    });

    command[0] = 'x';
    value[0] = 'x';
    output_path[0] = 'x';
    allowed_path[1] = 'x';

    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const call = fake.spawn_calls.items[0];
    try std.testing.expectEqualStrings("/bin/echo", call.executable);
    try std.testing.expectEqualStrings("echo", call.argv[0]);
    try std.testing.expectEqualStrings("hello", call.argv[1]);
    try std.testing.expectEqualStrings("FOO", call.environment.overlay[0].name);
    try std.testing.expectEqualStrings("bar", call.environment.overlay[0].value);
    try std.testing.expectEqualStrings("/tmp/example", call.cwd.path);
    try std.testing.expectEqual(CommandPlan.ProcessGroupAction.create, call.process_group);
    try std.testing.expectEqualStrings("out", call.file_actions[1].open.path);
    try std.testing.expectEqualStrings(
        "/usr",
        call.sandbox.restrict.file_system.allow[0].path,
    );
    try std.testing.expect(spawned.process_group != null);
    try std.testing.expectEqual(
        SandboxPolicy.Coverage.complete,
        spawned.sandbox_coverage,
    );

    fake.termination = .{ .exited = 23 };
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 23 },
        try host.wait(spawned.process),
    );
    try std.testing.expectEqualSlices(
        Host.Process,
        &.{spawned.process},
        fake.wait_calls.items,
    );
}

test "host rejects an empty command before dispatch" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{ .executable = "", .argv = &.{} }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        fake.host().spawn(.{ .executable = "echo", .argv = &.{"echo"} }),
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

test "fake host returns configured errors" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    fake.spawn_error = error.CommandNotFound;
    try std.testing.expectError(
        error.CommandNotFound,
        fake.host().spawn(.{ .executable = "/missing", .argv = &.{"missing"} }),
    );
}

test "fake host recording handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordPlanWithAllocator,
        .{},
    );
}

fn recordPlanWithAllocator(gpa: std.mem.Allocator) !void {
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    const environment = [_]CommandPlan.EnvironmentVariable{
        .{ .name = "NAME", .value = "value" },
    };
    const actions = [_]CommandPlan.FileAction{.{ .open = .{
        .path = "output",
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_truncate,
    } }};
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/workspace", .access = .{ .read = true, .write = true } },
    };

    _ = try fake.host().spawn(.{
        .executable = "/bin/command",
        .argv = &.{ "command", "argument" },
        .environment = .{ .replace = &environment },
        .cwd = .{ .path = "/workspace" },
        .file_actions = &actions,
        .sandbox = .{ .restrict = .{
            .file_system = .{ .allow = &rules },
        } },
    });
}
