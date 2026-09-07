//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();
const RuntimeState = @import("RuntimeState.zig");
const VariableStore = @import("VariableStore.zig");

tag: Tag,
special: bool = false,

pub const Tag = enum {
    @":",
    true,
    false,
    @"export",
    unset,
};

pub const Result = struct {
    status: u8,
};

pub const Context = struct {
    runtime_state: ?*RuntimeState = null,
};

pub const Error = std.mem.Allocator.Error || error{RuntimeStateUnavailable};

const definitions = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .tag = .@":", .special = true } },
    .{ "true", Builtin{ .tag = .true } },
    .{ "false", Builtin{ .tag = .false } },
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
        .@"export" => runExport(context, argv),
        .unset => runUnset(context, argv),
    };
}

fn runExport(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: u8 = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
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
    // TODO: Render exported variables when the builtin I/O abstraction exists.
    return .{ .status = status };
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

test {
    std.testing.refAllDecls(@This());
}
