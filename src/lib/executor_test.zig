const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const FakeResolver = @import("CommandResolver/FakeResolver.zig");
const Executor = @import("Executor.zig");
const FakeHost = @import("Host/FakeHost.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const VariableStore = @import("VariableStore.zig");

test "executes static simple commands through the host" {
    var hir = try generate("/bin/echo 'hello world' x\\ y \"\"");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 7 };

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u32, 7), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    const argv = fake.spawn_calls.items[0].argv;
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hello world", argv[1]);
    try std.testing.expectEqualStrings("x y", argv[2]);
    try std.testing.expectEqualStrings("", argv[3]);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
}

test "preserves wide native process exit codes" {
    var hir = try generate("/bin/command");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 0x80000001 };

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u32, 0x80000001), result.status);
}

test "executes sequential lists and returns the last status" {
    var hir = try generate("/bin/first; /bin/second\n/bin/third");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .signal = 9 };

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(@as(u32, 137), result.status);
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

    try std.testing.expectEqual(@as(u32, 0), result.status);
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

    try std.testing.expectEqual(@as(u32, 1), (try executor.execute(false_hir)).status);
    try std.testing.expectEqual(@as(u32, 0), (try executor.execute(colon_hir)).status);
    try std.testing.expectEqual(@as(u32, 1), (try executor.execute(expanded_hir)).status);
    try std.testing.expectEqual(@as(usize, 0), fake_resolver.calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
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

    try std.testing.expectEqual(@as(u32, 0), result.status);
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

    try std.testing.expectEqual(@as(u32, 0), result.status);
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

    try std.testing.expectEqual(@as(u32, 0), result.status);
    try std.testing.expectEqualStrings("one", variables.get("first").?);
    try std.testing.expectEqualStrings("", variables.get("empty").?);
    try std.testing.expectEqualStrings("one two", variables.get("second").?);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "standalone assignment execution handles every allocation failure" {
    var hir = try generate("first=one second=\"$first two\"");
    defer hir.deinit(std.testing.allocator);
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        executeAssignmentsWithAllocator,
        .{ hir, fake.host() },
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

    _ = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    const environment = fake.spawn_calls.items[0].environment.overlay;
    try std.testing.expectEqual(@as(usize, 1), environment.len);
    try std.testing.expectEqualStrings("local", environment[0].name);
    try std.testing.expectEqualStrings("value", environment[0].value);
}

test "command-local assignment execution handles every allocation failure" {
    var hir = try generate("first=one second=\"$first two\" /bin/true");
    defer hir.deinit(std.testing.allocator);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        executeCommandAssignmentsWithAllocator,
        .{hir},
    );
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

test "unsupported expansion has no host side effects" {
    var hir = try generate("/bin/echo $name");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.FieldSplittingUnsupported,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "pathname expansion is not executed as a literal argument" {
    var hir = try generate("/bin/echo *.zig");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.PathnameExpansionUnsupported,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "background execution has no host side effects" {
    var hir = try generate("/bin/sleep &");
    defer hir.deinit(std.testing.allocator);

    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.UnsupportedInstruction,
        Executor.init(std.testing.allocator, fake.host()).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
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

test "resolves command names from explicit session state" {
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
}

test "does not spawn when command resolution finds no executable" {
    var hir = try generate("missing");
    defer hir.deinit(std.testing.allocator);

    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();

    try std.testing.expectError(
        error.CommandNotFound,
        Executor.initWithOptions(std.testing.allocator, fake_host.host(), .{
            .resolver = fake_resolver.resolver(),
        }).execute(hir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
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

    const result = try Executor.init(std.testing.allocator, fake.host()).execute(hir);

    try std.testing.expectEqual(.partial, result.sandbox_coverage);
}

fn generate(source: [:0]const u8) !@import("Hir.zig") {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return AstGen.generate(std.testing.allocator, tree);
}

fn executeAssignmentsWithAllocator(
    gpa: std.mem.Allocator,
    hir: @import("Hir.zig"),
    host: @import("Host.zig"),
) !void {
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    _ = try Executor.initWithOptions(gpa, host, .{
        .variables = &variables,
    }).execute(hir);
}

fn executeCommandAssignmentsWithAllocator(
    gpa: std.mem.Allocator,
    hir: @import("Hir.zig"),
) !void {
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    try variables.set("inherited", "value");
    try variables.setExported("inherited", true);
    _ = try Executor.initWithOptions(gpa, fake.host(), .{
        .variables = &variables,
    }).execute(hir);
}
