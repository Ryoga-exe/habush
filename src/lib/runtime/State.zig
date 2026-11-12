//! Owned mutable state shared by commands in one shell session.

const std = @import("std");
const ExecutionContext = @import("../ExecutionContext.zig");
const FunctionStore = @import("../FunctionStore.zig");
const Hir = @import("../Hir.zig");
const State = @This();
const types = @import("types.zig");
const VariableStore = @import("../VariableStore.zig");
const CompletionRegistry = @import("../Completion/Registry.zig");

gpa: std.mem.Allocator,
invocation_name: []u8,
shell_process_id: ?types.ProcessId,
default_search_path: []const []const u8,
positional_parameters: []const []const u8,
variables: VariableStore,
functions: FunctionStore,
completions: CompletionRegistry,

pub const Options = struct {
    invocation_name: []const u8 = "habush",
    shell_process_id: ?types.ProcessId = null,
    /// Immutable fallback used only when the shell variable PATH is unset.
    default_search_path: []const []const u8 = &.{},
    positional_parameters: []const []const u8 = &.{},
    /// Complete initial shell variable state. The caller should import the
    /// host environment here and mark those bindings exported when desired.
    variables: []const VariableStore.Binding = &.{},
};

pub const Error = VariableStore.Error;

pub fn init(gpa: std.mem.Allocator, options: Options) Error!State {
    const invocation_name = try gpa.dupe(u8, options.invocation_name);
    errdefer gpa.free(invocation_name);

    const default_search_path = try cloneStrings(gpa, options.default_search_path);
    errdefer deinitStrings(gpa, default_search_path);

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
        .invocation_name = invocation_name,
        .shell_process_id = options.shell_process_id,
        .default_search_path = default_search_path,
        .positional_parameters = positional_parameters,
        .variables = variables,
        .functions = FunctionStore.init(gpa),
        .completions = .{ .gpa = gpa },
    };
}

pub fn deinit(state: *State) void {
    state.gpa.free(state.invocation_name);
    deinitStrings(state.gpa, state.default_search_path);
    deinitStrings(state.gpa, state.positional_parameters);
    state.variables.deinit();
    state.functions.deinit();
    state.completions.deinit();
    state.* = undefined;
}

pub fn clone(state: State) std.mem.Allocator.Error!State {
    return state.cloneWithAllocator(state.gpa);
}

/// Makes a fully owned copy whose future mutations use `allocator`.
pub fn cloneWithAllocator(state: State, gpa: std.mem.Allocator) std.mem.Allocator.Error!State {
    const invocation_name = try gpa.dupe(u8, state.invocation_name);
    errdefer gpa.free(invocation_name);

    const default_search_path = try cloneStrings(gpa, state.default_search_path);
    errdefer deinitStrings(gpa, default_search_path);

    const positional_parameters = try cloneStrings(gpa, state.positional_parameters);
    errdefer deinitStrings(gpa, positional_parameters);

    var variables = try state.variables.clone(gpa);
    errdefer variables.deinit();
    var completions = try state.completions.clone(gpa);
    errdefer completions.deinit();

    return .{
        .gpa = gpa,
        .invocation_name = invocation_name,
        .shell_process_id = state.shell_process_id,
        .default_search_path = default_search_path,
        .positional_parameters = positional_parameters,
        .variables = variables,
        .functions = try state.functions.clone(gpa),
        .completions = completions,
    };
}

pub fn allocator(state: State) std.mem.Allocator {
    return state.gpa;
}

pub fn invocationName(state: State) []const u8 {
    return state.invocation_name;
}

pub fn shellProcessId(state: State) ?types.ProcessId {
    return state.shell_process_id;
}

pub fn defaultSearchPath(state: State) []const []const u8 {
    return state.default_search_path;
}

pub fn positionalParameters(state: State) []const []const u8 {
    return state.positional_parameters;
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

/// Applies a successful `cd` while keeping the directory and its shell
/// variables unchanged if any allocation fails.
pub fn changeWorkingDirectory(
    state: *State,
    context: *ExecutionContext,
    cwd: []const u8,
) std.mem.Allocator.Error!void {
    const cwd_copy = try context.allocator().dupe(u8, cwd);
    errdefer context.allocator().free(cwd_copy);

    var variables = try state.variables.clone(state.gpa);
    errdefer variables.deinit();
    if (context.workingDirectory()) |previous| try setKnownVariable(&variables, "OLDPWD", previous);
    try setKnownVariable(&variables, "PWD", cwd);

    context.replaceWorkingDirectoryOwned(cwd_copy);
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

pub fn setPositionalParameters(
    state: *State,
    positional_parameters: []const []const u8,
) std.mem.Allocator.Error!void {
    const copy = try cloneStrings(state.gpa, positional_parameters);
    deinitStrings(state.gpa, state.positional_parameters);
    state.positional_parameters = copy;
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
    var invocation_name = [_]u8{ 's', 'c', 'r', 'i', 'p', 't' };
    var search = [_]u8{ '/', 'b', 'i', 'n' };
    var positional = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var state = try State.init(std.testing.allocator, .{
        .invocation_name = &invocation_name,
        .default_search_path = &.{&search},
        .positional_parameters = &.{&positional},
        .variables = &.{.{ .name = &name, .value = &value, .exported = true }},
    });
    defer state.deinit();

    invocation_name[0] = 'x';
    search[1] = 'x';
    positional[0] = 'x';
    name[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqualStrings("script", state.invocationName());
    try std.testing.expectEqualStrings("/bin", state.defaultSearchPath()[0]);
    try std.testing.expectEqualStrings("value", state.positionalParameters()[0]);
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
    var state = try State.init(std.testing.allocator, .{
        .invocation_name = "script.hb",
        .shell_process_id = @fromBackingInt(12345),
        .default_search_path = &.{"/bin"},
        .positional_parameters = &.{"argument"},
        .variables = &.{.{ .name = "name", .value = "original", .exported = true }},
    });
    defer state.deinit();
    var copy = try state.clone();
    defer copy.deinit();

    copy.invocation_name[0] = 'x';
    @constCast(copy.default_search_path[0])[1] = 'x';
    try copy.setPositionalParameters(&.{"changed"});
    try copy.setVariable("name", "changed");

    try std.testing.expectEqualStrings("script.hb", state.invocationName());
    try std.testing.expectEqual(@as(?types.ProcessId, @fromBackingInt(12345)), state.shellProcessId());
    try std.testing.expectEqual(state.shellProcessId(), copy.shellProcessId());
    try std.testing.expectEqualStrings("/bin", state.defaultSearchPath()[0]);
    try std.testing.expectEqualStrings("argument", state.positionalParameters()[0]);
    try std.testing.expectEqualStrings("original", state.variable("name").?);
    try std.testing.expect(state.isVariableExported("name"));
}

test "runtime state clone handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCloneAllocations,
        .{},
    );
}

test "directory change updates PWD and OLDPWD atomically" {
    var state = try State.init(std.testing.allocator, .{
        .variables = &.{
            .{ .name = "PWD", .value = "/old", .exported = true },
            .{ .name = "OLDPWD", .value = "/older", .exported = true },
            .{ .name = "LOCAL", .value = "value" },
        },
    });
    defer state.deinit();
    var context = try ExecutionContext.init(std.testing.allocator, .{ .cwd = "/old" });
    defer context.deinit();

    try state.changeWorkingDirectory(&context, "/new");

    try std.testing.expectEqualStrings("/new", context.workingDirectory().?);
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
        .variables = &.{
            .{ .name = "PWD", .value = "/old", .exported = true },
            .{ .name = "OLDPWD", .value = "/older", .exported = true },
            .{ .name = "LOCAL", .value = "value" },
        },
    });
    defer state.deinit();
    var context = try ExecutionContext.init(gpa, .{ .cwd = "/old" });
    defer context.deinit();

    state.changeWorkingDirectory(&context, "/new") catch |err| {
        try std.testing.expectEqualStrings("/old", context.workingDirectory().?);
        try std.testing.expectEqualStrings("/old", state.variable("PWD").?);
        try std.testing.expectEqualStrings("/older", state.variable("OLDPWD").?);
        try std.testing.expectEqualStrings("value", state.variable("LOCAL").?);
        return err;
    };
}

fn initWithAllocator(gpa: std.mem.Allocator) !void {
    const search_path = [_][]const u8{ "/bin", "/usr/bin" };
    var state = try State.init(gpa, .{
        .invocation_name = "script.hb",
        .default_search_path = &search_path,
        .positional_parameters = &.{ "one", "two" },
        .variables = &.{
            .{ .name = "first", .value = "one", .exported = true },
            .{ .name = "second", .value = "two" },
        },
    });
    defer state.deinit();
}

fn exerciseCloneAllocations(gpa: std.mem.Allocator) !void {
    var state = try State.init(gpa, .{
        .invocation_name = "script.hb",
        .default_search_path = &.{"/bin"},
        .positional_parameters = &.{"argument"},
        .variables = &.{.{ .name = "name", .value = "value", .exported = true }},
    });
    defer state.deinit();
    try state.completions.set("git", .{ .function = "__complete" });
    var copy = try state.clone();
    defer copy.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
