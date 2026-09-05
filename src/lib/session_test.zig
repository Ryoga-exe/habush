const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const CommandPlan = @import("CommandPlan.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");
const FakeHost = @import("Host/FakeHost.zig");
const Hir = @import("Hir.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const Session = @import("Session.zig");

test "session owns runtime configuration and executes with it" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    fake_host.termination = .{ .exited = 4 };
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/usr/bin/echo";

    var cwd = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    var bin = [_]u8{ '/', 'b', 'i', 'n' };
    var allowed = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    var variable_name = [_]u8{ 'g', 'r', 'e', 'e', 't', 'i', 'n', 'g' };
    var variable_value = [_]u8{ 'f', 'r', 'o', 'm', ' ', 's', 'e', 's', 's', 'i', 'o', 'n' };
    const search_path = [_][]const u8{ &bin, "/usr/bin" };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = &allowed, .access = .{ .read = true } },
    };
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .cwd = &cwd,
        .search_path = &search_path,
        .sandbox = .{ .restrict = .{
            .file_system = .{ .allow = &rules },
        } },
        .variables = &.{
            .{ .name = &variable_name, .value = &variable_value },
        },
    });
    defer session.deinit();

    cwd[1] = 'x';
    bin[1] = 'x';
    allowed[1] = 'x';
    variable_name[0] = 'x';
    variable_value[0] = 'x';

    try std.testing.expectEqualStrings("/work", session.workingDirectory().?);
    try std.testing.expectEqualStrings("/bin", session.commandSearchPath()[0]);
    try std.testing.expectEqualStrings(
        "/work",
        session.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expectEqualStrings("from session", session.variable("greeting").?);

    var hir = try generate("echo \"$greeting\"");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 4), result.status);
    try std.testing.expectEqualDeep(result, session.lastResult());
    try std.testing.expectEqualStrings("/work", fake_resolver.calls.items[0].cwd.?);
    try std.testing.expectEqualStrings("/usr/bin/echo", fake_host.spawn_calls.items[0].executable);
    try std.testing.expectEqualStrings("from session", fake_host.spawn_calls.items[0].argv[1]);
    try std.testing.expectEqualStrings("/work", fake_host.spawn_calls.items[0].cwd.path);
}

test "session replaces owned runtime configuration" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    try session.setWorkingDirectory("/new");
    try session.setCommandSearchPath(&.{ "/one", "/two" });
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/new", .access = .{ .write = true } },
    };
    try session.setSandbox(.{ .restrict = .{
        .file_system = .{ .allow = &rules },
    } });
    try session.setVariable("name", "value");

    try std.testing.expectEqualStrings("/new", session.workingDirectory().?);
    try std.testing.expectEqual(@as(usize, 2), session.commandSearchPath().len);
    try std.testing.expectEqualStrings(
        "/new",
        session.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expectEqualStrings("value", session.variable("name").?);
    try std.testing.expect(session.unsetVariable("name"));
    try std.testing.expect(session.variable("name") == null);
}

test "session persists assignments across commands" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var hir = try generate("first=one; second=\"$first two\"");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("one", session.variable("first").?);
    try std.testing.expectEqualStrings("one two", session.variable("second").?);
    try std.testing.expectEqualDeep(result, session.lastResult());
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "session initialization handles every allocation failure" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initWithAllocator,
        .{ fake_host.host(), fake_resolver.resolver() },
    );
}

test "session rejects an invalid initial variable name" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();

    try std.testing.expectError(
        error.InvalidName,
        Session.init(std.testing.allocator, fake_host.host(), .{
            .variables = &.{.{ .name = "not-valid", .value = "value" }},
        }),
    );
}

fn initWithAllocator(
    gpa: std.mem.Allocator,
    host: @import("Host.zig"),
    resolver: @import("CommandResolver.zig"),
) !void {
    const path = [_][]const u8{ "/bin", "/usr/bin" };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/workspace", .access = .{ .read = true, .write = true } },
    };
    var session = try Session.init(gpa, host, .{
        .resolver = resolver,
        .cwd = "/workspace",
        .search_path = &path,
        .sandbox = CommandPlan.Sandbox{ .restrict = .{
            .file_system = .{ .allow = &rules },
        } },
        .variables = &.{
            .{ .name = "first", .value = "one" },
            .{ .name = "second", .value = "two" },
        },
    });
    defer session.deinit();
}

fn generate(source: [:0]const u8) !Hir {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}
