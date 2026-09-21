//! Executes Habush HIR through a `Host`.
//!
//! The current runtime foundation executes empty units, foreground sequential
//! lists, and-or commands, pipeline negation, brace groups, if clauses,
//! while/until/for loops with break/continue control, standalone assignments,
//! builtins, and external simple commands.
//! Standard-stream redirections are supported for simple commands, brace
//! groups, and subshells. Redirects on conditional and loop clauses, here
//! documents, background execution, and pipelines remain explicit
//! `UnsupportedInstruction` boundaries.

const std = @import("std");
const Builtin = @import("Builtin.zig");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const Executor = @This();
const Expander = @import("Expander.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const runtime = @import("runtime.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const VariableStore = @import("VariableStore.zig");

gpa: std.mem.Allocator,
host: Host,
sandbox: CommandPlan.Sandbox,
resolver: ?CommandResolver,
search_path: []const []const u8,
invocation_name: []const u8,
shell_process_id: ?runtime.ProcessId,
positional_parameters: []const []const u8,
positional_parameters_override: ?[]const []const u8,
cwd: ?[]const u8,
variables: ?*VariableStore,
runtime_state: ?*runtime.State,
io: runtime.Io,
scoped_file_actions: []const CommandPlan.FileAction,
last_status: runtime.ExitStatus,
loop_depth: u32,
function_depth: u32,

const max_function_depth = 64;

/// Failures that prevent the runtime from producing a shell-visible `Result`.
/// Expected command failures are reported through `Result.status` and, when
/// appropriate, a diagnostic written to `Io.stderr`.
pub const Error = Builtin.Error || Host.Error || Expander.Error || CommandResolver.Error || VariableStore.Error || error{
    UnsupportedInstruction,
    CommandResolutionUnavailable,
    UnexpectedTermination,
    VariableStateUnavailable,
    FunctionStateUnavailable,
};

pub const Options = struct {
    sandbox: CommandPlan.Sandbox = .inherit,
    resolver: ?CommandResolver = null,
    search_path: []const []const u8 = &.{},
    invocation_name: []const u8 = "habush",
    shell_process_id: ?runtime.ProcessId = null,
    positional_parameters: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// Complete shell variable state. When present, exported bindings become
    /// an exact replacement environment; `null` preserves host inheritance.
    variables: ?*VariableStore = null,
    io: runtime.Io = .{},
    /// Status visible to a command such as `exit` when no operand is given.
    last_status: runtime.ExitStatus = 0,
};

/// The shell-visible outcome of a completed HIR unit.
pub const Result = struct {
    status: runtime.ExitStatus,
    sandbox_coverage: SandboxPolicy.Coverage,
    control_flow: runtime.ControlFlow = .none,
};

pub fn init(gpa: std.mem.Allocator, host: Host) Executor {
    return initWithOptions(gpa, host, .{});
}

pub fn initWithOptions(gpa: std.mem.Allocator, host: Host, options: Options) Executor {
    return .{
        .gpa = gpa,
        .host = host,
        .sandbox = options.sandbox,
        .resolver = options.resolver,
        .search_path = options.search_path,
        .invocation_name = options.invocation_name,
        .shell_process_id = options.shell_process_id,
        .positional_parameters = options.positional_parameters,
        .positional_parameters_override = null,
        .cwd = options.cwd,
        .variables = options.variables,
        .runtime_state = null,
        .io = options.io,
        .scoped_file_actions = &.{},
        .last_status = options.last_status,
        .loop_depth = 0,
        .function_depth = 0,
    };
}

pub fn initWithState(
    host: Host,
    resolver: ?CommandResolver,
    state: *runtime.State,
    io: runtime.Io,
    last_status: runtime.ExitStatus,
) Executor {
    return .{
        .gpa = state.allocator(),
        .host = host,
        .sandbox = .inherit,
        .resolver = resolver,
        .search_path = &.{},
        .invocation_name = "",
        .shell_process_id = null,
        .positional_parameters = &.{},
        .positional_parameters_override = null,
        .cwd = null,
        .variables = null,
        .runtime_state = state,
        .io = io,
        .scoped_file_actions = &.{},
        .last_status = last_status,
        .loop_depth = 0,
        .function_depth = 0,
    };
}

/// Executes a complete HIR unit and returns its shell-visible result.
pub fn execute(executor: Executor, hir: Hir) Error!Result {
    const root = hir.root() orelse return .{
        .status = 0,
        .sandbox_coverage = .not_requested,
    };
    return executor.executeInstruction(hir, root);
}

fn executeInstruction(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    return switch (hir.instructionTag(index)) {
        .list => executor.executeList(hir, index),
        .and_if, .or_if => executor.executeAndOr(hir, index),
        .negated_pipeline => executor.executeNegatedPipeline(hir, index),
        .subshell => executor.executeSubshell(hir, index),
        .brace_group => executor.executeBraceGroup(hir, index),
        .if_clause => executor.executeIfClause(hir, index),
        .while_clause, .until_clause => executor.executeLoopClause(hir, index),
        .for_clause => executor.executeForClause(hir, index),
        .function_definition => executor.executeFunctionDefinition(hir, index),
        .simple_command => executor.executeSimpleCommand(hir, index),
        else => error.UnsupportedInstruction,
    };
}

fn executeFunctionDefinition(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const state = executor.runtime_state orelse return error.FunctionStateUnavailable;
    const definition = hir.functionDefinition(index);
    try state.defineFunction(definition.name, hir, definition.body);
    return .{ .status = 0, .sandbox_coverage = .not_requested };
}

fn executeSubshell(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const group = hir.groupedCommand(index);
    var subshell_executor = executor;
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    var scope = switch (try subshell_executor.beginHirRedirections(
        hir,
        group.redirects,
        arena.allocator(),
    )) {
        .ready => |ready| ready,
        .failed => |result| return result,
    };
    defer scope.deinit();
    subshell_executor = scope.executor;
    subshell_executor.loop_depth = 0;
    if (executor.runtime_state) |state| {
        var state_copy = try state.clone();
        defer state_copy.deinit();
        subshell_executor.runtime_state = &state_copy;
        return subshell_executor.executeSubshellBody(hir, group.body);
    }
    if (executor.variables) |variables| {
        var variables_copy = try variables.clone(executor.gpa);
        defer variables_copy.deinit();
        subshell_executor.variables = &variables_copy;
        return subshell_executor.executeSubshellBody(hir, group.body);
    }
    return subshell_executor.executeSubshellBody(hir, group.body);
}

fn executeSubshellBody(executor: Executor, hir: Hir, body: Hir.Inst.Index) Error!Result {
    var result = try executor.executeInstruction(hir, body);
    switch (result.control_flow) {
        .none => {},
        .exit, .@"return" => result.control_flow = .none,
        .@"break", .@"continue" => unreachable,
    }
    return result;
}

fn executeBraceGroup(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const group = hir.groupedCommand(index);
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    var scope = switch (try executor.beginHirRedirections(
        hir,
        group.redirects,
        arena.allocator(),
    )) {
        .ready => |ready| ready,
        .failed => |result| return result,
    };
    defer scope.deinit();
    return scope.executor.executeInstruction(hir, group.body);
}

fn executeForClause(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const clause = hir.forClause(index);
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scope = switch (try executor.beginHirRedirections(hir, clause.redirects, allocator)) {
        .ready => |ready| ready,
        .failed => |result| return result,
    };
    defer scope.deinit();
    const scoped_executor = scope.executor;
    const variables = scoped_executor.variableStore();

    var expanded_words: std.ArrayList([]const u8) = .empty;
    var expansion_failure: Expander.Failure = undefined;
    const values = if (clause.implicit_positional_parameters)
        scoped_executor.positionalParameters()
    else values: {
        const expander = scoped_executor.wordExpander(allocator, null, &expansion_failure);
        for (clause.words) |word| {
            const expanded = expander.expandArgument(hir, word) catch |err| switch (err) {
                error.ParameterExpansionFailed => return scoped_executor.parameterExpansionFailure(
                    allocator,
                    expansion_failure,
                ),
                else => |other| return other,
            };
            try expanded_words.appendSlice(allocator, expanded);
        }
        break :values expanded_words.items;
    };

    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    var last_status = scoped_executor.last_status;
    iteration: for (values) |value| {
        const mutable_variables = variables orelse return error.VariableStateUnavailable;
        mutable_variables.set(clause.name, value) catch |err| switch (err) {
            error.InvalidName => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };

        var body_executor = scoped_executor;
        body_executor.last_status = last_status;
        body_executor.loop_depth += 1;
        const body_result = try body_executor.executeInstruction(hir, clause.body);
        result.status = body_result.status;
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            body_result.sandbox_coverage,
        );
        switch (body_result.control_flow) {
            .none => last_status = body_result.status,
            .exit => {
                result.control_flow = .exit;
                return result;
            },
            .@"return" => {
                result.control_flow = .@"return";
                return result;
            },
            .@"break" => |levels| {
                if (levels > 1) result.control_flow = .{ .@"break" = levels - 1 };
                return result;
            },
            .@"continue" => |levels| {
                if (levels > 1) {
                    result.control_flow = .{ .@"continue" = levels - 1 };
                    return result;
                }
                last_status = body_result.status;
                continue :iteration;
            },
        }
    }
    return result;
}

fn executeList(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    var last_status = executor.last_status;
    for (0..hir.listItemCount(index)) |item_index| {
        const item = hir.listItem(index, item_index);
        if (item.separator == .background) return error.UnsupportedInstruction;
        var command_executor = executor;
        command_executor.last_status = last_status;
        const command_result = try command_executor.executeInstruction(hir, item.command);
        result.status = command_result.status;
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            command_result.sandbox_coverage,
        );
        result.control_flow = command_result.control_flow;
        last_status = command_result.status;
        if (!command_result.control_flow.isNone()) break;
    }
    return result;
}

fn executeLoopClause(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const clause = hir.loopClause(index);
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    var scope = switch (try executor.beginHirRedirections(
        hir,
        clause.redirects,
        arena.allocator(),
    )) {
        .ready => |ready| ready,
        .failed => |result| return result,
    };
    defer scope.deinit();
    const scoped_executor = scope.executor;

    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    var last_status = scoped_executor.last_status;
    loop: while (true) {
        var condition_executor = scoped_executor;
        condition_executor.last_status = last_status;
        condition_executor.loop_depth += 1;
        const condition_result = try condition_executor.executeInstruction(hir, clause.condition);
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            condition_result.sandbox_coverage,
        );
        switch (condition_result.control_flow) {
            .none => {},
            .exit => {
                result.status = condition_result.status;
                result.control_flow = .exit;
                return result;
            },
            .@"return" => {
                result.status = condition_result.status;
                result.control_flow = .@"return";
                return result;
            },
            .@"break" => |levels| {
                result.status = condition_result.status;
                if (levels > 1) result.control_flow = .{ .@"break" = levels - 1 };
                return result;
            },
            .@"continue" => |levels| {
                result.status = condition_result.status;
                if (levels > 1) {
                    result.control_flow = .{ .@"continue" = levels - 1 };
                    return result;
                }
                last_status = condition_result.status;
                continue :loop;
            },
        }

        const execute_body = switch (hir.instructionTag(index)) {
            .while_clause => condition_result.status == 0,
            .until_clause => condition_result.status != 0,
            else => unreachable,
        };
        if (!execute_body) return result;

        var body_executor = scoped_executor;
        body_executor.last_status = condition_result.status;
        body_executor.loop_depth += 1;
        const body_result = try body_executor.executeInstruction(hir, clause.body);
        result.status = body_result.status;
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            body_result.sandbox_coverage,
        );
        switch (body_result.control_flow) {
            .none => last_status = body_result.status,
            .exit => {
                result.control_flow = .exit;
                return result;
            },
            .@"return" => {
                result.control_flow = .@"return";
                return result;
            },
            .@"break" => |levels| {
                if (levels > 1) result.control_flow = .{ .@"break" = levels - 1 };
                return result;
            },
            .@"continue" => |levels| {
                if (levels > 1) {
                    result.control_flow = .{ .@"continue" = levels - 1 };
                    return result;
                }
                last_status = body_result.status;
                continue :loop;
            },
        }
    }
}

fn executeIfClause(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const clause = hir.ifClause(index);
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    var scope = switch (try executor.beginHirRedirections(
        hir,
        clause.redirects,
        arena.allocator(),
    )) {
        .ready => |ready| ready,
        .failed => |result| return result,
    };
    defer scope.deinit();
    const scoped_executor = scope.executor;

    const condition_result = try scoped_executor.executeInstruction(hir, clause.condition);
    if (!condition_result.control_flow.isNone()) return condition_result;

    const branch = if (condition_result.status == 0)
        clause.then_body
    else
        clause.else_body.unwrap() orelse return .{
            .status = 0,
            .sandbox_coverage = condition_result.sandbox_coverage,
        };

    var branch_executor = scoped_executor;
    branch_executor.last_status = condition_result.status;
    var result = try branch_executor.executeInstruction(hir, branch);
    result.sandbox_coverage = combineSandboxCoverage(
        condition_result.sandbox_coverage,
        result.sandbox_coverage,
    );
    return result;
}

fn executeAndOr(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    const operands = hir.andOr(index);
    const lhs_result = try executor.executeInstruction(hir, operands.lhs);
    if (!lhs_result.control_flow.isNone()) return lhs_result;

    const execute_rhs = switch (hir.instructionTag(index)) {
        .and_if => lhs_result.status == 0,
        .or_if => lhs_result.status != 0,
        else => unreachable,
    };
    if (!execute_rhs) return lhs_result;

    var rhs_executor = executor;
    rhs_executor.last_status = lhs_result.status;
    var rhs_result = try rhs_executor.executeInstruction(hir, operands.rhs);
    rhs_result.sandbox_coverage = combineSandboxCoverage(
        lhs_result.sandbox_coverage,
        rhs_result.sandbox_coverage,
    );
    return rhs_result;
}

fn executeNegatedPipeline(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var result = try executor.executeInstruction(hir, hir.negatedPipeline(index));
    if (!result.control_flow.isNone()) return result;
    result.status = if (result.status == 0) 1 else 0;
    return result;
}

fn executeSimpleCommand(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const variables = executor.variableStore();
    var expansion_failure: Expander.Failure = undefined;
    const expander = executor.wordExpander(allocator, null, &expansion_failure);

    var argv: std.ArrayList([]const u8) = .empty;
    var file_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    const parts = hir.simpleCommandParts(index);
    var has_assignments = false;
    var has_redirects = false;
    var has_words = false;
    for (parts) |part| {
        switch (hir.instructionTag(part)) {
            .assignment => has_assignments = true,
            .redirect => {
                has_redirects = true;
                if (try executor.appendRedirectActions(
                    hir,
                    part,
                    allocator,
                    expander,
                    &expansion_failure,
                    &file_actions,
                )) |failure| return failure;
            },
            .word => {
                has_words = true;
                const expanded = expander.expandArgument(hir, part) catch |err| switch (err) {
                    error.ParameterExpansionFailed => return executor.parameterExpansionFailure(
                        allocator,
                        expansion_failure,
                    ),
                    else => |other| return other,
                };
                try argv.appendSlice(allocator, expanded);
            },
            else => return error.UnsupportedInstruction,
        }
    }
    if (argv.items.len == 0) {
        var scope = switch (try executor.beginRedirections(file_actions.items, allocator)) {
            .ready => |ready| ready,
            .failed => |result| return result,
        };
        defer scope.deinit();
        if (!has_assignments) return if (has_words or has_redirects)
            .{ .status = 0, .sandbox_coverage = .not_requested }
        else
            error.UnsupportedInstruction;
        const mutable_variables = variables orelse return error.VariableStateUnavailable;
        for (parts) |part| {
            if (hir.instructionTag(part) != .assignment) continue;
            const assignment = hir.assignment(part);
            const value = expander.expandAssignment(hir, assignment.value) catch |err| switch (err) {
                error.ParameterExpansionFailed => return executor.parameterExpansionFailure(
                    allocator,
                    expansion_failure,
                ),
                else => |other| return other,
            };
            try mutable_variables.set(assignment.name, value);
        }
        return .{ .status = 0, .sandbox_coverage = .not_requested };
    }

    var command_variables = VariableStore.init(allocator);
    defer command_variables.deinit();
    if (has_assignments) {
        for (parts) |part| {
            if (hir.instructionTag(part) != .assignment) continue;
            const assignment = hir.assignment(part);
            const assignment_expander = executor.wordExpander(
                allocator,
                &command_variables,
                &expansion_failure,
            );
            const value = assignment_expander.expandAssignment(hir, assignment.value) catch |err| switch (err) {
                error.ParameterExpansionFailed => return executor.parameterExpansionFailure(
                    allocator,
                    expansion_failure,
                ),
                else => |other| return other,
            };
            try command_variables.set(assignment.name, value);
        }
    }
    const builtin = Builtin.lookup(argv.items[0]);
    if (builtin) |candidate| {
        if (candidate.special) {
            var scope = switch (try executor.beginRedirections(file_actions.items, allocator)) {
                .ready => |ready| ready,
                .failed => |result| return result,
            };
            defer scope.deinit();
            return scope.executor.executeBuiltin(
                candidate,
                argv.items,
                &command_variables,
                has_assignments,
            );
        }
    }
    if (executor.runtime_state) |state| {
        if (state.functionStore().contains(argv.items[0])) {
            if (has_assignments) {
                const mutable_variables = variables orelse unreachable;
                try applyAssignments(mutable_variables, &command_variables);
            }
            var scope = switch (try executor.beginRedirections(file_actions.items, allocator)) {
                .ready => |ready| ready,
                .failed => |result| return result,
            };
            defer scope.deinit();
            return scope.executor.executeFunction(argv.items);
        }
    }
    if (builtin) |candidate| {
        var scope = switch (try executor.beginRedirections(file_actions.items, allocator)) {
            .ready => |ready| ready,
            .failed => |result| return result,
        };
        defer scope.deinit();
        return scope.executor.executeBuiltin(
            candidate,
            argv.items,
            &command_variables,
            has_assignments,
        );
    }

    var process_environment = VariableStore.init(allocator);
    defer process_environment.deinit();
    const environment = try prepareEnvironment(
        allocator,
        variables,
        &command_variables,
        &process_environment,
    );

    const resolver = executor.resolver orelse return error.CommandResolutionUnavailable;
    const executable = (resolver.resolve(allocator, .{
        .name = argv.items[0],
        .search_path = executor.commandSearchPath(),
        .cwd = executor.workingDirectory(),
    }) catch |err| switch (err) {
        error.AccessDenied => return executor.commandFailure(
            argv.items[0],
            .{ .cannot_execute = .access_denied },
        ),
        error.OutOfMemory, error.Unexpected => return err,
    }) orelse return executor.commandFailure(argv.items[0], .command_not_found);

    var effective_file_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    try effective_file_actions.appendSlice(allocator, executor.scoped_file_actions);
    try effective_file_actions.appendSlice(allocator, file_actions.items);
    const spawn_outcome = executor.host.spawn(.{
        .executable = executable,
        .argv = argv.items,
        .environment = environment,
        .cwd = if (executor.workingDirectory()) |cwd| .{ .path = cwd } else .inherit,
        .file_actions = effective_file_actions.items,
        .sandbox = executor.activeSandbox(),
    }) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidArguments, error.Unexpected => return err,
    };
    const spawned = switch (spawn_outcome) {
        .spawned => |spawned| spawned,
        .failed => |failure| return executor.spawnFailure(
            argv.items[0],
            effective_file_actions.items,
            failure,
        ),
    };
    return .{
        .status = try terminationStatus(try executor.host.wait(spawned.process)),
        .sandbox_coverage = spawned.sandbox_coverage,
    };
}

const RedirectionStart = union(enum) {
    ready: RedirectionScope,
    failed: Result,
};

const RedirectionScope = struct {
    executor: Executor,
    resources: []const CommandPlan.Resource,

    fn deinit(scope: *RedirectionScope) void {
        var index = scope.resources.len;
        while (index != 0) {
            index -= 1;
            scope.executor.host.closeResource(scope.resources[index]);
        }
        scope.* = undefined;
    }
};

fn beginHirRedirections(
    executor: Executor,
    hir: Hir,
    redirects: []const Hir.Inst.Index,
    allocator: std.mem.Allocator,
) Error!RedirectionStart {
    var actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    var expansion_failure: Expander.Failure = undefined;
    const expander = executor.wordExpander(allocator, null, &expansion_failure);
    for (redirects) |redirect| {
        if (try executor.appendRedirectActions(
            hir,
            redirect,
            allocator,
            expander,
            &expansion_failure,
            &actions,
        )) |failure| return .{ .failed = failure };
    }
    return executor.beginRedirections(actions.items, allocator);
}

fn appendRedirectActions(
    executor: Executor,
    hir: Hir,
    redirect_index: Hir.Inst.Index,
    allocator: std.mem.Allocator,
    expander: Expander,
    expansion_failure: *Expander.Failure,
    actions: *std.ArrayList(CommandPlan.FileAction),
) Error!?Result {
    const redirect = hir.redirect(redirect_index);
    const paths = expander.expandArgument(hir, redirect.target) catch |err| switch (err) {
        error.ParameterExpansionFailed => return try executor.parameterExpansionFailure(
            allocator,
            expansion_failure.*,
        ),
        else => |other| return other,
    };
    if (paths.len != 1)
        return try executor.redirectFailure(.ambiguous_redirect);

    const target = if (redirect.io_number) |io_number|
        CommandPlan.FileDescriptor.parse(io_number) orelse
            return try executor.redirectFailure(.{ .invalid_file_descriptor = io_number })
    else
        defaultRedirectDescriptor(redirect.operator) orelse
            return error.UnsupportedInstruction;
    switch (redirect.operator) {
        .duplicate_input, .duplicate_output => {
            if (std.mem.eql(u8, paths[0], "-")) {
                try actions.append(allocator, .{ .close = target });
            } else {
                const source = CommandPlan.FileDescriptor.parse(paths[0]) orelse
                    return try executor.redirectFailure(.{
                        .invalid_file_descriptor = paths[0],
                    });
                try actions.append(allocator, .{ .duplicate = .{
                    .source = source,
                    .target = target,
                } });
            }
        },
        .output_both, .append_both => {
            const action = openRedirectAction(
                redirect.operator,
                target,
                paths[0],
            ) orelse return error.UnsupportedInstruction;
            try actions.append(allocator, action);
            try actions.append(allocator, .{ .duplicate = .{
                .source = target,
                .target = .stderr,
            } });
        },
        else => {
            const action = openRedirectAction(
                redirect.operator,
                target,
                paths[0],
            ) orelse return error.UnsupportedInstruction;
            try actions.append(allocator, action);
        },
    }
    return null;
}

fn beginRedirections(
    executor: Executor,
    actions: []const CommandPlan.FileAction,
    allocator: std.mem.Allocator,
) Error!RedirectionStart {
    var scoped_executor = executor;
    var resources: std.ArrayList(CommandPlan.Resource) = .empty;
    var scoped_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    try scoped_actions.appendSlice(allocator, executor.scoped_file_actions);
    var retain_resources = false;
    defer if (!retain_resources) {
        var index = resources.items.len;
        while (index != 0) {
            index -= 1;
            executor.host.closeResource(resources.items[index]);
        }
    };

    for (actions) |action| switch (action) {
        .open => |open| {
            _ = standardStreamIndex(open.target) orelse
                return error.UnsupportedInstruction;
            try resources.ensureUnusedCapacity(allocator, 1);
            try scoped_actions.ensureUnusedCapacity(allocator, 1);
            const outcome = try executor.host.openFile(
                if (executor.workingDirectory()) |cwd| .{ .path = cwd } else .inherit,
                open,
            );
            const resource = switch (outcome) {
                .opened => |resource| resource,
                .failed => |reason| return .{ .failed = try scoped_executor.fileOpenFailure(
                    open.path,
                    reason,
                ) },
            };
            resources.appendAssumeCapacity(resource);
            scoped_actions.appendAssumeCapacity(.{ .use_resource = .{
                .resource = resource,
                .target = open.target,
            } });
            scoped_executor.setRuntimeWriter(
                open.target,
                executor.host.resourceWriter(resource),
            );
        },
        .duplicate => |duplicate| {
            _ = standardStreamIndex(duplicate.source) orelse
                return error.UnsupportedInstruction;
            _ = standardStreamIndex(duplicate.target) orelse
                return error.UnsupportedInstruction;
            const writer = scoped_executor.runtimeWriter(duplicate.source);
            scoped_executor.setRuntimeWriter(duplicate.target, writer);
            try scoped_actions.append(allocator, action);
        },
        .close => |descriptor| {
            _ = standardStreamIndex(descriptor) orelse
                return error.UnsupportedInstruction;
            scoped_executor.setRuntimeWriter(descriptor, null);
            try scoped_actions.append(allocator, action);
        },
        .use_resource => return error.UnsupportedInstruction,
    };

    scoped_executor.scoped_file_actions = scoped_actions.items;
    retain_resources = true;
    return .{ .ready = .{
        .executor = scoped_executor,
        .resources = resources.items,
    } };
}

fn runtimeWriter(executor: Executor, descriptor: CommandPlan.FileDescriptor) ?*std.Io.Writer {
    return switch (descriptor) {
        .stdout => executor.io.stdout,
        .stderr => executor.io.stderr,
        else => null,
    };
}

fn setRuntimeWriter(
    executor: *Executor,
    descriptor: CommandPlan.FileDescriptor,
    writer: ?*std.Io.Writer,
) void {
    switch (descriptor) {
        .stdout => executor.io.stdout = writer,
        .stderr => executor.io.stderr = writer,
        else => {},
    }
}

fn standardStreamIndex(descriptor: CommandPlan.FileDescriptor) ?usize {
    return switch (descriptor) {
        .stdin => 0,
        .stdout => 1,
        .stderr => 2,
        else => null,
    };
}

fn defaultRedirectDescriptor(operator: Hir.Redirect.Operator) ?CommandPlan.FileDescriptor {
    return switch (operator) {
        .input, .duplicate_input, .input_output => .stdin,
        .output,
        .append,
        .duplicate_output,
        .clobber,
        .output_both,
        .append_both,
        => .stdout,
        else => null,
    };
}

fn openRedirectAction(
    operator: Hir.Redirect.Operator,
    target: CommandPlan.FileDescriptor,
    path: []const u8,
) ?CommandPlan.FileAction {
    const open: CommandPlan.FileAction.Open = switch (operator) {
        .input => .{
            .path = path,
            .target = target,
            .access = .read,
            .disposition = .open_existing,
        },
        .output => .{
            .path = path,
            .target = target,
            .access = .write,
            .disposition = .create_or_truncate,
        },
        .append => .{
            .path = path,
            .target = target,
            .access = .write,
            .disposition = .create_or_append,
        },
        .input_output => .{
            .path = path,
            .target = target,
            .access = .read_write,
            .disposition = .create_or_open,
        },
        .clobber, .output_both => .{
            .path = path,
            .target = target,
            .access = .write,
            .disposition = .create_or_truncate,
        },
        .append_both => .{
            .path = path,
            .target = target,
            .access = .write,
            .disposition = .create_or_append,
        },
        else => return null,
    };
    return .{ .open = open };
}

fn executeBuiltin(
    executor: Executor,
    builtin: Builtin,
    argv: []const []const u8,
    command_variables: *const VariableStore,
    has_assignments: bool,
) Error!Result {
    if (builtin.special and has_assignments) {
        const mutable_variables = executor.variableStore() orelse
            return error.VariableStateUnavailable;
        try applyAssignments(mutable_variables, command_variables);
    }
    const result = try builtin.run(.{
        .host = executor.host,
        .runtime_state = executor.runtime_state,
        .variable_overrides = command_variables,
        .io = executor.io,
        .last_status = executor.last_status,
        .loop_depth = executor.loop_depth,
        .function_depth = executor.function_depth,
    }, argv);
    return .{
        .status = result.status,
        .sandbox_coverage = .not_requested,
        .control_flow = result.control_flow,
    };
}

fn executeFunction(executor: Executor, argv: []const []const u8) Error!Result {
    if (executor.function_depth == max_function_depth)
        return executor.commandFailure(argv[0], .function_call_depth_exceeded);

    const state = executor.runtime_state orelse return error.FunctionStateUnavailable;
    var definition = (try state.cloneFunction(argv[0], executor.gpa)) orelse unreachable;
    defer definition.deinit(executor.gpa);

    var function_executor = executor;
    function_executor.positional_parameters_override = argv[1..];
    function_executor.loop_depth = 0;
    function_executor.function_depth += 1;
    var result = try function_executor.executeInstruction(definition.hir, definition.body);
    if (result.control_flow == .@"return") result.control_flow = .none;
    return result;
}

fn variableStore(executor: Executor) ?*VariableStore {
    if (executor.runtime_state) |state| return state.variableStore();
    return executor.variables;
}

fn wordExpander(
    executor: Executor,
    allocator: std.mem.Allocator,
    overrides: ?*const VariableStore,
    failure: *Expander.Failure,
) Expander {
    return Expander.initWithContext(allocator, .{
        .variables = executor.variableStore(),
        .overrides = overrides,
        .positional_parameters = executor.positionalParameters(),
        .invocation_name = executor.invocationName(),
        .shell_process_id = executor.shellProcessId(),
        .last_status = executor.last_status,
        .failure = failure,
    });
}

fn parameterExpansionFailure(
    executor: Executor,
    allocator: std.mem.Allocator,
    failure: Expander.Failure,
) std.Io.Writer.Error!Result {
    defer failure.deinit(allocator);
    const diagnostic: runtime.Diagnostic = .{
        .subject = .shell,
        .kind = .{ .parameter_expansion = .{
            .parameter = failure.parameter,
            .message = failure.message,
        } },
    };
    try executor.io.reportDiagnostic(diagnostic);
    return .{
        .status = diagnostic.status(),
        .sandbox_coverage = .not_requested,
    };
}

fn workingDirectory(executor: Executor) ?[]const u8 {
    if (executor.runtime_state) |state| return state.workingDirectory();
    return executor.cwd;
}

fn invocationName(executor: Executor) []const u8 {
    if (executor.runtime_state) |state| return state.invocationName();
    return executor.invocation_name;
}

fn shellProcessId(executor: Executor) ?runtime.ProcessId {
    if (executor.runtime_state) |state| return state.shellProcessId();
    return executor.shell_process_id;
}

fn commandSearchPath(executor: Executor) []const []const u8 {
    if (executor.runtime_state) |state| return state.commandSearchPath();
    return executor.search_path;
}

fn positionalParameters(executor: Executor) []const []const u8 {
    if (executor.positional_parameters_override) |parameters| return parameters;
    if (executor.runtime_state) |state| return state.positionalParameters();
    return executor.positional_parameters;
}

fn activeSandbox(executor: Executor) CommandPlan.Sandbox {
    if (executor.runtime_state) |state| return state.activeSandbox();
    return executor.sandbox;
}

fn commandFailure(
    executor: Executor,
    command: []const u8,
    kind: runtime.Diagnostic.Kind,
) std.Io.Writer.Error!Result {
    const diagnostic: runtime.Diagnostic = .{
        .subject = .{ .command = command },
        .kind = kind,
    };
    try executor.io.reportDiagnostic(diagnostic);
    return .{
        .status = diagnostic.status(),
        .sandbox_coverage = .not_requested,
    };
}

fn redirectFailure(
    executor: Executor,
    kind: runtime.Diagnostic.Kind,
) std.Io.Writer.Error!Result {
    const diagnostic: runtime.Diagnostic = .{
        .subject = .shell,
        .kind = kind,
    };
    try executor.io.reportDiagnostic(diagnostic);
    return .{
        .status = diagnostic.status(),
        .sandbox_coverage = .not_requested,
    };
}

fn spawnFailure(
    executor: Executor,
    command: []const u8,
    file_actions: []const CommandPlan.FileAction,
    failure: Host.SpawnFailure,
) Error!Result {
    return switch (failure) {
        .command_not_found => executor.commandFailure(command, .command_not_found),
        .access_denied => executor.commandFailure(
            command,
            .{ .cannot_execute = .access_denied },
        ),
        .invalid_executable => executor.commandFailure(
            command,
            .{ .cannot_execute = .invalid_executable },
        ),
        .resource_unavailable => executor.commandFailure(
            command,
            .{ .cannot_execute = .resource_unavailable },
        ),
        .sandbox_unavailable => executor.commandFailure(
            command,
            .{ .cannot_execute = .sandbox_unavailable },
        ),
        .unsupported => executor.commandFailure(
            command,
            .{ .cannot_execute = .unsupported },
        ),
        .file_action => |file_action| {
            const action_index = std.math.cast(usize, file_action.action_index) orelse
                return error.Unexpected;
            if (action_index >= file_actions.len) return error.Unexpected;
            const path = switch (file_actions[action_index]) {
                .open => |open| open.path,
                else => return error.Unexpected,
            };
            return executor.fileOpenFailure(path, file_action.reason);
        },
    };
}

fn fileOpenFailure(
    executor: Executor,
    path: []const u8,
    reason: Host.FileActionFailure.Reason,
) std.Io.Writer.Error!Result {
    const diagnostic: runtime.Diagnostic = .{
        .subject = .{ .path = path },
        .kind = .{ .cannot_open = switch (reason) {
            .not_found => .not_found,
            .access_denied => .access_denied,
            .invalid_path => .invalid_path,
            .path_already_exists => .path_already_exists,
            .resource_unavailable => .resource_unavailable,
            .unsupported => .unsupported,
        } },
    };
    try executor.io.reportDiagnostic(diagnostic);
    return .{
        .status = diagnostic.status(),
        .sandbox_coverage = .not_requested,
    };
}

fn applyAssignments(
    variables: *VariableStore,
    assignments: *const VariableStore,
) VariableStore.Error!void {
    var iterator = assignments.iterator();
    while (iterator.next()) |binding|
        try variables.set(binding.name, binding.value);
}

fn environmentVariables(
    allocator: std.mem.Allocator,
    variables: *const VariableStore,
) std.mem.Allocator.Error![]const CommandPlan.EnvironmentVariable {
    const result = try allocator.alloc(CommandPlan.EnvironmentVariable, variables.count());
    var iterator = variables.iterator();
    var index: usize = 0;
    while (iterator.next()) |binding| : (index += 1) {
        result[index] = .{ .name = binding.name, .value = binding.value };
    }
    return result;
}

fn prepareEnvironment(
    allocator: std.mem.Allocator,
    session_variables: ?*const VariableStore,
    command_variables: *const VariableStore,
    process_environment: *VariableStore,
) VariableStore.Error!CommandPlan.Environment {
    if (session_variables == null and command_variables.count() == 0) return .inherit;
    if (session_variables) |variables| {
        var iterator = variables.iterator();
        while (iterator.next()) |binding| {
            if (binding.exported)
                try process_environment.set(binding.name, binding.value);
        }
    }
    var command_iterator = command_variables.iterator();
    while (command_iterator.next()) |binding|
        try process_environment.set(binding.name, binding.value);

    const variables = try environmentVariables(allocator, process_environment);
    return if (session_variables != null)
        .{ .replace = variables }
    else
        .{ .overlay = variables };
}

fn combineSandboxCoverage(
    lhs: SandboxPolicy.Coverage,
    rhs: SandboxPolicy.Coverage,
) SandboxPolicy.Coverage {
    if (lhs == .partial or rhs == .partial) return .partial;
    if (lhs == .complete or rhs == .complete) return .complete;
    return .not_requested;
}

fn terminationStatus(termination: Host.Termination) Error!u8 {
    return switch (termination) {
        .exited => |status| status,
        .signal => |signal| status: {
            const capped_signal: u32 = @min(signal, 127);
            const status: u32 = 128 + capped_signal;
            break :status @intCast(status);
        },
        .stopped, .unknown => error.UnexpectedTermination,
    };
}

test {
    _ = @import("executor_test.zig");
    std.testing.refAllDecls(@This());
}
