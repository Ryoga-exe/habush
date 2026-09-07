//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();
const Host = @import("Host.zig");
const RuntimeState = @import("RuntimeState.zig");
const VariableStore = @import("VariableStore.zig");

tag: Tag,
special: bool = false,

pub const Tag = enum {
    @":",
    true,
    false,
    cd,
    @"export",
    unset,
};

pub const Result = struct {
    status: u8,
};

/// Standard I/O endpoints available to builtins. A null stream discards
/// output. Non-null writers must remain valid for every execution using them.
pub const Io = struct {
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
};

pub const Context = struct {
    host: ?Host = null,
    runtime_state: ?*RuntimeState = null,
    variable_overrides: ?*const VariableStore = null,
    io: Io = .{},
};

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    HostUnavailable,
    RuntimeStateUnavailable,
};

const definitions = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .tag = .@":", .special = true } },
    .{ "true", Builtin{ .tag = .true } },
    .{ "false", Builtin{ .tag = .false } },
    .{ "cd", Builtin{ .tag = .cd } },
    .{ "export", Builtin{ .tag = .@"export", .special = true } },
    .{ "unset", Builtin{ .tag = .unset, .special = true } },
});

pub fn lookup(name: []const u8) ?Builtin {
    return definitions.get(name);
}

pub fn run(builtin: Builtin, context: Context, argv: []const []const u8) Error!Result {
    if (argv.len == 0) return .{ .status = 2 };
    return switch (builtin.tag) {
        .@":", .true => .{ .status = 0 },
        .false => .{ .status = 1 },
        .cd => runCd(context, argv),
        .@"export" => runExport(context, argv),
        .unset => runUnset(context, argv),
    };
}

fn runCd(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    const host = context.host orelse return error.HostUnavailable;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) {
        operands = operands[1..];
    } else if (operands.len != 0 and operands[0].len != 0 and operands[0][0] == '-') {
        // TODO: Support `cd -` after builtin output and OLDPWD handling exist.
        return .{ .status = 2 };
    }
    if (operands.len > 1) return .{ .status = 2 };

    const path = if (operands.len == 1)
        operands[0]
    else
        variable(context, "HOME") orelse return .{ .status = 1 };
    const resolved = host.resolveWorkingDirectory(state.allocator(), .{
        .current = state.workingDirectory(),
        .path = path,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = 1 },
    };
    defer state.allocator().free(resolved);
    try state.setWorkingDirectory(resolved);
    return .{ .status = 0 };
}

fn variable(context: Context, name: []const u8) ?[]const u8 {
    if (context.variable_overrides) |overrides|
        if (overrides.get(name)) |value| return value;
    if (context.runtime_state) |state| return state.variable(name);
    return null;
}

fn runExport(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: u8 = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len == 0) try writeExportedVariables(context.io.stdout, state.variableStore());
    for (operands) |operand| {
        if (operand.len != 0 and operand[0] == '-') {
            status = 2;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, operand, '=');
        const name = if (equals) |index| operand[0..index] else operand;
        if (!VariableStore.isValidName(name)) {
            status = 1;
            continue;
        }
        if (equals) |index|
            try setVariable(state, name, operand[index + 1 ..]);
        try setVariableExported(state, name);
    }
    return .{ .status = status };
}

fn writeExportedVariables(
    optional_writer: ?*std.Io.Writer,
    variables: *const VariableStore,
) std.Io.Writer.Error!void {
    const writer = optional_writer orelse return;
    var iterator = variables.iterator();
    while (iterator.next()) |binding| {
        if (!binding.exported) continue;
        try writer.writeAll("export ");
        try writer.writeAll(binding.name);
        try writer.writeAll("=");
        try writeShellQuoted(writer, binding.value);
        try writer.writeByte('\n');
    }
}

fn writeShellQuoted(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('\'');
    var remaining = value;
    while (std.mem.indexOfScalar(u8, remaining, '\'')) |index| {
        try writer.writeAll(remaining[0..index]);
        try writer.writeAll("'\\''");
        remaining = remaining[index + 1 ..];
    }
    try writer.writeAll(remaining);
    try writer.writeByte('\'');
}

fn runUnset(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: u8 = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    for (operands) |name| {
        if (!VariableStore.isValidName(name)) {
            status = if (name.len != 0 and name[0] == '-') 2 else 1;
            continue;
        }
        _ = state.unsetVariable(name);
    }
    return .{ .status = status };
}

fn setVariable(state: *RuntimeState, name: []const u8, value: []const u8) Error!void {
    state.setVariable(name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

fn setVariableExported(state: *RuntimeState, name: []const u8) Error!void {
    state.setVariableExported(name, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

test "looks up core builtins by command name" {
    try std.testing.expectEqual(Tag.@":", lookup(":").?.tag);
    try std.testing.expect(lookup(":").?.special);
    try std.testing.expectEqual(Tag.true, lookup("true").?.tag);
    try std.testing.expect(!lookup("false").?.special);
    try std.testing.expectEqual(Tag.cd, lookup("cd").?.tag);
    try std.testing.expect(!lookup("cd").?.special);
    try std.testing.expectEqual(Tag.@"export", lookup("export").?.tag);
    try std.testing.expect(lookup("export").?.special);
    try std.testing.expect(lookup("unset").?.special);
    try std.testing.expect(lookup("missing") == null);
    try std.testing.expect(lookup("./true") == null);
}

test "runs status-only core builtins" {
    try std.testing.expectEqual(@as(u8, 0), (try lookup(":").?.run(.{}, &.{":"})).status);
    try std.testing.expectEqual(@as(u8, 0), (try lookup("true").?.run(.{}, &.{"true"})).status);
    try std.testing.expectEqual(@as(u8, 1), (try lookup("false").?.run(.{}, &.{"false"})).status);
}

test "export and unset mutate runtime state" {
    var state = try RuntimeState.init(std.testing.allocator, .{});
    defer state.deinit();
    const context: Context = .{ .runtime_state = &state };

    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("export").?.run(context, &.{ "export", "NAME=value", "EMPTY" })).status,
    );
    try std.testing.expectEqualStrings("value", state.variable("NAME").?);
    try std.testing.expect(state.isVariableExported("NAME"));
    try std.testing.expectEqualStrings("", state.variable("EMPTY").?);
    try std.testing.expect(state.isVariableExported("EMPTY"));

    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("unset").?.run(context, &.{ "unset", "NAME", "missing" })).status,
    );
    try std.testing.expect(state.variable("NAME") == null);
}

test "export without operands writes exported variables" {
    var state = try RuntimeState.init(std.testing.allocator, .{
        .variables = &.{
            .{ .name = "PLAIN", .value = "value", .exported = true },
            .{ .name = "LOCAL", .value = "hidden" },
            .{ .name = "QUOTED", .value = "one'two", .exported = true },
        },
    });
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const result = try lookup("export").?.run(.{
        .runtime_state = &state,
        .io = .{ .stdout = &output.writer },
    }, &.{"export"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings(
        \\export PLAIN='value'
        \\export QUOTED='one'\''two'
        \\
    , output.written());
}

test "export propagates output failures" {
    var state = try RuntimeState.init(std.testing.allocator, .{
        .variables = &.{.{ .name = "NAME", .value = "value", .exported = true }},
    });
    defer state.deinit();
    var buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, lookup("export").?.run(.{
        .runtime_state = &state,
        .io = .{ .stdout = &output },
    }, &.{"export"}));
}

test "stateful builtins report invalid operands as command status" {
    var state = try RuntimeState.init(std.testing.allocator, .{});
    defer state.deinit();
    const context: Context = .{ .runtime_state = &state };

    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("export").?.run(context, &.{ "export", "not-valid" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("unset").?.run(context, &.{ "unset", "-f" })).status,
    );
    try std.testing.expectError(
        error.RuntimeStateUnavailable,
        lookup("export").?.run(.{}, &.{ "export", "NAME" }),
    );
}

test "cd resolves and persists the working directory" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/workspace/project";
    var state = try RuntimeState.init(std.testing.allocator, .{ .cwd = "/workspace" });
    defer state.deinit();

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
    }, &.{ "cd", "project" });

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace/project", state.workingDirectory().?);
    const request = fake.resolve_working_directory_calls.items[0];
    try std.testing.expectEqualStrings("/workspace", request.current.?);
    try std.testing.expectEqualStrings("project", request.path);
}

test "cd uses command-local HOME without persisting it" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/temporary";
    var state = try RuntimeState.init(std.testing.allocator, .{
        .variables = &.{.{ .name = "HOME", .value = "/home/user" }},
    });
    defer state.deinit();
    var overrides = VariableStore.init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.set("HOME", "/temporary");

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .variable_overrides = &overrides,
    }, &.{"cd"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/temporary", state.workingDirectory().?);
    try std.testing.expectEqualStrings("/home/user", state.variable("HOME").?);
    try std.testing.expectEqualStrings(
        "/temporary",
        fake.resolve_working_directory_calls.items[0].path,
    );
}

test "cd reports usage and host failures as command status" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.resolve_working_directory_error = error.AccessDenied;
    var state = try RuntimeState.init(std.testing.allocator, .{});
    defer state.deinit();
    const context: Context = .{ .host = fake.host(), .runtime_state = &state };

    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("cd").?.run(context, &.{ "cd", "one", "two" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("cd").?.run(context, &.{ "cd", "/denied" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("cd").?.run(context, &.{"cd"})).status,
    );
}

test "cd execution handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runCdWithAllocator,
        .{},
    );
}

fn runCdWithAllocator(gpa: std.mem.Allocator) !void {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    fake.working_directory_result = "/workspace/project";
    var state = try RuntimeState.init(gpa, .{ .cwd = "/workspace" });
    defer state.deinit();

    _ = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
    }, &.{ "cd", "project" });
}

test {
    std.testing.refAllDecls(@This());
}
