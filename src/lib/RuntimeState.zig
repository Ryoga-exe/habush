//! Owned mutable state shared by commands in one shell session.

const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const RuntimeState = @This();
const SandboxPolicy = @import("SandboxPolicy.zig");
const VariableStore = @import("VariableStore.zig");

gpa: std.mem.Allocator,
cwd: ?[]u8,
search_path: []const []const u8,
sandbox: CommandPlan.Sandbox,
variables: VariableStore,

pub const Options = struct {
    cwd: ?[]const u8 = null,
    search_path: []const []const u8 = &.{},
    sandbox: CommandPlan.Sandbox = .inherit,
    /// Complete initial shell variable state. The caller should import the
    /// host environment here and mark those bindings exported when desired.
    variables: []const VariableStore.Binding = &.{},
};

pub const Error = VariableStore.Error;

pub fn init(gpa: std.mem.Allocator, options: Options) Error!RuntimeState {
    const cwd = if (options.cwd) |path| try gpa.dupe(u8, path) else null;
    errdefer if (cwd) |path| gpa.free(path);

    const search_path = try cloneStrings(gpa, options.search_path);
    errdefer deinitStrings(gpa, search_path);

    var variables = VariableStore.init(gpa);
    errdefer variables.deinit();
    for (options.variables) |binding| {
        try variables.set(binding.name, binding.value);
        if (binding.exported) try variables.setExported(binding.name, true);
    }

    return .{
        .gpa = gpa,
        .cwd = cwd,
        .search_path = search_path,
        .sandbox = try options.sandbox.clone(gpa),
        .variables = variables,
    };
}

pub fn deinit(state: *RuntimeState) void {
    if (state.cwd) |cwd| state.gpa.free(cwd);
    deinitStrings(state.gpa, state.search_path);
    state.sandbox.deinit(state.gpa);
    state.variables.deinit();
    state.* = undefined;
}

pub fn allocator(state: RuntimeState) std.mem.Allocator {
    return state.gpa;
}

pub fn workingDirectory(state: RuntimeState) ?[]const u8 {
    return state.cwd;
}

pub fn commandSearchPath(state: RuntimeState) []const []const u8 {
    return state.search_path;
}

pub fn activeSandbox(state: RuntimeState) CommandPlan.Sandbox {
    return state.sandbox;
}

pub fn variableStore(state: *RuntimeState) *VariableStore {
    return &state.variables;
}

pub fn variable(state: RuntimeState, name: []const u8) ?[]const u8 {
    return state.variables.get(name);
}

pub fn setVariable(
    state: *RuntimeState,
    name: []const u8,
    value: []const u8,
) VariableStore.Error!void {
    return state.variables.set(name, value);
}

pub fn unsetVariable(state: *RuntimeState, name: []const u8) bool {
    return state.variables.unset(name);
}

pub fn isVariableExported(state: RuntimeState, name: []const u8) bool {
    return state.variables.isExported(name);
}

pub fn setVariableExported(
    state: *RuntimeState,
    name: []const u8,
    exported: bool,
) VariableStore.Error!void {
    return state.variables.setExported(name, exported);
}

pub fn setWorkingDirectory(state: *RuntimeState, cwd: ?[]const u8) std.mem.Allocator.Error!void {
    const copy = if (cwd) |path| try state.gpa.dupe(u8, path) else null;
    if (state.cwd) |previous| state.gpa.free(previous);
    state.cwd = copy;
}

pub fn setCommandSearchPath(
    state: *RuntimeState,
    search_path: []const []const u8,
) std.mem.Allocator.Error!void {
    const copy = try cloneStrings(state.gpa, search_path);
    deinitStrings(state.gpa, state.search_path);
    state.search_path = copy;
}

pub fn setSandbox(
    state: *RuntimeState,
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
    var search = [_]u8{ '/', 'b', 'i', 'n' };
    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var state = try RuntimeState.init(std.testing.allocator, .{
        .cwd = &cwd,
        .search_path = &.{&search},
        .variables = &.{.{ .name = &name, .value = &value, .exported = true }},
    });
    defer state.deinit();

    cwd[1] = 'x';
    search[1] = 'x';
    name[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqualStrings("/old", state.workingDirectory().?);
    try std.testing.expectEqualStrings("/bin", state.commandSearchPath()[0]);
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

fn initWithAllocator(gpa: std.mem.Allocator) !void {
    const search_path = [_][]const u8{ "/bin", "/usr/bin" };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/workspace", .access = .{ .read = true } },
    };
    var state = try RuntimeState.init(gpa, .{
        .cwd = "/workspace",
        .search_path = &search_path,
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .variables = &.{
            .{ .name = "first", .value = "one", .exported = true },
            .{ .name = "second", .value = "two" },
        },
    });
    defer state.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
