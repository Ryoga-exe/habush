//! Synchronous adapter for session registrations. Function calls use isolated
//! state and bounded pipes, including stdout from external commands.
//! The caller keeps the source Session unchanged until collection has joined.
const std = @import("std");
const Completion = @import("../Completion.zig");
const Provider = @import("Provider.zig");
const Session = @import("../Session.zig");
const Executor = @import("../Executor.zig");
const ExecutionContext = @import("../ExecutionContext.zig");
const CommandPlan = @import("../CommandPlan.zig");
const VariableStore = @import("../VariableStore.zig");
const runtime = @import("../runtime.zig");
const Command = @import("../Command.zig");
const Registered = @This();

session: *Session,
io: std.Io,
timeout: std.Io.Duration = .fromMilliseconds(100),

pub fn provider(registered: *Registered) Provider {
    return .{ .userdata = registered, .complete = complete };
}

fn complete(userdata: ?*anyopaque, request: Provider.Request, collector: *Provider.Collector) Provider.Error!void {
    const registered: *Registered = @ptrCast(@alignCast(userdata.?));
    if (request.context.kind != .argument or registered.session.state.completions.map.count() == 0) return;
    var scratch: std.heap.ArenaAllocator = .init(collector.gpa);
    defer scratch.deinit();
    const args = request.context.literalArguments(scratch.allocator()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedContext => return,
    };
    if (args.len == 0) return;
    const handler = registered.session.state.completions.get(args[0]) orelse return;
    switch (handler) {
        .provider => |callback| try callback.complete(callback.userdata, request, collector),
        .function => |name| {
            const argv = try scratch.allocator().alloc([]const u8, args.len + 2);
            argv[0] = name;
            argv[1] = request.prefix;
            @memcpy(argv[2..], args);
            const bytes = try registered.functionOutput(collector.gpa, argv, collector.limits.bytes);
            defer collector.gpa.free(bytes);
            if (bytes.len != 0 and bytes[bytes.len - 1] != 0) return error.Unavailable;
            var values = std.mem.splitScalar(u8, bytes, 0);
            while (values.next()) |value| {
                if (values.index == null) break; // The final delimiter is not an empty candidate.
                if (!collector.step() or !try collector.add(.{ .value = value })) break;
            }
        },
    }
    collector.exclusive = true;
}

fn functionOutput(registered: Registered, gpa: std.mem.Allocator, argv: []const []const u8, limit: usize) Provider.Error![]u8 {
    const parent = registered.session;
    if (parent.evaluating or parent.context.activeSandbox() != .inherit or
        !parent.state.functionStore().contains(argv[0])) return error.Unavailable;
    var state = try parent.state.cloneWithAllocator(gpa);
    defer state.deinit();
    var context = try ExecutionContext.init(gpa, parent.context.view());
    defer context.deinit();
    const host = parent.host;
    const pipe = host.createPipe() catch |err| return failure(err);
    defer host.closeResource(pipe.read_end);
    var writer_owned = true;
    defer if (writer_owned) host.closeResource(pipe.write_end);
    const reader = host.resourceReader(pipe.read_end) orelse return error.Unavailable;
    const writer = host.resourceWriter(pipe.write_end) orelse return error.Unavailable;
    const input = host.createInput("") catch |err| return failure(err);
    defer host.closeResource(input);
    var eof: std.Io.Reader = .fixed("");
    context.io = .{ .stdin = &eof, .stdout = writer };
    var executor = Executor.initWithState(host, parent.resolver, &state, &context, parent.lastResult().status);
    executor.commands = parent.commands;
    executor.cancel_io = registered.io;
    executor.deadline = std.Io.Timestamp.now(registered.io, .awake).addDuration(registered.timeout);
    executor.concurrent_pipeline = parent.concurrent_pipeline;
    const actions = [_]CommandPlan.FileAction{
        .{ .use_resource = .{ .resource = input, .target = .stdin } },
        .{ .use_resource = .{ .resource = pipe.write_end, .target = .stdout } },
        .{ .close = .stderr },
    };
    executor.scoped_file_actions = &actions;
    const Result = union(enum) {
        executed: Executor.Error!Executor.Result,
        output: Provider.Error![]u8,
        expired: std.Io.Cancelable!void,
    };
    var storage: [3]Result = undefined;
    var pending: std.Io.Select(Result) = .init(registered.io, &storage);
    defer while (pending.cancel()) |result| {
        if (result == .output) {
            if (result.output) |bytes| gpa.free(bytes) else |_| {}
        }
    };
    pending.concurrent(.executed, run, .{ executor, argv, pipe.write_end }) catch |err| return failure(err);
    writer_owned = false; // run closes it after all child writers have ended.
    pending.concurrent(.output, readOutput, .{ reader, gpa, limit }) catch |err| return failure(err);
    pending.concurrent(.expired, expire, .{ registered.io, registered.timeout }) catch |err| return failure(err);
    var output: ?[]u8 = null;
    errdefer if (output) |bytes| gpa.free(bytes);
    var executed = false;
    while (!executed or output == null) {
        switch (try pending.await()) {
            .executed => |result| {
                const value = result catch |err| {
                    if (err == error.Canceled and std.Io.Timestamp.now(registered.io, .awake).nanoseconds >= executor.deadline.?.nanoseconds)
                        return error.Unavailable;
                    return failure(err);
                };
                if (value.status != 0) return error.Unavailable;
                executed = true;
            },
            .output => |result| output = try result,
            .expired => |result| {
                try result;
                return error.Unavailable;
            },
        }
    }
    return output.?;
}

fn run(executor: Executor, argv: []const []const u8, write_end: CommandPlan.Resource) Executor.Error!Executor.Result {
    defer executor.host.closeResource(write_end);
    var jobs: runtime.Jobs = .{ .gpa = executor.gpa, .cancel_io = executor.cancel_io };
    defer {
        const previous = executor.cancel_io.?.swapCancelProtection(.blocked);
        defer _ = executor.cancel_io.?.swapCancelProtection(previous);
        jobs.cancelAll();
        jobs.deinit();
    }
    var scoped = executor;
    scoped.jobs = &jobs;
    var assignments = VariableStore.init(executor.gpa);
    defer assignments.deinit();
    return scoped.executeFunction(argv, &assignments);
}

fn readOutput(reader: *std.Io.Reader, gpa: std.mem.Allocator, limit: usize) Provider.Error![]u8 {
    return reader.allocRemaining(gpa, .limited(limit)) catch |err| return failure(err);
}

fn expire(io: std.Io, timeout: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(timeout, .awake);
}

fn failure(err: anyerror) Provider.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unavailable,
    };
}

test "function completion uses literal argv and isolates session mutations" {
    const gpa = std.testing.allocator;
    var system: @import("../Host/System.zig") = .{ .gpa = gpa, .io = std.testing.io };
    defer system.deinit();
    const commands = [_]Command{.{ .name = "emit", .run = Test.emit }};
    var session = try Session.init(gpa, system.host(), .{
        .cancel_io = std.testing.io,
        .commands = &commands,
        .positional_parameters = &.{"outer"},
        .variables = &.{
            .{ .name = "VALUE", .value = "kept" },
            .{ .name = "ODD", .value = "line\nwith '$(literal)" },
        },
    });
    defer session.deinit();
    const cwd = try gpa.dupe(u8, session.workingDirectory().?);
    defer gpa.free(cwd);
    try std.testing.expectEqual(@as(u8, 1), (try session.evaluate(
        "__comp() { emit \"$1\" \"$2\" \"$3\" \"$VALUE\" \"$ODD\"; VALUE=changed; cd ..; complete -r git; __comp() { emit changed; }; }; complete -F __comp git; false",
        .{},
    )).executed.status);
    var registered: Registered = .{ .session = &session, .io = std.testing.io, .timeout = .fromSeconds(1) };
    const source = "git switch 'a b'";
    const request: Provider.Request = .{ .context = try Completion.inspect(source, source.len, 0), .prefix = "a b" };
    const providers = [_]Provider{registered.provider()};
    for (0..2) |_| {
        var result = try Provider.collect(gpa, request, &providers, .{});
        defer result.deinit(gpa);
        try std.testing.expect(!result.incomplete);
        try std.testing.expectEqual(@as(usize, 5), result.candidates.len);
        for (result.candidates, [_][]const u8{ "a b", "git", "switch", "kept", "line\nwith '$(literal)" }) |candidate, expected|
            try std.testing.expectEqualStrings(expected, candidate.value);
    }
    try std.testing.expectEqualStrings("kept", session.variable("VALUE").?);
    try std.testing.expectEqualStrings(cwd, session.workingDirectory().?);
    try std.testing.expectEqualStrings("outer", session.positionalParameters()[0]);
    try std.testing.expectEqual(@as(u8, 1), session.lastResult().status);
    try std.testing.expectEqualStrings("__comp", session.state.completions.get("git").?.function);
    // Resolve the function at invocation time, after registration.
    _ = try session.evaluate("__comp() { emit new; }; target() { false; }; complete -F __comp true; complete -F __comp target", .{});
    for ([_][]const u8{ "git ", "true ", "target " }) |source_name| {
        const changed_request: Provider.Request = .{ .context = try Completion.inspect(source_name, source_name.len, 0), .prefix = "" };
        var changed = try Provider.collect(gpa, changed_request, &providers, .{});
        defer changed.deinit(gpa);
        try std.testing.expectEqualStrings("new", changed.unique().?.value);
    }
    _ = try session.evaluate("complete -r git", .{});
    try std.testing.expect(session.state.completions.get("git") == null);
    try std.testing.expectEqual(@as(u8, 0), (try session.evaluate("true", .{})).executed.status);
    try std.testing.expectEqual(@as(u8, 1), (try session.evaluate("target", .{})).executed.status);
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
    try std.testing.expectEqual(@as(usize, 0), system.resources.count());
}

test "empty completion is exclusive while failures, limits and timeouts fall back" {
    const gpa = std.testing.allocator;
    var system: @import("../Host/System.zig") = .{ .gpa = gpa, .io = std.testing.io };
    defer system.deinit();
    var entered: std.atomic.Value(bool) = .init(false);
    const commands = [_]Command{
        .{ .name = "emit", .run = Test.emit },
        .{ .name = "mark", .userdata = &entered, .run = Test.mark },
    };
    var input: std.Io.Reader = .fixed("untouched\n");
    var session = try Session.init(gpa, system.host(), .{
        .cancel_io = std.testing.io,
        .commands = &commands,
        .context = .{ .io = .{ .stdin = &input } },
    });
    defer session.deinit();
    _ = try session.evaluate("__comp() { :; }; complete -F __comp git", .{});
    var registered: Registered = .{ .session = &session, .io = std.testing.io };
    const providers = [_]Provider{ registered.provider(), .{ .complete = Test.fallback } };
    const request: Provider.Request = .{ .context = try Completion.inspect("git ", 4, 0), .prefix = "" };
    var empty = try Provider.collect(gpa, request, &providers, .{});
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.candidates.len);
    try std.testing.expect(!empty.incomplete);
    const large = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(large);
    @memset(large, 'x');
    try session.setVariable("LARGE", large);
    for ([_][:0]const u8{
        "__comp() { emit partial; false; }",
        "__comp() { read value; }",
        "__comp() { emit \"$LARGE\"; }",
        "__comp() { while true; do :; done; }",
        "complete -F missing git",
    }) |source| {
        _ = try session.evaluate(source, .{});
        var result = try Provider.collect(gpa, request, &providers, .{ .bytes = 16 });
        defer result.deinit(gpa);
        try std.testing.expect(result.incomplete and !result.truncated and result.unique() == null);
        try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
        try std.testing.expectEqualStrings("fallback", result.candidates[0].value);
    }
    try std.testing.expectEqual(@as(usize, "untouched\n".len), input.bufferedLen());
    if (@import("builtin").target.os.tag != .windows and @import("builtin").target.os.tag != .wasi) {
        _ = try session.evaluate("__comp() { /bin/sleep 5; }; complete -F __comp git", .{});
        var external = try Provider.collect(gpa, request, &providers, .{});
        defer external.deinit(gpa);
        try std.testing.expect(external.incomplete);
        try std.testing.expectEqualStrings("fallback", external.candidates[0].value);
    }
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
    _ = try session.evaluate("__comp() { mark; while true; do :; done; }", .{});
    registered.timeout = .fromSeconds(2);
    const io = std.testing.io;
    var task = try io.concurrent(Provider.collect, .{ gpa, request, &providers, Provider.Limits{} });
    defer {
        if (task.cancel(io)) |value| {
            var owned = value;
            owned.deinit(gpa);
        } else |_| {}
    }
    for (0..1000) |_| {
        if (entered.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(entered.load(.acquire));
    try std.testing.expectError(error.Canceled, task.cancel(io));
    registered.timeout = .fromMilliseconds(100);
    try std.testing.expectEqual(@as(usize, 0), system.resources.count());
    // A timed-out or canceled call must not poison the next call.
    _ = try session.evaluate("__comp() { emit recovered; }; complete -F __comp git", .{});
    var recovered = try Provider.collect(gpa, request, &providers, .{});
    defer recovered.deinit(gpa);
    try std.testing.expectEqualStrings("recovered", recovered.unique().?.value);
}

const Test = struct {
    fn emit(_: ?*anyopaque, context: Command.Context, argv: []const []const u8) Command.Error!Command.Outcome {
        const writer = context.io.stdout orelse return .{ .failed = .io };
        for (argv[1..]) |arg| {
            writer.writeAll(arg) catch return .{ .failed = .io };
            writer.writeByte(0) catch return .{ .failed = .io };
        }
        return .{ .exited = 0 };
    }

    fn mark(userdata: ?*anyopaque, _: Command.Context, _: []const []const u8) Command.Error!Command.Outcome {
        const entered: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata.?));
        entered.store(true, .release);
        return .{ .exited = 0 };
    }

    fn fallback(_: ?*anyopaque, _: Provider.Request, collector: *Provider.Collector) Provider.Error!void {
        _ = try collector.add(.{ .value = "fallback" });
    }
};
