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
const Diagnostic = @import("runtime/Diagnostic.zig");
const Source = @import("Source.zig");

test "evaluation events pair outcomes and reject callback reentry" {
    const Capture = struct {
        const Kind = enum { started, executed, syntax, unsupported, failed };
        const Record = struct { id: Session.EvaluationId, kind: Kind, status: ?u8 = null };
        records: [12]Record = undefined,
        count: usize = 0,
        session: ?*Session = null,
        reentry_error: ?anyerror = null,
        failure: ?anyerror = null,
        saw_cwd: bool = false,

        fn notify(userdata: ?*anyopaque, event: Session.Event) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.records[self.count] = switch (event) {
                .started => |started| .{ .id = started.id, .kind = .started },
                .finished => |finished| .{
                    .id = finished.id,
                    .kind = switch (finished.outcome) {
                        .executed => .executed,
                        .syntax => .syntax,
                        .unsupported => .unsupported,
                        .failed => .failed,
                    },
                    .status = if (finished.outcome == .executed) finished.outcome.executed.status else null,
                },
            };
            self.count += 1;
            if (event == .finished and event.finished.outcome == .failed)
                self.failure = event.finished.outcome.failed;
            if (event == .started) {
                self.saw_cwd = std.mem.eql(u8, event.started.cwd.?, "/work");
                if (self.reentry_error == null) {
                    var nested = self.session.?.evaluate("true", .{}) catch |err| {
                        self.reentry_error = err;
                        return;
                    };
                    nested.deinit(self.session.?.allocator());
                }
            }
        }
    };
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var resolver = FakeResolver.init(std.testing.allocator);
    defer resolver.deinit();
    var capture: Capture = .{};
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .context = .{ .cwd = "/work" },
        .resolver = resolver.resolver(),
        .observer = .{ .userdata = &capture, .notify = Capture.notify },
    });
    defer session.deinit();
    capture.session = &session;

    const inputs = [_][:0]const u8{ "exit 7", "# comment", "if", "tool ~other" };
    for (inputs) |input| {
        var result = try session.evaluate(input, .{});
        result.deinit(session.allocator());
    }
    resolver.resolve_error = error.Unexpected;
    try std.testing.expectError(error.Unexpected, session.evaluate("tool", .{}));
    try std.testing.expectEqual(error.EvaluationInProgress, capture.reentry_error.?);
    try std.testing.expect(capture.saw_cwd);
    try std.testing.expectEqual(@as(usize, 10), capture.count);
    const kinds = [_]Capture.Kind{ .executed, .executed, .syntax, .unsupported, .failed };
    for (kinds, 0..) |kind, index| {
        try std.testing.expectEqual(@as(u64, index + 1), @backingInt(capture.records[index * 2].id));
        try std.testing.expectEqual(capture.records[index * 2].id, capture.records[index * 2 + 1].id);
        try std.testing.expectEqual(Capture.Kind.started, capture.records[index * 2].kind);
        try std.testing.expectEqual(kind, capture.records[index * 2 + 1].kind);
    }
    try std.testing.expectEqual(@as(u8, 7), capture.records[1].status.?);
    try std.testing.expectEqual(@as(u8, 7), capture.records[3].status.?);
    try std.testing.expectEqual(error.Unexpected, capture.failure.?);

    session.interruptInput();
    try std.testing.expectEqual(@as(u8, 130), session.lastResult().status);
    try std.testing.expectEqual(@as(usize, 10), capture.count);

    session.next_evaluation_id = std.math.maxInt(u64);
    try std.testing.expectError(error.EvaluationIdExhausted, session.evaluate("true", .{}));
    try std.testing.expectEqual(@as(usize, 10), capture.count);
}

const DiagnosticCapture = struct {
    count: usize = 0,
    source: ?Diagnostic.Source = null,
    origin: ?Source = null,
    subject: [128]u8 = undefined,
    subject_len: usize = 0,
    kind: std.meta.Tag(Diagnostic.Kind) = .command_not_found,
    worker_reported: bool = false,

    fn deinit(self: *DiagnosticCapture) void {
        if (self.origin) |*origin| origin.deinit(std.testing.allocator);
    }

    fn report(userdata: ?*anyopaque, diagnostic: Diagnostic) void {
        const self: *DiagnosticCapture = @ptrCast(@alignCast(userdata.?));
        self.count += 1;
        if (self.origin) |*origin| origin.deinit(std.testing.allocator);
        self.origin = null;
        self.source = diagnostic.source;
        if (self.source) |*location| {
            if (location.origin) |origin| {
                self.origin = Source.init(std.testing.allocator, origin) catch unreachable;
                location.origin = self.origin.?.view();
            }
        }
        const subject = switch (diagnostic.subject) {
            .shell => "",
            .command, .path => |value| value,
        };
        @memcpy(self.subject[0..subject.len], subject);
        self.subject_len = subject.len;
        self.kind = diagnostic.kind;
        self.worker_reported = diagnostic.worker_reported;
    }
};

test "diagnostics retain exact ranges and the source of stored function bodies" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var resolver = FakeResolver.init(std.testing.allocator);
    defer resolver.deinit();
    resolver.result = null;
    var capture: DiagnosticCapture = .{};
    defer capture.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = resolver.resolver(),
        .context = .{ .io = .{
            .stderr = &stderr.writer,
            .diagnostic_sink = .{ .userdata = &capture, .report = DiagnosticCapture.report },
        } },
    });
    defer session.deinit();
    var result = try session.evaluate("command_name=missing; X=y \"$command_name\" arg", .{});
    defer result.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 127), result.executed.status);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(u32, 26), capture.source.?.start);
    try std.testing.expectEqualStrings("\"$command_name\"", capture.source.?.slice().?);
    try std.testing.expectEqualStrings("missing", capture.subject[0..capture.subject_len]);
    try std.testing.expectEqualStrings("", stderr.written());

    const input = try std.testing.allocator.dupeSentinel(u8, "f() { missing; }", 0);
    var definition = try session.evaluate(input, .{
        .source_name = "definitions.hb",
        .source_revision = 9,
        .source_line_offset = 20,
    });
    definition.deinit(session.allocator());
    @memset(input, 'x');
    std.testing.allocator.free(input);
    var invocation = try session.evaluate("f", .{ .source_name = "invocation.hb" });
    defer invocation.deinit(session.allocator());
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings("missing", capture.source.?.slice().?);
    try std.testing.expectEqualStrings("definitions.hb", capture.origin.?.name.?);
    try std.testing.expectEqual(@as(?u64, 9), capture.origin.?.revision);
    try std.testing.expectEqual(@as(?u64, 2), capture.origin.?.id);
    try std.testing.expectEqual(@as(usize, 20), capture.origin.?.line_offset);

    var pipeline = try session.evaluate("f | true", .{ .source_name = "pipeline.hb" });
    defer pipeline.deinit(session.allocator());
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualStrings("missing", capture.source.?.slice().?);
    try std.testing.expectEqualStrings("definitions.hb", capture.origin.?.name.?);
}

test "delayed worker diagnostics preserve background command and path attribution" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .spawn_failed = .{ .file_action = .{ .action_index = 1, .reason = .access_denied } } };
    var capture: DiagnosticCapture = .{};
    defer capture.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
        .context = .{ .io = .{
            .stderr = &stderr.writer,
            .diagnostic_sink = .{ .userdata = &capture, .report = DiagnosticCapture.report },
        } },
    });
    defer session.deinit();
    const input = try std.testing.allocator.dupeSentinel(u8, "/bin/tool > denied &", 0);
    var launched = try session.evaluate(input, .{ .source_name = "submitted.hb" });
    launched.deinit(session.allocator());
    @memset(input, 'x');
    std.testing.allocator.free(input);
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    var waited = try session.evaluate("wait $!", .{ .source_name = "later.hb" });
    defer waited.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 1), waited.executed.status);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("denied", capture.subject[0..capture.subject_len]);
    try std.testing.expectEqualStrings("/bin/tool", capture.source.?.slice().?);
    try std.testing.expectEqualStrings("submitted.hb", capture.origin.?.name.?);
    try std.testing.expectEqual(@as(?u64, 1), capture.origin.?.id);
    try std.testing.expect(capture.worker_reported);
    try std.testing.expectEqualStrings("", stderr.written());
    try session.jobs.poll();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}

test "nested substitution diagnostics map through raw CRLF here-document sources" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var resolver = FakeResolver.init(std.testing.allocator);
    defer resolver.deinit();
    var capture: DiagnosticCapture = .{};
    defer capture.deinit();
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = resolver.resolver(),
        .context = .{ .io = .{
            .diagnostic_sink = .{ .userdata = &capture, .report = DiagnosticCapture.report },
        } },
    });
    defer session.deinit();
    const scripts = [_][:0]const u8{
        "value=$(missing)",
        "value=$(inner=$(missing))",
        "value=$(cat <<EOF\r\nlong body\r\nEOF\r\nmissing)",
        "value=$(cat <<EOF\r\nlong body\r\nEOF\r\ninner=$(missing))",
    };
    for (scripts, 0..) |script, index| {
        var result = try session.evaluate(script, .{
            .source_name = "nested.hb",
            .source_base_offset = 200,
            .source_line_offset = 4,
            .source_revision = 12,
        });
        defer result.deinit(session.allocator());
        const expected = std.mem.indexOf(u8, script, "missing").?;
        const source = capture.source.?;
        const origin = capture.origin.?.view();
        try std.testing.expectEqualStrings("missing", source.originalSlice().?);
        try std.testing.expectEqualStrings("nested.hb", origin.name.?);
        try std.testing.expectEqual(@as(?u64, index + 1), origin.id);
        try std.testing.expectEqual(@as(?u64, 12), origin.revision);
        try std.testing.expectEqual(@as(u32, @intCast(200 + expected)), source.absoluteRange().?.start);
        const actual_line = origin.line_offset + std.mem.count(u8, origin.text[0..source.start], "\n");
        try std.testing.expectEqual(4 + std.mem.count(u8, script[0..expected], "\n"), actual_line);
    }
    var unknown = try session.evaluate("value=$(missing)", .{ .source_base_offset = null });
    defer unknown.deinit(session.allocator());
    try std.testing.expect(capture.source.?.absoluteRange() == null);
}

test "parameter replacement substitutions retain their static source origins" {
    const Filter = struct {
        fn report(userdata: ?*anyopaque, diagnostic: Diagnostic) void {
            if (diagnostic.kind == .command_not_found)
                DiagnosticCapture.report(userdata, diagnostic);
        }
    };
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var resolver = FakeResolver.init(std.testing.allocator);
    defer resolver.deinit();
    var capture: DiagnosticCapture = .{};
    defer capture.deinit();
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = resolver.resolver(),
        .context = .{ .io = .{
            .diagnostic_sink = .{ .userdata = &capture, .report = Filter.report },
        } },
    });
    defer session.deinit();
    const scripts = [_][:0]const u8{
        ": ${fallback:-$(missing)}",
        ": \"${fallback:-$(missing)}\"",
        "assigned=\"${fallback:=$(missing)}\"",
        ": \"${fallback:?$(missing)}\"",
        ": \"${fallback:-${also:-$(missing)}}\"",
        "value=$(: <<EOF\r\nlong body\r\nEOF\r\n: \"${fallback:-$(missing)}\")",
    };
    for (scripts, 0..) |script, index| {
        const before = capture.count;
        var result = try session.evaluate(script, .{
            .source_name = "parameters.hb",
            .source_base_offset = 500,
            .source_line_offset = 12,
            .source_revision = 42,
        });
        result.deinit(session.allocator());
        try std.testing.expectEqual(before + 1, capture.count);
        const expected = std.mem.indexOf(u8, script, "missing").?;
        const location = capture.source.?;
        const origin = capture.origin.?.view();
        try std.testing.expectEqualStrings("missing", location.originalSlice().?);
        try std.testing.expectEqualStrings("parameters.hb", origin.name.?);
        try std.testing.expectEqual(@as(?u64, index + 1), origin.id);
        try std.testing.expectEqual(@as(?u64, 42), origin.revision);
        try std.testing.expectEqual(@as(u32, @intCast(500 + expected)), location.absoluteRange().?.start);
        try std.testing.expectEqual(
            12 + std.mem.count(u8, script[0..expected], "\n"),
            origin.line_offset + std.mem.count(u8, origin.text[0..location.start], "\n"),
        );
    }
    try session.setVariable("literal", "$(missing)");
    const before = capture.count;
    var literal = try session.evaluate(": \"${fallback:-$literal}\"", .{});
    defer literal.deinit(session.allocator());
    try std.testing.expectEqual(before, capture.count);
}

test "background jobs retain process state until wait consumes the result" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 23 };
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
    });
    defer session.deinit();
    var launched = try session.evaluate("/bin/tool &", .{});
    defer launched.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 0), launched.executed.status);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.jobs.entries.items.len);

    var waited = try session.evaluate("saved=$!; wait $saved", .{});
    defer waited.deinit(session.allocator());
    try std.testing.expectEqualStrings("1", session.variable("saved").?);
    try std.testing.expectEqual(@as(u8, 23), waited.executed.status);
    try std.testing.expectEqual(@as(usize, 0), session.jobs.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
}

test "background pipelines preserve the final stage result and use isolated input" {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.termination = .{ .exited = 29 };
    var session = try Session.init(std.testing.allocator, fake.host(), .{
        .resolver = CommandResolver.preResolved(),
    });
    defer session.deinit();
    var launched = try session.evaluate("/bin/first | /bin/last &", .{});
    defer launched.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 0), launched.executed.status);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.create_input_calls.items.len);
    var waited = try session.evaluate("wait %1", .{});
    defer waited.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 29), waited.executed.status);
    try std.testing.expectEqual(@as(usize, 2), fake.wait_calls.items.len);
}

test "background submission and waiting handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, submitBackgroundWithAllocator, .{});
}

fn submitBackgroundWithAllocator(gpa: std.mem.Allocator) !void {
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var session = try Session.init(gpa, fake.host(), .{ .resolver = CommandResolver.preResolved() });
    defer session.deinit();
    var result = try session.evaluate("/bin/first | /bin/last & wait $!", .{});
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.executed.status);
    try std.testing.expectEqual(@as(usize, 0), session.jobs.entries.items.len);
}

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

test "session snapshots the host directory and accepts an explicit absolute directory" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var fake_resolver = FakeResolver.init(std.testing.allocator);
    defer fake_resolver.deinit();
    fake_resolver.result = "/bin/tool";
    var initial = [_]u8{ '/', 'f', 'i', 'r', 's', 't' };
    fake_host.initial_working_directory = &initial;

    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .resolver = fake_resolver.resolver(),
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake_host.resolve_working_directory_calls.items.len);
    try std.testing.expect(fake_host.resolve_working_directory_calls.items[0].current == null);
    try std.testing.expectEqualStrings(".", fake_host.resolve_working_directory_calls.items[0].path);
    initial[1] = 'x';
    fake_host.initial_working_directory = "/later";

    var hir = try generate("tool");
    defer hir.deinit(std.testing.allocator);
    _ = try session.execute(hir);
    try std.testing.expectEqualStrings("/first", session.workingDirectory().?);
    try std.testing.expectEqualStrings("/first", fake_resolver.calls.items[0].cwd.?);
    try std.testing.expectEqualStrings("/first", fake_host.spawn_calls.items[0].cwd.path);

    fake_host.resolve_working_directory_error = error.AccessDenied;
    var explicit = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .cwd = "/chosen" },
    });
    defer explicit.deinit();
    try std.testing.expectEqualStrings("/chosen", explicit.workingDirectory().?);
    try std.testing.expectEqual(@as(usize, 1), fake_host.resolve_working_directory_calls.items.len);
}

test "session resolves relative initial directory and propagates bootstrap failures" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    fake_host.working_directory_result = "/root/project";

    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .context = .{ .cwd = "project" },
    });
    defer session.deinit();
    try std.testing.expectEqualStrings("/root/project", session.workingDirectory().?);
    try std.testing.expectEqual(@as(usize, 1), fake_host.resolve_working_directory_calls.items.len);
    const request = fake_host.resolve_working_directory_calls.items[0];
    try std.testing.expect(request.current == null);
    try std.testing.expectEqualStrings("project", request.path);
    fake_host.working_directory_result = "/changed";
    try std.testing.expectEqualStrings("/root/project", session.workingDirectory().?);

    var failing_host = FakeHost.init(std.testing.allocator);
    defer failing_host.deinit();
    failing_host.resolve_working_directory_error = error.AccessDenied;
    try std.testing.expectError(
        error.AccessDenied,
        Session.init(std.testing.allocator, failing_host.host(), .{}),
    );
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

    session.rejectInput();
    const after_rejection = try session.execute(exit_hir);
    try std.testing.expectEqual(@as(u8, 2), after_rejection.status);
    try std.testing.expectEqual(.exit, after_rejection.control_flow);
}

test "source evaluation carries variables and status across inputs" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var assignment = try session.evaluate("name=remembered", .{});
    defer assignment.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 0), assignment.executed.status);
    try std.testing.expectEqualStrings("remembered", session.variable("name").?);

    var failure = try session.evaluate("false", .{});
    defer failure.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 1), failure.executed.status);

    var empty = try session.evaluate(" # no command\n", .{});
    defer empty.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 1), empty.executed.status);
    try std.testing.expectEqual(.none, empty.executed.control_flow);

    var exit_result = try session.evaluate("exit", .{});
    defer exit_result.deinit(session.allocator());
    try std.testing.expectEqual(@as(u8, 1), exit_result.executed.status);
    try std.testing.expectEqual(.exit, exit_result.executed.control_flow);
    try std.testing.expectEqual(@as(u8, 1), session.lastResult().status);
    try std.testing.expectEqualStrings("remembered", session.variable("name").?);
}

test "analysis is pure and rejected syntax borrows its source" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{
        .variables = &.{.{ .name = "name", .value = "before" }},
    });
    defer session.deinit();

    var inspected = try Ast.parse(std.testing.allocator, "name=after");
    defer inspected.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("before", session.variable("name").?);
    try std.testing.expectEqual(@as(u8, 0), session.lastResult().status);

    const source = try std.testing.allocator.dupeSentinel(u8, "|", 0);
    defer std.testing.allocator.free(source);
    {
        var rejected = try session.evaluate(source, .{});
        defer rejected.deinit(session.allocator());
        try std.testing.expect(rejected.syntax.errors.len != 0);
        try std.testing.expect(rejected.syntax.source.ptr == source.ptr);
        try std.testing.expectEqual(@as(u8, 2), session.lastResult().status);
        try std.testing.expectEqualStrings("before", session.variable("name").?);
    }
    try std.testing.expectEqualStrings("|", source);

    var incomplete = try session.evaluate("if true; then", .{});
    defer incomplete.deinit(session.allocator());
    try std.testing.expect(incomplete.syntax.status == .incomplete);
    try std.testing.expectEqual(@as(u8, 2), session.lastResult().status);
}

test "source evaluation handles allocation failures across its outcomes" {
    for ([_][:0]const u8{ "f() { false; }; f", "|", "/bin/echo ~other" }) |source| {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            evaluateWithAllocator,
            .{source},
        );
    }
}

test "unsupported source evaluation reports a shell status" {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(std.testing.allocator, fake_host.host(), .{});
    defer session.deinit();

    var evaluation = try session.evaluate("/bin/echo ~other", .{});
    defer evaluation.deinit(session.allocator());
    try std.testing.expectEqual(error.TildeExpansionUnsupported, evaluation.unsupported);
    try std.testing.expectEqual(@as(u8, 2), session.lastResult().status);
    try std.testing.expectEqual(@as(usize, 0), fake_host.spawn_calls.items.len);
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
        .shell_process_id = @fromBackingInt(12345),
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
    var seen: [expected_paths.len]bool = @splat(false);
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

    const path = try std.testing.allocator.print(
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
    const source: [:0]const u8 = switch (@import("builtin").target.os.tag) {
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

fn evaluateWithAllocator(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    var fake_host = FakeHost.init(std.testing.allocator);
    defer fake_host.deinit();
    var session = try Session.init(gpa, fake_host.host(), .{});
    defer session.deinit();
    var evaluation = try session.evaluate(source, .{});
    defer evaluation.deinit(gpa);
}
