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

test "session executes with its runtime configuration" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    fake_host.termination = .{ .exited = 4 };
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/usr/bin/echo";

    const default_search_path = [_][]const u8{ "/bin", "/usr/bin" };
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .context = .{ .cwd = "/work" },
        .default_search_path = &default_search_path,
        .variables = &.{
            .{ .name = "greeting", .value = "from session", .exported = true },
        },
    });
    defer session.deinit();

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

test "sessions keep working directory and output independent" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var first_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first_output.deinit();
    var second_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second_output.deinit();

    var first = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .cwd = "/one", .io = .{ .stdout = &first_output.writer } },
    });
    defer first.deinit();
    var second = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .cwd = "/two", .io = .{ .stdout = &second_output.writer } },
    });
    defer second.deinit();

    var hir = try generate("pwd");
    defer hir.deinit(std.testing.allocator);
    _ = try first.execute(hir);
    _ = try second.execute(hir);

    fake_host.working_directory_result = "/one/project";
    try first.changeWorkingDirectory("project");
    _ = try first.execute(hir);
    _ = try second.execute(hir);

    try std.testing.expectEqualStrings("/one/project", first.workingDirectory().?);
    try std.testing.expectEqualStrings("/two", second.workingDirectory().?);
    try std.testing.expectEqualStrings("/one\n/one/project\n", first_output.written());
    try std.testing.expectEqualStrings("/two\n/two\n", second_output.written());
}

test "session replaces owned runtime configuration" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var cwd = [_]u8{ '/', 'n', 'e', 'w' };
    var positional = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var allowed_path = [_]u8{ '/', 'n', 'e', 'w' };
    fake_host.working_directory_result = &cwd;
    try session.changeWorkingDirectory(&cwd);
    try session.setPositionalParameters(&.{&positional});
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = &allowed_path, .access = .{ .write = true } },
    };
    try session.setSandbox(.{ .restrict = .{
        .file_system = .{ .allow = &rules },
    } });
    try session.setVariable("name", "value");
    try session.setVariableExported("name", true);

    cwd[1] = 'x';
    positional[0] = 'x';
    allowed_path[1] = 'x';

    try std.testing.expectEqualStrings("/new", session.workingDirectory().?);
    try std.testing.expectEqualStrings("value", session.positionalParameters()[0]);
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

test "session supplies positional parameters to implicit for loops" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .positional_parameters = &.{ "one", "two words" },
    });
    defer session.deinit();

    var hir = try generate("for item; do observed=\"$item\"; done");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("two words", session.variable("item").?);
    try std.testing.expectEqualStrings("two words", session.variable("observed").?);
}

test "session persists function definitions and scopes their positional parameters" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    {
        var definition = try generate(
            "remember() { for item; do observed=\"$item\"; done; name=inside; false; }",
        );
        defer definition.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), (try session.execute(definition)).status);
    }

    var invocation = try generate("remember one \"two words\"");
    defer invocation.deinit(std.testing.allocator);
    const result = try session.execute(invocation);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("two words", session.variable("item").?);
    try std.testing.expectEqualStrings("two words", session.variable("observed").?);
    try std.testing.expectEqualStrings("inside", session.variable("name").?);
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "function call redirections scope builtin and external output together" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = CommandResolver.preResolved(),
        .context = .{ .cwd = "/workspace", .io = .{ .stdout = &output.writer } },
    });
    defer session.deinit();

    var hir = try generate("show() { pwd; /bin/tool; }; show >out; pwd");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace\n", fake_host.redirected_output.written());
    try std.testing.expectEqualStrings("/workspace\n", output.written());
    try std.testing.expectEqual(CommandPlan.FileDescriptor.stdout, fake_host.spawn_calls.items[0]
        .file_actions[0].use_resource.target);
    try std.testing.expectEqual(@as(usize, 1), fake_host.closed_resource_count);
}

test "functions expand scalar parameters and restore the caller scope" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .positional_parameters = &.{"outer"},
    });
    defer session.deinit();

    var hir = try generate(
        "capture() { status=$? first=$1 count=$#; }; " ++
            "false; capture one \"two words\"; " ++
            "for item; do caller=\"$item\"; done",
    );
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("1", session.variable("status").?);
    try std.testing.expectEqualStrings("one", session.variable("first").?);
    try std.testing.expectEqualStrings("2", session.variable("count").?);
    try std.testing.expectEqualStrings("outer", session.variable("caller").?);
}

test "zero parameter remains the session invocation name inside functions" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .invocation_name = "script.hb",
    });
    defer session.deinit();

    var hir = try generate("capture() { observed=\"$0\"; }; capture other");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("script.hb", session.invocationName());
    try std.testing.expectEqualStrings("script.hb", session.variable("observed").?);
}

test "shell process id remains stable inside functions" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .shell_process_id = @enumFromInt(12345),
    });
    defer session.deinit();

    var hir = try generate("capture() { observed=\"$$\"; }; capture");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("12345", session.variable("observed").?);
}

test "double-quoted at forwards exact function arguments" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = CommandResolver.preResolved(),
    });
    defer session.deinit();

    var hir = try generate("forward() { /bin/tool \"$@\"; }; forward one \"two words\" \"\"");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake_host.spawn_calls.items.len);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "/bin/tool", "one", "two words", "" }),
        fake_host.spawn_calls.items[0].argv,
    );
}

test "empty double-quoted at removes its command word" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var hir = try generate("empty() { \"$@\"; observed=after; }; empty");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("after", session.variable("observed").?);
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "shell functions override regular builtins but not special builtins" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var hir = try generate("true() { false; }; exit() { false; }; true; exit 7");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 7), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);
}

test "subshells inherit functions without leaking their state changes" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .variables = &.{.{ .name = "name", .value = "outside" }},
    });
    defer session.deinit();

    var hir = try generate("change() { name=inside; }; (change); observed=\"$name\"");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("outside", session.variable("name").?);
    try std.testing.expectEqualStrings("outside", session.variable("observed").?);
}

test "recursive functions stop at the runtime call-depth limit" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .io = .{ .stderr = &diagnostics.writer } },
    });
    defer session.deinit();

    var hir = try generate("recurse() { recurse; }; recurse");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings(
        "recurse: maximum function call depth exceeded\n",
        diagnostics.written(),
    );
}

test "return completes only the current function" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var hir = try generate(
        "inner() { false; return; skipped=inner; }; " ++
            "outer() { inner; after=outer; return 9; skipped=outer; }; outer",
    );
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 9), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("outer", session.variable("after").?);
    try std.testing.expect(session.variable("skipped") == null);
}

test "subshells contain return control from their function" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var hir = try generate("work() { (return 7); observed=after; }; work");
    defer hir.deinit(std.testing.allocator);
    const result = try session.execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("after", session.variable("observed").?);
}

test "session routes builtin output" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .io = .{ .stdout = &output.writer } },
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
        .context = .{ .cwd = "/workspace" },
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

test "PATH assignment, unset, and empty value have distinct search paths" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/tool";
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .default_search_path = &.{"/fallback"},
    });
    defer session.deinit();

    var assigned = try generate("PATH=/persisted; tool");
    defer assigned.deinit(std.testing.allocator);
    _ = try session.execute(assigned);
    try std.testing.expectEqualStrings("/persisted", session.variable("PATH").?);
    try std.testing.expectEqual(@as(usize, 1), fake_resolver.calls.items[0].search_path.len);
    try std.testing.expectEqualStrings("/persisted", fake_resolver.calls.items[0].search_path[0]);

    try std.testing.expect(session.unsetVariable("PATH"));
    var plain = try generate("tool");
    defer plain.deinit(std.testing.allocator);
    _ = try session.execute(plain);
    try std.testing.expectEqual(@as(usize, 1), fake_resolver.calls.items[1].search_path.len);
    try std.testing.expectEqualStrings("/fallback", fake_resolver.calls.items[1].search_path[0]);

    var empty = try generate("PATH=; tool");
    defer empty.deinit(std.testing.allocator);
    _ = try session.execute(empty);
    try std.testing.expectEqualStrings("", session.variable("PATH").?);
    try std.testing.expectEqual(@as(usize, 1), fake_resolver.calls.items[2].search_path.len);
    try std.testing.expectEqualStrings("", fake_resolver.calls.items[2].search_path[0]);
}

test "unexported PATH controls lookup and a command-local PATH stays scoped" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/tool";
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .default_search_path = &.{"/fallback"},
        .variables = &.{
            .{ .name = "PATH", .value = "/private" },
            .{ .name = "VISIBLE", .value = "yes", .exported = true },
        },
    });
    defer session.deinit();

    var hir = try generate("tool; PATH=/temporary tool; tool");
    defer hir.deinit(std.testing.allocator);
    _ = try session.execute(hir);

    try std.testing.expectEqual(@as(usize, 3), fake_resolver.calls.items.len);
    try std.testing.expectEqualStrings("/private", fake_resolver.calls.items[0].search_path[0]);
    try std.testing.expectEqualStrings("/temporary", fake_resolver.calls.items[1].search_path[0]);
    try std.testing.expectEqualStrings("/private", fake_resolver.calls.items[2].search_path[0]);
    try std.testing.expectEqualStrings("/private", session.variable("PATH").?);
    try std.testing.expect(!session.isVariableExported("PATH"));

    try std.testing.expectEqual(@as(usize, 3), fake_host.spawn_calls.items.len);
    const first_environment = fake_host.spawn_calls.items[0].environment.replace;
    try std.testing.expectEqual(@as(usize, 1), first_environment.len);
    try std.testing.expectEqualStrings("VISIBLE", first_environment[0].name);
    const temporary_environment = fake_host.spawn_calls.items[1].environment.replace;
    try std.testing.expectEqual(@as(usize, 2), temporary_environment.len);
    var found_temporary_path = false;
    for (temporary_environment) |binding| {
        if (std.mem.eql(u8, binding.name, "PATH")) {
            try std.testing.expectEqualStrings("/temporary", binding.value);
            found_temporary_path = true;
        }
    }
    try std.testing.expect(found_temporary_path);
    const final_environment = fake_host.spawn_calls.items[2].environment.replace;
    try std.testing.expectEqual(@as(usize, 1), final_environment.len);
    try std.testing.expectEqualStrings("VISIBLE", final_environment[0].name);
}

test "pipeline stages use their own PATH without changing the session" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/tool";
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .variables = &.{.{ .name = "PATH", .value = "/parent" }},
    });
    defer session.deinit();

    var hir = try generate("PATH=/left left | PATH=/right right; tool");
    defer hir.deinit(std.testing.allocator);
    _ = try session.execute(hir);

    try std.testing.expectEqual(@as(usize, 3), fake_resolver.calls.items.len);
    const expected_paths = [_][]const u8{ "/left", "/right", "/parent" };
    var seen = [_]bool{false} ** expected_paths.len;
    for (fake_resolver.calls.items) |request| {
        const index: usize = if (std.mem.eql(u8, request.name, "left"))
            0
        else if (std.mem.eql(u8, request.name, "right"))
            1
        else if (std.mem.eql(u8, request.name, "tool"))
            2
        else {
            try std.testing.expect(false);
            continue;
        };
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try std.testing.expectEqual(@as(usize, 1), request.search_path.len);
        try std.testing.expectEqualStrings(expected_paths[index], request.search_path[0]);
    }
    for (seen) |found| try std.testing.expect(found);
    try std.testing.expectEqualStrings("/parent", session.variable("PATH").?);
}

test "relative and empty PATH entries retain the command working directory" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    fake_host.working_directory_result = "/workspace/next";
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/tool";
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .context = .{ .cwd = "/workspace" },
    });
    defer session.deinit();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "relative{c}{c}/absolute",
        .{ std.fs.path.delimiter, std.fs.path.delimiter },
    );
    defer std.testing.allocator.free(path);
    try session.setVariable("PATH", path);

    var hir = try generate("cd next; tool");
    defer hir.deinit(std.testing.allocator);
    _ = try session.execute(hir);

    try std.testing.expectEqual(@as(usize, 1), fake_resolver.calls.items.len);
    const request = fake_resolver.calls.items[0];
    try std.testing.expectEqualStrings("/workspace/next", request.cwd.?);
    try std.testing.expectEqual(@as(usize, 3), request.search_path.len);
    try std.testing.expectEqualStrings("relative", request.search_path[0]);
    try std.testing.expectEqualStrings("", request.search_path[1]);
    try std.testing.expectEqualStrings("/absolute", request.search_path[2]);
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
        .context = .{ .cwd = cwd },
        .default_search_path = &search_path_storage,
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

fn generate(source: [:0]const u8) !Hir {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}
