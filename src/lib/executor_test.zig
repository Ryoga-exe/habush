const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const CommandResolver = @import("CommandResolver.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");
const Executor = @import("Executor.zig");
const FakeHost = @import("Host/FakeHost.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const runtime = @import("runtime.zig");
const VariableStore = @import("VariableStore.zig");

test "executes static simple commands through the host" {
    var hir = try generate("/bin/echo 'hello world' x\\ y \"\"");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 7 };

    const result = try preResolvedExecutor(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 7), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const argv = fake.spawn_calls.items[0].argv;
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hello world", argv[1]);
    try std.testing.expectEqualStrings("x y", argv[2]);
    try std.testing.expectEqualStrings("", argv[3]);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
}

test "executes sequential lists and returns the last status" {
    var hir = try generate("/bin/first; /bin/second\n/bin/third");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .signal = 9 };

    const result = try preResolvedExecutor(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 137), result.status);
    try std.testing.expectEqual(@as(usize, 3), fake.spawn_calls.items.len);
    try std.testing.expectEqualStrings("/bin/first", fake.spawn_calls.items[0].argv[0]);
    try std.testing.expectEqualStrings("/bin/second", fake.spawn_calls.items[1].argv[0]);
    try std.testing.expectEqualStrings("/bin/third", fake.spawn_calls.items[2].argv[0]);
}

test "empty HIR succeeds without host calls" {
    var hir = try generate("");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(.not_requested, result.sandbox_coverage);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "executes expanded core builtin names without external lookup" {
    var false_hir = try generate("true; false");
    defer false_hir.deinit(std.testing.allocator);
    var colon_hir = try generate("':' ignored");
    defer colon_hir.deinit(std.testing.allocator);
    var expanded_hir = try generate("\"$command\"");
    defer expanded_hir.deinit(std.testing.allocator);

    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/external";
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("command", "false");
    const executor = Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .variables = &variables,
    });

    try std.testing.expectEqual(@as(u8, 1), (try executor.execute(false_hir)).status);
    try std.testing.expectEqual(@as(u8, 0), (try executor.execute(colon_hir)).status);
    try std.testing.expectEqual(@as(u8, 1), (try executor.execute(expanded_hir)).status);
    try std.testing.expectEqual(@as(usize, 0), fake_resolver.calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "exit stops a sequential list and inherits the previous status" {
    var hir = try generate("false; e\"xit\"; /bin/after");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "and-or commands execute and short-circuit by status" {
    const cases = [_]struct { [:0]const u8, u8 }{
        .{ "true && false", 1 },
        .{ "false || true", 0 },
        .{ "false && /bin/skipped", 1 },
        .{ "true || /bin/skipped", 0 },
        .{ "false && false || true", 0 },
        .{ "true || true && false", 1 },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(case[1], result.status);
        try std.testing.expectEqual(.none, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "and-or commands propagate exit without executing remaining commands" {
    var hir = try generate("false || exit; /bin/skipped");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "short-circuiting an exit leaves control flow unchanged" {
    var hir = try generate("false && exit 9; true");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(.none, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "pipeline negation inverts command status" {
    const cases = [_]struct { [:0]const u8, u8 }{
        .{ "! true", 1 },
        .{ "! false", 0 },
        .{ "! ! true", 0 },
        .{ "! true || false", 1 },
        .{ "! false && true", 0 },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(case[1], result.status);
        try std.testing.expectEqual(.none, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "pipeline negation preserves exit control flow and status" {
    var hir = try generate("! exit 7; /bin/skipped");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 7), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "brace groups execute in the current shell state" {
    var hir = try generate("name=before; { name=inside; false; }");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("inside", variables.get("name").?);
}

test "brace groups propagate control flow" {
    var hir = try generate("{ exit 7; /bin/skipped; }; /bin/skipped");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 7), result.status);
    try std.testing.expectEqual(.exit, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "subshells isolate runtime state and contain exit control flow" {
    var hir = try generate("(name=inside; cd child; exit 7); observed=\"$name\"");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/workspace/child";
    var state = try runtime.State.init(std.testing.allocator, .{
        .cwd = "/workspace",
        .variables = &.{.{ .name = "name", .value = "outside" }},
    });
    defer state.deinit();

    const result = try Executor.initWithState(
        fake.host(),
        null,
        &state,
        .{},
        0,
    ).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("outside", state.variable("name").?);
    try std.testing.expectEqualStrings("outside", state.variable("observed").?);
    try std.testing.expectEqualStrings("/workspace", state.workingDirectory().?);
    try std.testing.expect(state.variable("PWD") == null);
}

test "subshells return their body status without exiting the shell" {
    var hir = try generate("(exit 7)");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 7), result.status);
    try std.testing.expect(result.control_flow.isNone());
}

test "subshells do not inherit the surrounding loop context" {
    var hir = try generate(
        "condition=true; while \"$condition\"; do " ++
            "condition=false; (break); observed=after; done",
    );
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
        .io = .{ .stderr = &diagnostics.writer },
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("after", variables.get("observed").?);
    try std.testing.expectEqualStrings("break: not in a loop\n", diagnostics.written());
}

test "if clauses execute the selected branch" {
    const cases = [_]struct { [:0]const u8, u8 }{
        .{ "if true; then false; else true; fi", 1 },
        .{ "if false; then false; else true; fi", 0 },
        .{ "if false; then false; fi", 0 },
        .{
            "if false; then true; elif true; then false; else true; fi",
            1,
        },
        .{ "if true; then true; else /bin/skipped; fi", 0 },
        .{ "if false; then /bin/skipped; else true; fi", 0 },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(case[1], result.status);
        try std.testing.expectEqual(.none, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "if clauses propagate exit from conditions and branches" {
    const cases = [_]struct { [:0]const u8, u8 }{
        .{ "if exit 7; then true; fi; /bin/skipped", 7 },
        .{ "if true; then exit 8; fi; /bin/skipped", 8 },
        .{ "if false; then true; else exit; fi; /bin/skipped", 1 },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(case[1], result.status);
        try std.testing.expectEqual(.exit, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "while and until loops skip bodies when conditions are not met" {
    const cases = [_][:0]const u8{
        "while false; do /bin/skipped; done",
        "until true; do /bin/skipped; done",
    };

    for (cases) |source| {
        var hir = try generate(source);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expectEqual(.none, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "while and until loops reevaluate conditions and return the last body status" {
    const cases = [_]struct { [:0]const u8, []const u8 }{
        .{
            "command=true; while \"$command\"; do command=false; false; done",
            "false",
        },
        .{
            "command=false; until \"$command\"; do command=true; false; done",
            "true",
        },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        var variables = VariableStore.init(std.testing.allocator);
        defer variables.deinit();

        const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
            .variables = &variables,
        }).execute(hir);

        try std.testing.expectEqual(@as(u8, 1), result.status);
        try std.testing.expectEqual(.none, result.control_flow);
        try std.testing.expectEqualStrings(case[1], variables.get("command").?);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "while and until loops propagate exit from conditions and bodies" {
    const cases = [_]struct { [:0]const u8, u8 }{
        .{ "false; while exit; do true; done; /bin/skipped", 1 },
        .{ "while true; do exit 7; done; /bin/skipped", 7 },
        .{ "until false; do exit; done; /bin/skipped", 1 },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

        try std.testing.expectEqual(case[1], result.status);
        try std.testing.expectEqual(.exit, result.control_flow);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "for loops expand explicit words once and retain the last iteration values" {
    var hir = try generate(
        \\source=one
        \\for item in "$source" "two words" "$source"; do
        \\  source=changed
        \\  observed="$item"
        \\done
    );
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("one", variables.get("item").?);
    try std.testing.expectEqualStrings("one", variables.get("observed").?);
    try std.testing.expectEqualStrings("changed", variables.get("source").?);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "for loops without an in list iterate over positional parameters" {
    var hir = try generate("for item; do observed=\"$item\"; done");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .positional_parameters = &.{ "one", "two words", "three" },
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("three", variables.get("item").?);
    try std.testing.expectEqualStrings("three", variables.get("observed").?);
}

test "for loops with no values succeed without variable state" {
    var hir = try generate("for item in; do /bin/skipped; done");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "for loops consume continue and propagate break across nested loops" {
    const cases = [_][:0]const u8{
        \\for command in continue false; do
        \\  "$command"
        \\  observed="$command"
        \\done
        ,
        \\for outer in one; do
        \\  for inner in two; do
        \\    break 2
        \\    /bin/skipped
        \\  done
        \\  /bin/skipped
        \\done
        ,
    };

    for (cases, 0..) |source, case_index| {
        var hir = try generate(source);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        var variables = VariableStore.init(std.testing.allocator);
        defer variables.deinit();

        const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
            .variables = &variables,
        }).execute(hir);

        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expect(result.control_flow.isNone());
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
        if (case_index == 0)
            try std.testing.expectEqualStrings("false", variables.get("observed").?);
    }
}

test "break exits a loop and continue starts its next condition" {
    const cases = [_]struct { [:0]const u8, []const u8 }{
        .{
            "command=true; while \"$command\"; do command=false; break; /bin/skipped; done",
            "false",
        },
        .{
            "command=true; while \"$command\"; do command=false; continue; /bin/skipped; done",
            "false",
        },
    };

    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        var variables = VariableStore.init(std.testing.allocator);
        defer variables.deinit();

        const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
            .variables = &variables,
        }).execute(hir);

        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expect(result.control_flow.isNone());
        try std.testing.expectEqualStrings(case[1], variables.get("command").?);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "break and continue propagate across nested loops" {
    const cases = [_][:0]const u8{
        \\outer=true
        \\while "$outer"; do
        \\  outer=false
        \\  while true; do
        \\    break 2
        \\    /bin/skipped
        \\  done
        \\  /bin/skipped
        \\done
        ,
        \\outer=true
        \\inner=true
        \\while "$outer"; do
        \\  outer=false
        \\  while "$inner"; do
        \\    inner=false
        \\    continue 2
        \\    /bin/skipped
        \\  done
        \\  /bin/skipped
        \\done
        ,
    };

    for (cases) |source| {
        var hir = try generate(source);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        var variables = VariableStore.init(std.testing.allocator);
        defer variables.deinit();

        const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
            .variables = &variables,
        }).execute(hir);

        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expect(result.control_flow.isNone());
        try std.testing.expectEqualStrings("false", variables.get("outer").?);
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "break outside a loop reports a command failure" {
    var hir = try generate("break");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .io = .{ .stderr = &diagnostics.writer },
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 1), result.status);
    try std.testing.expect(result.control_flow.isNone());
    try std.testing.expectEqualStrings("break: not in a loop\n", diagnostics.written());
}

test "special builtin assignments persist in session state" {
    var hir = try generate("name=temporary next=\"$name value\" :");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "persistent");
    try variables.setExported("name", true);

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("temporary", variables.get("name").?);
    try std.testing.expect(variables.isExported("name"));
    try std.testing.expectEqualStrings("temporary value", variables.get("next").?);
    try std.testing.expect(!variables.isExported("next"));
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "regular builtin assignments remain command-local" {
    var hir = try generate("name=temporary true");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "persistent");

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("persistent", variables.get("name").?);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "persists standalone assignments in source order" {
    var hir = try generate("first=one empty= second=\"$first two\"");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("one", variables.get("first").?);
    try std.testing.expectEqualStrings("", variables.get("empty").?);
    try std.testing.expectEqualStrings("one two", variables.get("second").?);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "assignment execution handles every allocation failure" {
    var standalone_hir = try generate("first=one second=\"$first two\"");
    defer standalone_hir.deinit(std.testing.allocator);
    var command_hir = try generate("first=one second=\"$first two\" /bin/true");
    defer command_hir.deinit(std.testing.allocator);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        executeAssignmentsWithAllocator,
        .{ standalone_hir, command_hir },
    );
}

test "command-local assignments overlay the inherited environment" {
    var hir = try generate(
        "name=temporary next=\"$name value\" name=final /bin/echo \"$name\"",
    );
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "persistent");
    try variables.setExported("name", true);

    _ = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqualStrings("persistent", variables.get("name").?);
    try std.testing.expect(variables.isExported("name"));
    try std.testing.expect(variables.get("next") == null);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const plan = fake.spawn_calls.items[0];
    try std.testing.expectEqualStrings("persistent", plan.argv[1]);
    try std.testing.expectEqual(@as(usize, 2), plan.environment.replace.len);
    try std.testing.expectEqualStrings("name", plan.environment.replace[0].name);
    try std.testing.expectEqualStrings("final", plan.environment.replace[0].value);
    try std.testing.expectEqualStrings("next", plan.environment.replace[1].name);
    try std.testing.expectEqualStrings("temporary value", plan.environment.replace[1].value);
}

test "exports session variables through an exact environment snapshot" {
    var hir = try generate("/bin/env");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("visible", "yes");
    try variables.setExported("visible", true);
    try variables.set("hidden", "no");

    _ = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .variables = &variables,
    }).execute(hir);

    const environment = fake.spawn_calls.items[0].environment.replace;
    try std.testing.expectEqual(@as(usize, 1), environment.len);
    try std.testing.expectEqualStrings("visible", environment[0].name);
    try std.testing.expectEqualStrings("yes", environment[0].value);
}

test "command-local assignments overlay the host environment without session state" {
    var hir = try generate("local=value /bin/true");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    _ = try preResolvedExecutor(std.testing.allocator, fake.host()).execute(hir);

    const environment = fake.spawn_calls.items[0].environment.overlay;
    try std.testing.expectEqual(@as(usize, 1), environment.len);
    try std.testing.expectEqualStrings("local", environment[0].name);
    try std.testing.expectEqualStrings("value", environment[0].value);
}

test "standalone assignments require mutable variable state" {
    var hir = try generate("name=value");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.VariableStateUnavailable,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
}

test "unsupported expansions have no host side effects" {
    const cases = [_]struct { [:0]const u8, anyerror }{
        .{ "/bin/echo $@", error.FieldSplittingUnsupported },
        .{ "/bin/echo *.zig", error.PathnameExpansionUnsupported },
    };
    for (cases) |case| {
        var hir = try generate(case[0]);
        defer hir.deinit(std.testing.allocator);
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();

        try std.testing.expectError(
            case[1],
            Executor.init(std.testing.allocator, fake.host()).execute(hir),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
    }
}

test "field splitting contributes every expanded command argument" {
    var hir = try generate("/bin/tool pre$name\"post\" \"$name\" $missing");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "one two");

    const result = try Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .variables = &variables,
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "/bin/tool", "preone", "twopost", "one two" }),
        fake.spawn_calls.items[0].argv,
    );
}

test "unsupported execution forms fail before the current command has side effects" {
    const cases = [_][:0]const u8{
        "left | right",
        "persisted=changed >out",
        "if persisted=changed; then true; fi >out",
        "while persisted=changed; do true; done >out",
        "for persisted in changed; do true; done >out",
        "{ persisted=changed; } >out",
        "(persisted=changed) >out",
        "left &",
    };

    for (cases) |source| {
        var hir = try generate(source);
        defer hir.deinit(std.testing.allocator);

        var fake_host = FakeHost.init(std.testing.allocator);
        defer fake_host.deinit();
        var fake_resolver = FakeResolver.init(std.testing.allocator);
        defer fake_resolver.deinit();
        fake_resolver.result = "/bin/left";
        var variables = VariableStore.init(std.testing.allocator);
        defer variables.deinit();
        try variables.set("persisted", "original");

        try std.testing.expectError(
            error.UnsupportedInstruction,
            Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
                .resolver = fake_resolver.resolver(),
                .variables = &variables,
            }).execute(hir),
        );
        try std.testing.expectEqualStrings("original", variables.get("persisted").?);
        try std.testing.expectEqual(@as(usize, 0), fake_resolver.calls.items.len);
        try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
        try std.testing.expectEqual(@as(usize, 0), fake_host.wait_calls.items.len);
    }
}

test "command names are not resolved by the host" {
    var hir = try generate("echo hello");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.CommandResolutionUnavailable,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "resolves command names and explicit paths through the resolver" {
    var hir = try generate("echo hello");
    defer hir.deinit(std.testing.allocator);

    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/usr/bin/echo";
    const search_path = [_][]const u8{ "/bin", "/usr/bin" };
    const executor = Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .search_path = &search_path,
        .cwd = "/workspace",
    });

    _ = try executor.execute(hir);

    try std.testing.expectEqual(@as(usize, 1), fake_resolver.calls.items.len);
    const request = fake_resolver.calls.items[0];
    try std.testing.expectEqualStrings("echo", request.name);
    try std.testing.expectEqualStrings("/bin", request.search_path[0]);
    try std.testing.expectEqualStrings("/workspace", request.cwd.?);
    const plan = fake_host.spawn_calls.items[0];
    try std.testing.expectEqualStrings("/usr/bin/echo", plan.executable);
    try std.testing.expectEqualStrings("echo", plan.argv[0]);
    try std.testing.expectEqualStrings("/workspace", plan.cwd.path);

    var explicit_hir = try generate("/requested/command");
    defer explicit_hir.deinit(std.testing.allocator);
    fake_resolver.result = "/canonical/command";
    _ = try executor.execute(explicit_hir);

    try std.testing.expectEqual(@as(usize, 2), fake_resolver.calls.items.len);
    try std.testing.expectEqualStrings("/requested/command", fake_resolver.calls.items[1].name);
    try std.testing.expectEqualStrings(
        "/canonical/command",
        fake_host.spawn_calls.items[1].executable,
    );
}

test "does not spawn when command resolution finds no executable" {
    var hir = try generate("missing");
    defer hir.deinit(std.testing.allocator);

    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .io = .{ .stderr = &diagnostics.writer },
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 127), result.status);
    try std.testing.expectEqualStrings("missing: command not found\n", diagnostics.written());
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "reports denied command resolution as not executable" {
    var hir = try generate("denied");
    defer hir.deinit(std.testing.allocator);
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.resolve_error = error.AccessDenied;
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();

    const result = try Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
        .io = .{ .stderr = &diagnostics.writer },
    }).execute(hir);

    try std.testing.expectEqual(@as(u8, 126), result.status);
    try std.testing.expectEqualStrings("denied: permission denied\n", diagnostics.written());
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
}

test "reports host spawn failures as command diagnostics" {
    const Case = struct {
        host_error: @import("Host.zig").Error,
        status: u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{
            .host_error = error.CommandNotFound,
            .status = 127,
            .message = "tool: command not found\n",
        },
        .{
            .host_error = error.AccessDenied,
            .status = 126,
            .message = "tool: permission denied\n",
        },
        .{
            .host_error = error.InvalidExecutable,
            .status = 126,
            .message = "tool: invalid executable\n",
        },
        .{
            .host_error = error.ResourceUnavailable,
            .status = 126,
            .message = "tool: system resources unavailable\n",
        },
        .{
            .host_error = error.SandboxUnavailable,
            .status = 126,
            .message = "tool: required sandbox unavailable\n",
        },
        .{
            .host_error = error.Unsupported,
            .status = 126,
            .message = "tool: operation not supported\n",
        },
    };

    var hir = try generate("tool");
    defer hir.deinit(std.testing.allocator);
    for (cases) |case| {
        var fake_host = FakeHost.init(std.testing.allocator);
        defer fake_host.deinit();
        fake_host.spawn_error = case.host_error;
        var fake_resolver = FakeResolver.init(std.testing.allocator);
        defer fake_resolver.deinit();
        fake_resolver.result = "/bin/tool";
        var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer diagnostics.deinit();

        const result = try Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
            .resolver = fake_resolver.resolver(),
            .io = .{ .stderr = &diagnostics.writer },
        }).execute(hir);

        try std.testing.expectEqual(case.status, result.status);
        try std.testing.expectEqualStrings(case.message, diagnostics.written());
        try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
    }
}

test "forwards the active sandbox policy to the host" {
    var hir = try generate("/bin/echo hello");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/usr", .access = .{ .read = true } },
    };
    const executor = Executor.initWithOptions(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .sandbox = .{ .restrict = .{
            .enforcement = .required,
            .file_system = .{ .allow = &rules },
        } },
    });

    _ = try executor.execute(hir);

    const policy = fake.spawn_calls.items[0].sandbox.restrict;
    try std.testing.expectEqual(SandboxPolicy.Enforcement.required, policy.enforcement);
    try std.testing.expectEqualStrings("/usr", policy.file_system.allow[0].path);
}

test "reports partial best-effort sandbox coverage" {
    var hir = try generate("/bin/echo hello");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.sandbox_coverage = .partial;

    const result = try preResolvedExecutor(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(.partial, result.sandbox_coverage);
}

fn generate(source: [:0]const u8) !@import("Hir.zig") {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}

fn preResolvedExecutor(gpa: std.mem.Allocator, host: @import("Host.zig")) Executor {
    return Executor.initWithOptions(gpa, host, .{
        .resolver = CommandResolver.preResolved(),
    });
}

fn executeAssignmentsWithAllocator(
    gpa: std.mem.Allocator,
    standalone_hir: @import("Hir.zig"),
    command_hir: @import("Hir.zig"),
) !void {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    _ = try Executor.initWithOptions(gpa, fake.host(), .{
        .variables = &variables,
    }).execute(standalone_hir);
    try variables.set("inherited", "value");
    try variables.setExported("inherited", true);
    _ = try Executor.initWithOptions(gpa, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .variables = &variables,
    }).execute(command_hir);
}
