const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");
const Host = @import("Host.zig");
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
            .{ .name = &variable_name, .value = &variable_value, .exported = true },
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
    try std.testing.expect(session.isVariableExported("greeting"));

    var hir = try generate("echo \"$greeting\"");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 4), result.status);
    try std.testing.expectEqualDeep(result, session.lastResult());
    try std.testing.expectEqualStrings("/work", fake_resolver.calls.items[0].cwd.?);
    try std.testing.expectEqualStrings("/usr/bin/echo", fake_host.spawn_calls.items[0].executable);
    try std.testing.expectEqualStrings("from session", fake_host.spawn_calls.items[0].argv[1]);
    try std.testing.expectEqualStrings(
        "greeting",
        fake_host.spawn_calls.items[0].environment.replace[0].name,
    );
    try std.testing.expectEqualStrings(
        "from session",
        fake_host.spawn_calls.items[0].environment.replace[0].value,
    );
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
    try session.setVariableExported("name", true);

    try std.testing.expectEqualStrings("/new", session.workingDirectory().?);
    try std.testing.expectEqual(@as(usize, 2), session.commandSearchPath().len);
    try std.testing.expectEqualStrings(
        "/new",
        session.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expectEqualStrings("value", session.variable("name").?);
    try std.testing.expect(session.isVariableExported("name"));
    try session.setVariableExported("name", false);
    try std.testing.expect(!session.isVariableExported("name"));
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

test "session carries the previous status into exit" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var false_hir = try generate("false");
    defer false_hir.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), (try session.execute(false_hir)).status);

    var exit_hir = try generate("exit");
    defer exit_hir.deinit(std.testing.allocator);
    const result = try session.execute(exit_hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);

    const overridden = try session.executeWithOptions(exit_hir, .{ .last_status = 2 });
    try std.testing.expectEqual(@as(u8, 2), overridden.status);
    try std.testing.expectEqual(.exit, overridden.control_flow);
}

test "session executes export and unset builtins" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var export_hir = try generate("PREFIX=one export PREFIX DIRECT=two");
    defer export_hir.deinit(std.testing.allocator);
    const export_result = try session.execute(export_hir);

    try std.testing.expectEqual(@as(u8, 0), export_result.status);
    try std.testing.expectEqualStrings("one", session.variable("PREFIX").?);
    try std.testing.expect(session.isVariableExported("PREFIX"));
    try std.testing.expectEqualStrings("two", session.variable("DIRECT").?);
    try std.testing.expect(session.isVariableExported("DIRECT"));

    var unset_hir = try generate("unset PREFIX DIRECT missing");
    defer unset_hir.deinit(std.testing.allocator);
    const unset_result = try session.execute(unset_hir);

    try std.testing.expectEqual(@as(u8, 0), unset_result.status);
    try std.testing.expect(session.variable("PREFIX") == null);
    try std.testing.expect(session.variable("DIRECT") == null);
    try std.testing.expectEqualDeep(unset_result, session.lastResult());
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "session routes builtin output" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .io = .{
            .stdout = &output.writer,
            .stderr = &diagnostics.writer,
        },
        .variables = &.{
            .{ .name = "EXPORTED", .value = "value", .exported = true },
            .{ .name = "LOCAL", .value = "hidden" },
        },
    });
    defer session.deinit();

    var hir = try generate("export");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("export EXPORTED='value'\n", output.written());

    var invalid_hir = try generate("pwd -P");
    defer invalid_hir.deinit(std.testing.allocator);
    const invalid_result = try session.execute(invalid_hir);

    try std.testing.expectEqual(@as(u8, 2), invalid_result.status);
    try std.testing.expectEqualStrings("pwd: unsupported option: -P\n", diagnostics.written());
}

test "cd changes resolution and spawn directories for later commands" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    fake_host.working_directory_result = "/workspace/project";
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/echo";
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .cwd = "/workspace",
    });
    defer session.deinit();

    var hir = try generate("cd project; echo done");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace/project", session.workingDirectory().?);
    try std.testing.expectEqualStrings("/workspace/project", session.variable("PWD").?);
    try std.testing.expectEqualStrings("/workspace", session.variable("OLDPWD").?);
    try std.testing.expectEqualStrings(
        "/workspace/project",
        fake_resolver.calls.items[0].cwd.?,
    );
    try std.testing.expectEqualStrings(
        "/workspace/project",
        fake_host.spawn_calls.items[0].cwd.path,
    );
}

test "session executes HIR through the system resolver and host" {
    var environ_map = try std.process.Environ.createMap(
        std.testing.environ,
        std.testing.allocator,
    );
    defer environ_map.deinit();
    var system_host: Host.System = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
    };
    defer system_host.deinit();
    var system_resolver: CommandResolver.System = .{
        .io = std.testing.io,
        .executable_extensions = &.{},
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(std.testing.io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    var search_path_storage: [1][]const u8 = undefined;
    const source: [:0]const u8 = switch (@import("builtin").os.tag) {
        .windows => source: {
            const command = environ_map.get("ComSpec") orelse return error.SkipZigTest;
            search_path_storage[0] = std.fs.path.dirname(command) orelse
                return error.SkipZigTest;
            break :source
            \\cmd.exe /D /C 'if /I "%CD%"=="%EXPECTED%" (exit /B %STATUS%) else (exit /B 99)'
            ;
        },
        else => source: {
            search_path_storage[0] = "/bin";
            break :source
            \\sh -c 'test "$(pwd)" = "$EXPECTED" || exit 99; exit "$STATUS"'
            ;
        },
    };
    var session = try Session.init(std.testing.allocator, system_host.host(), .{
        .resolver = system_resolver.resolver(),
        .cwd = cwd,
        .search_path = &search_path_storage,
        .variables = &.{
            .{ .name = "EXPECTED", .value = cwd, .exported = true },
            .{ .name = "STATUS", .value = "23", .exported = true },
        },
    });
    defer session.deinit();
    var hir = try generate(source);
    defer hir.deinit(std.testing.allocator);

    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 23), result.status);
    try std.testing.expectEqualDeep(result, session.lastResult());
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
            .{ .name = "first", .value = "one", .exported = true },
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
