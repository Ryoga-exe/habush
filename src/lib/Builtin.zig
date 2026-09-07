//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();
const Host = @import("Host.zig");
const RuntimeDiagnostic = @import("RuntimeDiagnostic.zig");
const RuntimeIo = @import("RuntimeIo.zig");
const RuntimeState = @import("RuntimeState.zig");
const VariableStore = @import("VariableStore.zig");

tag: Tag,
special: bool = false,

pub const Tag = enum {
    @":",
    true,
    false,
    cd,
    pwd,
    @"export",
    unset,
};

pub const Result = struct {
    status: u8,
};

pub const Context = struct {
    host: ?Host = null,
    runtime_state: ?*RuntimeState = null,
    variable_overrides: ?*const VariableStore = null,
    io: RuntimeIo = .{},
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
    .{ "pwd", Builtin{ .tag = .pwd } },
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
        .pwd => runPwd(context, argv),
        .@"export" => runExport(context, argv),
        .unset => runUnset(context, argv),
    };
}

fn runCd(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    const host = context.host orelse return error.HostUnavailable;
    var operands = argv[1..];
    var write_directory = false;
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) {
        operands = operands[1..];
    } else if (operands.len != 0 and std.mem.eql(u8, operands[0], "-")) {
        write_directory = true;
    } else if (operands.len != 0 and operands[0].len != 0 and operands[0][0] == '-') {
        return commandFailure(context, argv[0], .{ .unsupported_option = operands[0] });
    }
    if (operands.len > 1) return commandFailure(context, argv[0], .too_many_arguments);

    const path = if (write_directory)
        variable(context, "OLDPWD") orelse
            return commandFailure(context, argv[0], .{ .variable_not_set = "OLDPWD" })
    else if (operands.len == 1)
        operands[0]
    else
        variable(context, "HOME") orelse
            return commandFailure(context, argv[0], .{ .variable_not_set = "HOME" });
    const resolved = host.resolveWorkingDirectory(state.allocator(), .{
        .current = state.workingDirectory(),
        .path = path,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return commandFailure(
            context,
            argv[0],
            .{ .cannot_change_directory = path },
        ),
    };
    defer state.allocator().free(resolved);
    try state.changeWorkingDirectory(resolved);
    if (write_directory) {
        if (context.io.stdout) |stdout| {
            try stdout.writeAll(resolved);
            try stdout.writeByte('\n');
        }
    }
    return .{ .status = 0 };
}

fn variable(context: Context, name: []const u8) ?[]const u8 {
    if (context.variable_overrides) |overrides|
        if (overrides.get(name)) |value| return value;
    if (context.runtime_state) |state| return state.variable(name);
    return null;
}

fn runPwd(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len != 0) {
        const kind: RuntimeDiagnostic.Kind = if (operands[0].len != 0 and operands[0][0] == '-')
            .{ .unsupported_option = operands[0] }
        else
            .{ .unexpected_argument = operands[0] };
        return commandFailure(context, argv[0], kind);
    }

    const cwd = state.workingDirectory() orelse
        return commandFailure(context, argv[0], .working_directory_unavailable);
    if (context.io.stdout) |stdout| {
        try stdout.writeAll(cwd);
        try stdout.writeByte('\n');
    }
    return .{ .status = 0 };
}

fn runExport(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: u8 = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len == 0) try writeExportedVariables(context.io.stdout, state.variableStore());
    for (operands) |operand| {
        if (operand.len != 0 and operand[0] == '-') {
            status = @max(status, try reportCommandDiagnostic(
                context,
                argv[0],
                .{ .unsupported_option = operand },
            ));
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, operand, '=');
        const name = if (equals) |index| operand[0..index] else operand;
        if (!VariableStore.isValidName(name)) {
            status = @max(status, try reportCommandDiagnostic(
                context,
                argv[0],
                .{ .invalid_name = name },
            ));
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
            if (name.len != 0 and name[0] == '-') {
                status = @max(status, try reportCommandDiagnostic(
                    context,
                    argv[0],
                    .{ .unsupported_option = name },
                ));
            } else {
                status = @max(status, try reportCommandDiagnostic(
                    context,
                    argv[0],
                    .{ .invalid_name = name },
                ));
            }
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

fn commandFailure(
    context: Context,
    command: []const u8,
    kind: RuntimeDiagnostic.Kind,
) Error!Result {
    return .{ .status = try reportCommandDiagnostic(context, command, kind) };
}

fn reportCommandDiagnostic(
    context: Context,
    command: []const u8,
    kind: RuntimeDiagnostic.Kind,
) std.Io.Writer.Error!u8 {
    const diagnostic: RuntimeDiagnostic = .{
        .subject = .{ .command = command },
        .kind = kind,
    };
    try context.io.reportDiagnostic(diagnostic);
    return diagnostic.status();
}

test "looks up core builtins by command name" {
    try std.testing.expectEqual(Tag.@":", lookup(":").?.tag);
    try std.testing.expect(lookup(":").?.special);
    try std.testing.expectEqual(Tag.true, lookup("true").?.tag);
    try std.testing.expect(!lookup("false").?.special);
    try std.testing.expectEqual(Tag.cd, lookup("cd").?.tag);
    try std.testing.expect(!lookup("cd").?.special);
    try std.testing.expectEqual(Tag.pwd, lookup("pwd").?.tag);
    try std.testing.expect(!lookup("pwd").?.special);
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
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .runtime_state = &state,
        .io = .{ .stderr = &diagnostics.writer },
    };

    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("export").?.run(context, &.{ "export", "not-valid" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("unset").?.run(context, &.{ "unset", "-f" })).status,
    );
    try std.testing.expectEqualStrings(
        \\export: invalid name: not-valid
        \\unset: unsupported option: -f
        \\
    , diagnostics.written());
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

test "cd updates directory variables and dash uses OLDPWD" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/previous";
    var state = try RuntimeState.init(std.testing.allocator, .{
        .cwd = "/current",
        .variables = &.{
            .{ .name = "PWD", .value = "/current", .exported = true },
            .{ .name = "OLDPWD", .value = "/previous", .exported = true },
        },
    });
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .io = .{ .stdout = &output.writer },
    }, &.{ "cd", "-" });

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/previous", state.workingDirectory().?);
    try std.testing.expectEqualStrings("/previous", state.variable("PWD").?);
    try std.testing.expectEqualStrings("/current", state.variable("OLDPWD").?);
    try std.testing.expect(state.isVariableExported("PWD"));
    try std.testing.expect(state.isVariableExported("OLDPWD"));
    try std.testing.expectEqualStrings("/previous\n", output.written());
    try std.testing.expectEqualStrings(
        "/previous",
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
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .host = fake.host(),
        .runtime_state = &state,
        .io = .{ .stderr = &diagnostics.writer },
    };

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
    try std.testing.expectEqualStrings(
        \\cd: too many arguments
        \\cd: cannot change directory: /denied
        \\cd: HOME not set
        \\
    , diagnostics.written());
}

test "pwd writes the logical working directory" {
    var state = try RuntimeState.init(std.testing.allocator, .{ .cwd = "/workspace/project" });
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .runtime_state = &state,
        .io = .{
            .stdout = &output.writer,
            .stderr = &diagnostics.writer,
        },
    };

    const result = try lookup("pwd").?.run(context, &.{"pwd"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace/project\n", output.written());
    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("pwd").?.run(context, &.{ "pwd", "--" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("pwd").?.run(context, &.{ "pwd", "-P" })).status,
    );
    try std.testing.expectEqualStrings("pwd: unsupported option: -P\n", diagnostics.written());
}

test "builtin diagnostics propagate output failures" {
    var state = try RuntimeState.init(std.testing.allocator, .{ .cwd = "/workspace" });
    defer state.deinit();
    var buffer: [1]u8 = undefined;
    var diagnostics: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, lookup("pwd").?.run(.{
        .runtime_state = &state,
        .io = .{ .stderr = &diagnostics },
    }, &.{ "pwd", "-P" }));
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
