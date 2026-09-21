//! Owned mutable state shared by commands in one shell session.

const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const FunctionStore = @import("../FunctionStore.zig");
const Hir = @import("../Hir.zig");
const State = @This();
const SandboxPolicy = @import("../SandboxPolicy.zig");
const VariableStore = @import("../VariableStore.zig");

gpa: std.mem.Allocator,
cwd: ?[]u8,
invocation_name: []u8,
search_path: []const []const u8,
positional_parameters: []const []const u8,
sandbox: CommandPlan.Sandbox,
variables: VariableStore,
functions: FunctionStore,

pub const Options = struct {
    cwd: ?[]const u8 = null,
    invocation_name: []const u8 = "habush",
    search_path: []const []const u8 = &.{},
    positional_parameters: []const []const u8 = &.{},
    sandbox: CommandPlan.Sandbox = .inherit,
    /// Complete initial shell variable state. The caller should import the
    /// host environment here and mark those bindings exported when desired.
    variables: []const VariableStore.Binding = &.{},
};

pub const Error = VariableStore.Error;

pub fn init(gpa: std.mem.Allocator, options: Options) Error!State {
    const cwd = if (options.cwd) |path| try gpa.dupe(u8, path) else null;
    errdefer if (cwd) |path| gpa.free(path);

    const invocation_name = try gpa.dupe(u8, options.invocation_name);
    errdefer gpa.free(invocation_name);

    const search_path = try cloneStrings(gpa, options.search_path);
    errdefer deinitStrings(gpa, search_path);

    const positional_parameters = try cloneStrings(gpa, options.positional_parameters);
    errdefer deinitStrings(gpa, positional_parameters);

    var variables = VariableStore.init(gpa);
    errdefer variables.deinit();
    for (options.variables) |binding| {
        try variables.set(binding.name, binding.value);
        if (binding.exported) try variables.setExported(binding.name, true);
    }

    return .{
        .gpa = gpa,
        .cwd = cwd,
        .invocation_name = invocation_name,
        .search_path = search_path,
        .positional_parameters = positional_parameters,
        .sandbox = try options.sandbox.clone(gpa),
        .variables = variables,
        .functions = FunctionStore.init(gpa),
    };
}

pub fn deinit(state: *State) void {
    if (state.cwd) |cwd| state.gpa.free(cwd);
    state.gpa.free(state.invocation_name);
    deinitStrings(state.gpa, state.search_path);
    deinitStrings(state.gpa, state.positional_parameters);
    state.sandbox.deinit(state.gpa);
    state.variables.deinit();
    state.functions.deinit();
    state.* = undefined;
}

pub fn clone(state: State) std.mem.Allocator.Error!State {
    const cwd = if (state.cwd) |path| try state.gpa.dupe(u8, path) else null;
    errdefer if (cwd) |path| state.gpa.free(path);

    const invocation_name = try state.gpa.dupe(u8, state.invocation_name);
    errdefer state.gpa.free(invocation_name);

    const search_path = try cloneStrings(state.gpa, state.search_path);
    errdefer deinitStrings(state.gpa, search_path);

    const positional_parameters = try cloneStrings(state.gpa, state.positional_parameters);
    errdefer deinitStrings(state.gpa, positional_parameters);

    var sandbox = try state.sandbox.clone(state.gpa);
    errdefer sandbox.deinit(state.gpa);

    var variables = try state.variables.clone(state.gpa);
    errdefer variables.deinit();

    return .{
        .gpa = state.gpa,
        .cwd = cwd,
        .invocation_name = invocation_name,
        .search_path = search_path,
        .positional_parameters = positional_parameters,
        .sandbox = sandbox,
        .variables = variables,
        .functions = try state.functions.clone(state.gpa),
    };
}

pub fn allocator(state: State) std.mem.Allocator {
    return state.gpa;
}

pub fn workingDirectory(state: State) ?[]const u8 {
    return state.cwd;
}

pub fn invocationName(state: State) []const u8 {
    return state.invocation_name;
}

pub fn commandSearchPath(state: State) []const []const u8 {
    return state.search_path;
}

pub fn positionalParameters(state: State) []const []const u8 {
    return state.positional_parameters;
}

pub fn activeSandbox(state: State) CommandPlan.Sandbox {
    return state.sandbox;
}

pub fn variableStore(state: *State) *VariableStore {
    return &state.variables;
}

pub fn functionStore(state: *State) *FunctionStore {
    return &state.functions;
}

pub fn defineFunction(
    state: *State,
    name: []const u8,
    hir: Hir,
    body: Hir.Inst.Index,
) FunctionStore.Error!void {
    return state.functions.set(name, hir, body);
}

pub fn cloneFunction(
    state: State,
    name: []const u8,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!?FunctionStore.Definition {
    return state.functions.cloneDefinition(name, gpa);
}

pub fn variable(state: State, name: []const u8) ?[]const u8 {
    return state.variables.get(name);
}

pub fn setVariable(
    state: *State,
    name: []const u8,
    value: []const u8,
) VariableStore.Error!void {
    return state.variables.set(name, value);
}

pub fn unsetVariable(state: *State, name: []const u8) bool {
    return state.variables.unset(name);
}

pub fn isVariableExported(state: State, name: []const u8) bool {
    return state.variables.isExported(name);
}

pub fn setVariableExported(
    state: *State,
    name: []const u8,
    exported: bool,
) VariableStore.Error!void {
    return state.variables.setExported(name, exported);
}

pub fn setWorkingDirectory(state: *State, cwd: ?[]const u8) std.mem.Allocator.Error!void {
    const copy = if (cwd) |path| try state.gpa.dupe(u8, path) else null;
    if (state.cwd) |previous| state.gpa.free(previous);
    state.cwd = copy;
}

/// Applies a successful `cd` while keeping the directory and its shell
/// variables unchanged if any allocation fails.
pub fn changeWorkingDirectory(state: *State, cwd: []const u8) std.mem.Allocator.Error!void {
    const cwd_copy = try state.gpa.dupe(u8, cwd);
    errdefer state.gpa.free(cwd_copy);

    var variables = try state.variables.clone(state.gpa);
    errdefer variables.deinit();
    if (state.cwd) |previous| try setKnownVariable(&variables, "OLDPWD", previous);
    try setKnownVariable(&variables, "PWD", cwd);

    if (state.cwd) |previous| state.gpa.free(previous);
    state.cwd = cwd_copy;
    state.variables.deinit();
    state.variables = variables;
}

fn setKnownVariable(
    variables: *VariableStore,
    name: []const u8,
    value: []const u8,
) std.mem.Allocator.Error!void {
    variables.set(name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

pub fn setCommandSearchPath(
    state: *State,
    search_path: []const []const u8,
) std.mem.Allocator.Error!void {
    const copy = try cloneStrings(state.gpa, search_path);
    deinitStrings(state.gpa, state.search_path);
    state.search_path = copy;
}

pub fn setPositionalParameters(
    state: *State,
    positional_parameters: []const []const u8,
) std.mem.Allocator.Error!void {
    const copy = try cloneStrings(state.gpa, positional_parameters);
    deinitStrings(state.gpa, state.positional_parameters);
    state.positional_parameters = copy;
}

pub fn setSandbox(
    state: *State,
    sandbox: CommandPlan.Sandbox,
) std.mem.Allocator.Error!void {
    const copy = try sandbox.clone(state.gpa);
    state.sandbox.deinit(state.gpa);
    state.sandbox = copy;
}

fn cloneStrings(
    allocator_value: std.mem.Allocator,
    strings: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const copy = try allocator_value.alloc([]const u8, strings.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |string| allocator_value.free(string);
        allocator_value.free(copy);
    }
    for (strings, copy) |string, *destination| {
        destination.* = try allocator_value.dupe(u8, string);
        copied += 1;
    }
    return copy;
}

fn deinitStrings(allocator_value: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator_value.free(string);
    allocator_value.free(strings);
}

test "runtime state owns mutable session values" {
    var cwd = [_]u8{ '/', 'o', 'l', 'd' };
    var invocation_name = [_]u8{ 's', 'c', 'r', 'i', 'p', 't' };
    var search = [_]u8{ '/', 'b', 'i', 'n' };
    var positional = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var allowed = [_]u8{ '/', 'o', 'l', 'd' };
    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = &allowed, .access = .{ .read = true } },
    };
    var state = try State.init(std.testing.allocator, .{
        .cwd = &cwd,
        .invocation_name = &invocation_name,
        .search_path = &.{&search},
        .positional_parameters = &.{&positional},
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .variables = &.{.{ .name = &name, .value = &value, .exported = true }},
    });
    defer state.deinit();

    cwd[1] = 'x';
    invocation_name[0] = 'x';
    search[1] = 'x';
    positional[0] = 'x';
    allowed[1] = 'x';
    name[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqualStrings("/old", state.workingDirectory().?);
    try std.testing.expectEqualStrings("script", state.invocationName());
    try std.testing.expectEqualStrings("/bin", state.commandSearchPath()[0]);
    try std.testing.expectEqualStrings("value", state.positionalParameters()[0]);
    try std.testing.expectEqualStrings(
        "/old",
        state.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expectEqualStrings("value", state.variable("name").?);
    try std.testing.expect(state.isVariableExported("name"));
}

test "runtime state initialization handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initWithAllocator,
        .{},
    );
}

test "runtime state clone is independent" {
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/allowed", .access = .{ .read = true } },
    };
    var state = try State.init(std.testing.allocator, .{
        .cwd = "/old",
        .invocation_name = "script.hb",
        .search_path = &.{"/bin"},
        .positional_parameters = &.{"argument"},
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .variables = &.{.{ .name = "name", .value = "original", .exported = true }},
    });
    defer state.deinit();
    var copy = try state.clone();
    defer copy.deinit();

    copy.invocation_name[0] = 'x';
    try copy.setWorkingDirectory("/new");
    try copy.setCommandSearchPath(&.{"/usr/bin"});
    try copy.setPositionalParameters(&.{"changed"});
    try copy.setSandbox(.inherit);
    try copy.setVariable("name", "changed");

    try std.testing.expectEqualStrings("/old", state.workingDirectory().?);
    try std.testing.expectEqualStrings("script.hb", state.invocationName());
    try std.testing.expectEqualStrings("/bin", state.commandSearchPath()[0]);
    try std.testing.expectEqualStrings("argument", state.positionalParameters()[0]);
    try std.testing.expectEqualStrings("original", state.variable("name").?);
    try std.testing.expect(state.isVariableExported("name"));
    try std.testing.expectEqualStrings(
        "/allowed",
        state.activeSandbox().restrict.file_system.allow[0].path,
    );
}

test "runtime state clone handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneWithAllocator,
        .{},
    );
}

test "directory change updates PWD and OLDPWD atomically" {
    var state = try State.init(std.testing.allocator, .{
        .cwd = "/old",
        .variables = &.{
            .{ .name = "PWD", .value = "/old", .exported = true },
            .{ .name = "OLDPWD", .value = "/older", .exported = true },
            .{ .name = "LOCAL", .value = "value" },
        },
    });
    defer state.deinit();

    try state.changeWorkingDirectory("/new");

    try std.testing.expectEqualStrings("/new", state.workingDirectory().?);
    try std.testing.expectEqualStrings("/new", state.variable("PWD").?);
    try std.testing.expectEqualStrings("/old", state.variable("OLDPWD").?);
    try std.testing.expect(state.isVariableExported("PWD"));
    try std.testing.expect(state.isVariableExported("OLDPWD"));
    try std.testing.expectEqualStrings("value", state.variable("LOCAL").?);
}

test "directory change handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        changeWorkingDirectoryWithAllocator,
        .{},
    );
}

fn changeWorkingDirectoryWithAllocator(gpa: std.mem.Allocator) !void {
    var state = try State.init(gpa, .{
        .cwd = "/old",
        .variables = &.{
            .{ .name = "PWD", .value = "/old", .exported = true },
            .{ .name = "OLDPWD", .value = "/older", .exported = true },
            .{ .name = "LOCAL", .value = "value" },
        },
    });
    defer state.deinit();

    state.changeWorkingDirectory("/new") catch |err| {
        try std.testing.expectEqualStrings("/old", state.workingDirectory().?);
        try std.testing.expectEqualStrings("/old", state.variable("PWD").?);
        try std.testing.expectEqualStrings("/older", state.variable("OLDPWD").?);
        try std.testing.expectEqualStrings("value", state.variable("LOCAL").?);
        return err;
    };
}

fn initWithAllocator(gpa: std.mem.Allocator) !void {
    const search_path = [_][]const u8{ "/bin", "/usr/bin" };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/workspace", .access = .{ .read = true } },
    };
    var state = try State.init(gpa, .{
        .cwd = "/workspace",
        .invocation_name = "script.hb",
        .search_path = &search_path,
        .positional_parameters = &.{ "one", "two" },
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .variables = &.{
            .{ .name = "first", .value = "one", .exported = true },
            .{ .name = "second", .value = "two" },
        },
    });
    defer state.deinit();
}

fn cloneWithAllocator(gpa: std.mem.Allocator) !void {
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/workspace", .access = .{ .read = true } },
    };
    var state = try State.init(gpa, .{
        .cwd = "/workspace",
        .invocation_name = "script.hb",
        .search_path = &.{"/bin"},
        .positional_parameters = &.{"argument"},
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .variables = &.{.{ .name = "name", .value = "value", .exported = true }},
    });
    defer state.deinit();
    var copy = try state.clone();
    defer copy.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
