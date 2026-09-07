//! Persistent state for evaluating HIR units.

const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const Executor = @import("Executor.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const RuntimeState = @import("RuntimeState.zig");
const VariableStore = @import("VariableStore.zig");
const Session = @This();

host: Host,
resolver: ?CommandResolver,
state: RuntimeState,
last_result: Executor.Result = .{
    .status = 0,
    .sandbox_coverage = .not_requested,
},

pub const Options = struct {
    resolver: ?CommandResolver = null,
    cwd: ?[]const u8 = null,
    search_path: []const []const u8 = &.{},
    sandbox: CommandPlan.Sandbox = .inherit,
    /// Complete initial shell variable state. The caller should import the
    /// host environment here and mark those bindings exported when desired.
    variables: []const VariableStore.Binding = &.{},
};

pub fn init(
    gpa: std.mem.Allocator,
    host: Host,
    options: Options,
) VariableStore.Error!Session {
    return .{
        .host = host,
        .resolver = options.resolver,
        .state = try RuntimeState.init(gpa, .{
            .cwd = options.cwd,
            .search_path = options.search_path,
            .sandbox = options.sandbox,
            .variables = options.variables,
        }),
    };
}

pub fn deinit(session: *Session) void {
    session.state.deinit();
    session.* = undefined;
}

pub fn execute(session: *Session, hir: Hir) Executor.Error!Executor.Result {
    const result = try Executor.initWithOptions(session.state.allocator(), session.host, .{
        .sandbox = session.state.activeSandbox(),
        .resolver = session.resolver,
        .search_path = session.state.commandSearchPath(),
        .cwd = session.state.workingDirectory(),
        .variables = session.state.variableStore(),
    }).execute(hir);
    session.last_result = result;
    return result;
}

pub fn workingDirectory(session: Session) ?[]const u8 {
    return session.state.workingDirectory();
}

pub fn commandSearchPath(session: Session) []const []const u8 {
    return session.state.commandSearchPath();
}

pub fn activeSandbox(session: Session) CommandPlan.Sandbox {
    return session.state.activeSandbox();
}

pub fn lastResult(session: Session) Executor.Result {
    return session.last_result;
}

pub fn variable(session: Session, name: []const u8) ?[]const u8 {
    return session.state.variable(name);
}

pub fn setVariable(session: *Session, name: []const u8, value: []const u8) VariableStore.Error!void {
    return session.state.setVariable(name, value);
}

pub fn unsetVariable(session: *Session, name: []const u8) bool {
    return session.state.unsetVariable(name);
}

pub fn isVariableExported(session: Session, name: []const u8) bool {
    return session.state.isVariableExported(name);
}

pub fn setVariableExported(
    session: *Session,
    name: []const u8,
    exported: bool,
) VariableStore.Error!void {
    return session.state.setVariableExported(name, exported);
}

pub fn setWorkingDirectory(session: *Session, cwd: ?[]const u8) !void {
    return session.state.setWorkingDirectory(cwd);
}

pub fn setCommandSearchPath(session: *Session, search_path: []const []const u8) !void {
    return session.state.setCommandSearchPath(search_path);
}

pub fn setSandbox(session: *Session, sandbox: CommandPlan.Sandbox) !void {
    return session.state.setSandbox(sandbox);
}

test {
    _ = @import("session_test.zig");
    std.testing.refAllDecls(@This());
}
