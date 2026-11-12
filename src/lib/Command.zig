//! Application-supplied commands. Names and callbacks outlive their Session.
//! The registry is immutable during evaluation; guest runtimes stay outside sh.
const std = @import("std");
const runtime = @import("runtime.zig");
const CommandPlan = @import("CommandPlan.zig");

name: []const u8,
userdata: ?*anyopaque = null,
run: *const fn (?*anyopaque, Context, []const []const u8) Error!Outcome,

pub const Context = struct {
    gpa: std.mem.Allocator,
    cwd: ?[]const u8,
    environment: CommandPlan.Environment,
    io: runtime.Io,
};

pub const Error = std.mem.Allocator.Error || error{Canceled};
pub const Outcome = union(enum) { exited: runtime.ExitStatus, failed: Failure };
pub const Failure = enum {
    unavailable,
    timeout,
    limit_exceeded,
    invalid_response,
    permission_denied,
    io,
    trap,

    pub fn message(failure: Failure) []const u8 {
        return switch (failure) {
            .unavailable => "unavailable",
            .timeout => "timed out",
            .limit_exceeded => "resource limit exceeded",
            .invalid_response => "invalid response",
            .permission_denied => "permission denied",
            .io => "I/O failed",
            .trap => "trapped",
        };
    }
};

test "session commands receive scoped I/O and bindings without replacing functions or builtins" {
    const Session = @import("Session.zig");
    const FakeHost = @import("Host/FakeHost.zig");
    const Capture = struct {
        calls: usize = 0,
        bindings: bool = false,

        fn run(userdata: ?*anyopaque, context: Context, argv: []const []const u8) Error!Outcome {
            const capture: *@This() = @ptrCast(@alignCast(userdata.?));
            capture.calls += 1;
            if (argv.len != 2) return .{ .failed = .invalid_response };
            if (std.mem.eql(u8, argv[1], "fail")) return .{ .failed = .trap };
            if (context.environment == .replace) {
                for (context.environment.replace) |binding| {
                    if (std.mem.eql(u8, binding.name, "TEMP") and std.mem.eql(u8, binding.value, "local"))
                        capture.bindings = std.mem.eql(u8, context.cwd.?, "/workspace");
                }
            }
            if (context.io.stdout) |writer| writer.writeAll(argv[1]) catch return .{ .failed = .io };
            return .{ .exited = 7 };
        }
    };
    const gpa = std.testing.allocator;
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    var capture: Capture = .{};
    const commands = [_]@This(){
        .{ .name = "demo", .userdata = &capture, .run = Capture.run },
        .{ .name = "true", .userdata = &capture, .run = Capture.run },
    };
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(gpa);
    defer errors.deinit();
    var session = try Session.init(gpa, fake.host(), .{
        .commands = &commands,
        .context = .{ .cwd = "/workspace", .io = .{ .stdout = &output.writer, .stderr = &errors.writer } },
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(u8, 7), (try session.evaluate("TEMP=local demo 'a b'", .{})).executed.status);
    try std.testing.expect(capture.bindings);
    try std.testing.expectEqualStrings("a b", output.written());
    try std.testing.expectEqual(null, session.variable("TEMP"));
    try std.testing.expectEqual(@as(u8, 0), (try session.evaluate("true", .{})).executed.status);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u8, 7), (try session.evaluate("demo fail; demo ok", .{})).executed.status);
    try std.testing.expectEqualStrings("demo: extension failed: trapped\n", errors.written());
    try std.testing.expectEqual(@as(u8, 1), (try session.evaluate("demo() { false; }; demo", .{})).executed.status);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "standalone command boundary rejects pipeline, background and sandbox before redirects" {
    const Session = @import("Session.zig");
    const FakeHost = @import("Host/FakeHost.zig");
    const Never = struct {
        fn run(_: ?*anyopaque, _: Context, _: []const []const u8) Error!Outcome {
            @panic("unsupported extension reached callback");
        }
    };
    const gpa = std.testing.allocator;
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    const commands = [_]@This(){.{ .name = "demo", .run = Never.run }};
    var session = try Session.init(gpa, fake.host(), .{
        .commands = &commands,
        .context = .{ .cwd = "/workspace" },
    });
    defer session.deinit();
    for ([_][:0]const u8{ "demo >out &", "demo >out | missing" }) |source|
        try std.testing.expectEqual(error.UnsupportedInstruction, (try session.evaluate(source, .{})).unsupported);
    try session.context.setSandbox(.{ .restrict = .{} });
    try std.testing.expectEqual(error.UnsupportedInstruction, (try session.evaluate("demo >out", .{})).unsupported);
    try std.testing.expectEqual(@as(usize, 0), fake.open_file_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}
