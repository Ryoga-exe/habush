//! Persistent state for evaluating shell input and HIR units.

const std = @import("std");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const Executor = @import("Executor.zig");
const Evaluation = @import("evaluation.zig").Result;
const ExecutionContext = @import("ExecutionContext.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const heredoc = @import("heredoc.zig");
const runtime = @import("runtime.zig");
const VariableStore = @import("VariableStore.zig");
const Session = @This();

host: Host,
resolver: ?CommandResolver,
context: ExecutionContext,
state: runtime.State,
last_result: Executor.Result = .{
    .status = 0,
    .sandbox_coverage = .not_requested,
},

pub const Options = struct {
    resolver: ?CommandResolver = null,
    context: ExecutionContext.View = .{},
    invocation_name: []const u8 = "habush",
    shell_process_id: ?runtime.ProcessId = null,
    /// Immutable fallback used only when PATH is unset. Set PATH through
    /// `variables` or `setVariable` to change the active search path.
    default_search_path: []const []const u8 = &.{},
    positional_parameters: []const []const u8 = &.{},
    /// Complete initial shell variable state. The caller should import the
    /// host environment here and mark those bindings exported when desired.
    variables: []const VariableStore.Binding = &.{},
};

pub const EvaluateOptions = struct {
    collected_here_documents: []const heredoc.Collected = &.{},
};

pub const EvaluateError = Ast.ParseError || AstGen.Error || Executor.Error;

pub fn init(
    gpa: std.mem.Allocator,
    host: Host,
    options: Options,
) VariableStore.Error!Session {
    var context = try ExecutionContext.init(gpa, options.context);
    errdefer context.deinit();
    return .{
        .host = host,
        .resolver = options.resolver,
        .context = context,
        .state = try runtime.State.init(gpa, .{
            .invocation_name = options.invocation_name,
            .shell_process_id = options.shell_process_id,
            .default_search_path = options.default_search_path,
            .positional_parameters = options.positional_parameters,
            .variables = options.variables,
        }),
    };
}

pub fn deinit(session: *Session) void {
    session.state.deinit();
    session.context.deinit();
    session.* = undefined;
}

pub fn allocator(session: Session) std.mem.Allocator {
    return session.state.allocator();
}

pub fn execute(session: *Session, hir: Hir) Executor.Error!Executor.Result {
    const result = try Executor.initWithState(
        session.host,
        session.resolver,
        &session.state,
        &session.context,
        session.last_result.status,
    ).execute(hir);
    session.last_result = result;
    return result;
}

/// Evaluates submitted input. Editor-only analysis should use `Ast.parse`
/// instead: rejected input here changes the shell's previous exit status.
/// The caller must deinit the returned value with this session's allocator;
/// a syntax result borrows `source` and collected here-document bodies.
pub fn evaluate(
    session: *Session,
    source: [:0]const u8,
    options: EvaluateOptions,
) EvaluateError!Evaluation {
    const gpa = session.allocator();
    var tree = try Ast.parseWithOptions(gpa, source, .{
        .collected_here_documents = options.collected_here_documents,
    });
    if (tree.errors.len != 0 or tree.status != .complete) {
        session.rejectInput();
        return .{ .syntax = tree };
    }
    defer tree.deinit(gpa);

    var hir = try AstGen.generate(gpa, tree);
    defer hir.deinit(gpa);
    if (hir.root() == null) {
        session.last_result = .{
            .status = session.last_result.status,
            .sandbox_coverage = .not_requested,
        };
        return .{ .executed = session.last_result };
    }
    const result = session.execute(hir) catch |err| switch (err) {
        error.UnsupportedInstruction,
        error.ParameterAssignmentUnavailable,
        error.PathnameExpansionUnsupported,
        error.TildeExpansionUnsupported,
        error.ParameterExpansionUnsupported,
        => {
            session.rejectInput();
            return .{ .unsupported = @errorCast(err) };
        },
        else => |other| return other,
    };
    return .{ .executed = result };
}

/// Records a submitted-input failure detected by an input adapter, such as
/// EOF while collecting a here-document. Merely inspecting input is not a
/// rejection and must not call this operation.
pub fn rejectInput(session: *Session) void {
    session.last_result = .{ .status = 2, .sandbox_coverage = .not_requested };
}

pub fn workingDirectory(session: Session) ?[]const u8 {
    return session.context.workingDirectory();
}

pub fn invocationName(session: Session) []const u8 {
    return session.state.invocationName();
}

pub fn positionalParameters(session: Session) []const []const u8 {
    return session.state.positionalParameters();
}

pub fn activeSandbox(session: Session) CommandPlan.Sandbox {
    return session.context.activeSandbox();
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

pub fn changeWorkingDirectory(session: *Session, path: []const u8) !void {
    const cwd = try session.host.resolveWorkingDirectory(session.state.allocator(), .{
        .current = session.context.workingDirectory(),
        .path = path,
    });
    defer session.state.allocator().free(cwd);
    return session.state.changeWorkingDirectory(&session.context, cwd);
}

pub fn setPositionalParameters(
    session: *Session,
    positional_parameters: []const []const u8,
) !void {
    return session.state.setPositionalParameters(positional_parameters);
}

pub fn setSandbox(session: *Session, sandbox: CommandPlan.Sandbox) !void {
    return session.context.setSandbox(sandbox);
}

test {
    _ = @import("session_test.zig");
    std.testing.refAllDecls(@This());
}
