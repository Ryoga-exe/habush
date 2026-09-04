//! Persistent state for evaluating HIR units.

const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const Executor = @import("Executor.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const VariableStore = @import("VariableStore.zig");
const Session = @This();

gpa: std.mem.Allocator,
host: Host,
resolver: ?CommandResolver,
cwd: ?[]u8,
search_path: []const []const u8,
sandbox: CommandPlan.Sandbox,
variables: VariableStore,
last_result: Executor.Result = .{
    .status = 0,
    .sandbox_coverage = .not_requested,
},

pub const Options = struct {
    resolver: ?CommandResolver = null,
    cwd: ?[]const u8 = null,
    search_path: []const []const u8 = &.{},
    sandbox: CommandPlan.Sandbox = .inherit,
    variables: []const VariableStore.Binding = &.{},
};

pub fn init(
    gpa: std.mem.Allocator,
    host: Host,
    options: Options,
) VariableStore.Error!Session {
    const cwd = if (options.cwd) |path| try gpa.dupe(u8, path) else null;
    errdefer if (cwd) |path| gpa.free(path);

    const search_path = try cloneStrings(gpa, options.search_path);
    errdefer deinitStrings(gpa, search_path);

    var variables = VariableStore.init(gpa);
    errdefer variables.deinit();
    for (options.variables) |binding| try variables.set(binding.name, binding.value);

    const sandbox = try options.sandbox.clone(gpa);

    return .{
        .gpa = gpa,
        .host = host,
        .resolver = options.resolver,
        .cwd = cwd,
        .search_path = search_path,
        .sandbox = sandbox,
        .variables = variables,
    };
}

pub fn deinit(session: *Session) void {
    if (session.cwd) |cwd| session.gpa.free(cwd);
    deinitStrings(session.gpa, session.search_path);
    session.sandbox.deinit(session.gpa);
    session.variables.deinit();
    session.* = undefined;
}

pub fn execute(session: *Session, hir: Hir) Executor.Error!Executor.Result {
    const result = try Executor.initWithOptions(session.gpa, session.host, .{
        .sandbox = session.sandbox,
        .resolver = session.resolver,
        .search_path = session.search_path,
        .cwd = session.cwd,
        .variables = &session.variables,
    }).execute(hir);
    session.last_result = result;
    return result;
}

pub fn workingDirectory(session: Session) ?[]const u8 {
    return session.cwd;
}

pub fn commandSearchPath(session: Session) []const []const u8 {
    return session.search_path;
}

pub fn activeSandbox(session: Session) CommandPlan.Sandbox {
    return session.sandbox;
}

pub fn lastResult(session: Session) Executor.Result {
    return session.last_result;
}

pub fn variable(session: Session, name: []const u8) ?[]const u8 {
    return session.variables.get(name);
}

pub fn setVariable(session: *Session, name: []const u8, value: []const u8) VariableStore.Error!void {
    return session.variables.set(name, value);
}

pub fn unsetVariable(session: *Session, name: []const u8) bool {
    return session.variables.unset(name);
}

pub fn setWorkingDirectory(session: *Session, cwd: ?[]const u8) !void {
    const copy = if (cwd) |path| try session.gpa.dupe(u8, path) else null;
    if (session.cwd) |previous| session.gpa.free(previous);
    session.cwd = copy;
}

pub fn setCommandSearchPath(session: *Session, search_path: []const []const u8) !void {
    const copy = try cloneStrings(session.gpa, search_path);
    deinitStrings(session.gpa, session.search_path);
    session.search_path = copy;
}

pub fn setSandbox(session: *Session, sandbox: CommandPlan.Sandbox) !void {
    const copy = try sandbox.clone(session.gpa);
    session.sandbox.deinit(session.gpa);
    session.sandbox = copy;
}

fn cloneStrings(
    allocator: std.mem.Allocator,
    strings: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const copy = try allocator.alloc([]const u8, strings.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |string| allocator.free(string);
        allocator.free(copy);
    }
    for (strings, copy) |string, *destination| {
        destination.* = try allocator.dupe(u8, string);
        copied += 1;
    }
    return copy;
}

fn deinitStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

test {
    _ = @import("session_test.zig");
    std.testing.refAllDecls(@This());
}
