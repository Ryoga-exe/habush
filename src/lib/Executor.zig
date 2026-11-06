//! Executes Habush HIR through a `Host`.
//!
//! The current runtime foundation executes empty units, foreground sequential
//! lists, and-or commands, pipeline negation, brace groups, if clauses,
//! while/until/for loops with break/continue control, standalone assignments,
//! builtins, external simple commands, and foreground pipelines of external
//! simple commands, builtins, and in-process stages such as `read`, shell
//! functions, and compound commands. Standard-stream redirections support
//! simple and compound commands, including here-documents and here-strings.
//! Multiple in-process pipeline stages require the opt-in concurrent runtime.

const std = @import("std");
const Builtin = @import("Builtin.zig");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const ConcurrentWriter = @import("concurrent/Writer.zig");
const Executor = @This();
const ExecutionContext = @import("ExecutionContext.zig");
const Expander = @import("Expander.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const Pipeline = @import("Pipeline.zig");
const runtime = @import("runtime.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const VariableStore = @import("VariableStore.zig");

gpa: std.mem.Allocator,
host: Host,
context: ExecutionContext.Ref,
resolver: ?CommandResolver,
default_search_path: []const []const u8,
invocation_name: []const u8,
shell_process_id: ?runtime.ProcessId,
positional_parameters: []const []const u8,
positional_parameters_override: ?*[]const []const u8,
variables: ?*VariableStore,
runtime_state: ?*runtime.State,
io: runtime.Io,
scoped_file_actions: []const CommandPlan.FileAction,
pipeline_stage: ?PipelineStage,
prepared_simple: ?PreparedSimpleCommand,
last_status: runtime.ExitStatus,
jobs: ?*runtime.Jobs = null,
background: bool = false,
job_control: bool = false,
concurrent_pipeline: ?ConcurrentPipeline = null,
cancel_io: ?std.Io = null,
diagnostic_locations: bool = true,
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
    Canceled,
};

/// Opt-in scheduling resources for multiple in-process pipeline stages.
/// `allocator` must be safe for concurrent use. The Host and resolver must
/// also be shared through synchronization adapters for this execution.
pub const ConcurrentPipeline = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub const Options = struct {
    context: ExecutionContext.View = .{},
    concurrent_pipeline: ?ConcurrentPipeline = null,
    resolver: ?CommandResolver = null,
    /// Used only when neither the command bindings nor shell variables set PATH.
    default_search_path: []const []const u8 = &.{},
    invocation_name: []const u8 = "habush",
    shell_process_id: ?runtime.ProcessId = null,
    positional_parameters: []const []const u8 = &.{},
    /// Complete shell variable state. When present, exported bindings become
    /// an exact replacement environment; `null` preserves host inheritance.
    variables: ?*VariableStore = null,
    /// Status visible to a command such as `exit` when no operand is given.
    last_status: runtime.ExitStatus = 0,
};

/// The shell-visible outcome of a completed HIR unit.
pub const Result = struct {
    status: runtime.ExitStatus,
    sandbox_coverage: SandboxPolicy.Coverage,
    control_flow: runtime.ControlFlow = .none,
};

const PipelineStage = struct {
    input: ?CommandPlan.Resource,
    output: ?CommandPlan.Resource,
    pipe_stderr: bool,
    pipeline: *Pipeline,
    index: usize,
};

const PipelineStageKind = enum {
    external,
    builtin,
    in_process,
};

const CommandSelection = union(enum) {
    external,
    builtin: Builtin,
    function,

    fn pipelineStageKind(command: CommandSelection) PipelineStageKind {
        return switch (command) {
            .external => .external,
            .builtin => |builtin| if (builtin.pipeline_support == .reads_stdin) .in_process else .builtin,
            .function => .in_process,
        };
    }
};

const PreparedSimpleCommand = struct {
    argv: []const []const u8,
    command: CommandSelection,
};

const PipelineStagePlan = union(enum) {
    simple: PreparedSimpleCommand,
    definition,
    compound,

    fn kind(plan: PipelineStagePlan) PipelineStageKind {
        return switch (plan) {
            .simple => |simple| simple.command.pipelineStageKind(),
            .definition => .builtin,
            .compound => .in_process,
        };
    }
};

const PipelineStagePreparation = union(enum) {
    ready: PipelineStagePlan,
    failed: Result,
};

const PreparedPipelineStage = struct {
    index: Hir.Inst.Index,
    plan: ?PipelineStagePlan = null,
    arena: ?std.heap.ArenaAllocator = null,
    stdout_writer: ?ConcurrentWriter = null,
    stderr_writer: ?ConcurrentWriter = null,
    state: ?runtime.State = null,
    variables: ?VariableStore = null,
    context: ?ExecutionContext = null,
    jobs: ?runtime.Jobs = null,
    positional_parameters: []const []const u8 = &.{},

    fn finishJobs(stage: *PreparedPipelineStage, cancel_io: ?std.Io) void {
        const jobs = if (stage.jobs) |*owned| owned else return;
        const previous_protection = if (cancel_io) |io|
            io.swapCancelProtection(.blocked)
        else
            null;
        defer {
            if (previous_protection) |previous|
                _ = cancel_io.?.swapCancelProtection(previous);
        }
        jobs.cancelAll();
        jobs.deinit();
        stage.jobs = null;
    }

    fn deinit(stage: *PreparedPipelineStage) void {
        stage.finishJobs(null);
        if (stage.state) |*state| state.deinit();
        if (stage.variables) |*variables| variables.deinit();
        if (stage.context) |*context| context.deinit();
        if (stage.arena) |*arena| arena.deinit();
    }

    fn executor(stage: *PreparedPipelineStage, base: Executor) Executor {
        var result = base;
        if (stage.arena) |*arena| result.gpa = arena.allocator();
        if (stage.state) |*state| result.runtime_state = state;
        if (stage.variables) |*variables| result.variables = variables;
        if (stage.context) |*context| {
            result.context = .{ .mutable = context };
            result.io = context.io;
        }
        result.jobs = if (stage.jobs) |*jobs| jobs else null;
        result.positional_parameters_override = &stage.positional_parameters;
        result.prepared_simple = if (stage.plan) |plan| switch (plan) {
            .simple => |simple| simple,
            .definition, .compound => null,
        } else null;
        return result;
    }

    fn allocator(stage: *PreparedPipelineStage, fallback: std.mem.Allocator) std.mem.Allocator {
        if (stage.arena) |*arena| return arena.allocator();
        return fallback;
    }
};

pub fn init(gpa: std.mem.Allocator, host: Host) Executor {
    return initWithOptions(gpa, host, .{});
}

pub fn initWithOptions(gpa: std.mem.Allocator, host: Host, options: Options) Executor {
    return .{
        .gpa = gpa,
        .host = host,
        .context = .{ .view = options.context },
        .resolver = options.resolver,
        .default_search_path = options.default_search_path,
        .invocation_name = options.invocation_name,
        .shell_process_id = options.shell_process_id,
        .positional_parameters = options.positional_parameters,
        .positional_parameters_override = null,
        .variables = options.variables,
        .runtime_state = null,
        .concurrent_pipeline = options.concurrent_pipeline,
        .io = options.context.io,
        .scoped_file_actions = &.{},
        .pipeline_stage = null,
        .prepared_simple = null,
        .last_status = options.last_status,
        .loop_depth = 0,
        .function_depth = 0,
    };
}

pub fn initWithState(
    host: Host,
    resolver: ?CommandResolver,
    state: *runtime.State,
    context: *ExecutionContext,
    last_status: runtime.ExitStatus,
) Executor {
    return .{
        .gpa = state.allocator(),
        .host = host,
        .context = .{ .mutable = context },
        .resolver = resolver,
        .default_search_path = &.{},
        .invocation_name = "",
        .shell_process_id = null,
        .positional_parameters = &.{},
        .positional_parameters_override = null,
        .variables = null,
        .runtime_state = state,
        .io = context.io,
        .scoped_file_actions = &.{},
        .pipeline_stage = null,
        .prepared_simple = null,
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

fn executeInstruction(parent: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var executor = parent;
    executor.io.diagnostic_source = if (executor.diagnostic_locations and hir.instructionTag(index) == .simple_command) blk: {
        for (hir.simpleCommandParts(index)) |part| {
            if (hir.instructionTag(part) == .word)
                break :blk .{ .start = hir.instructionData(part).pl.src_start };
        }
        break :blk .{ .start = hir.instructionData(index).pl.src_start };
    } else null;
    if (executor.cancel_io) |io| try io.checkCancel();
    if (executor.background) {
        if (executor.jobs == null) return error.UnsupportedInstruction;
        switch (hir.instructionTag(index)) {
            .simple_command, .pipe, .pipe_and => {},
            else => return error.UnsupportedInstruction,
        }
    }
    return switch (hir.instructionTag(index)) {
        .list => executor.executeList(hir, index),
        .and_if, .or_if => executor.executeAndOr(hir, index),
        .pipe, .pipe_and => executor.executePipeline(hir, index),
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
    var positional_parameters = executor.positionalParameters();
    subshell_executor.positional_parameters_override = &positional_parameters;
    var jobs: runtime.Jobs = .{ .gpa = executor.gpa };
    defer jobs.deinit();
    defer jobs.cancelAll();
    subshell_executor.jobs = &jobs;
    var context_copy = try executor.context.clone(executor.gpa);
    defer context_copy.deinit();
    subshell_executor.context = .{ .mutable = &context_copy };
    var state_copy = if (executor.runtime_state) |state| try state.clone() else null;
    defer if (state_copy) |*state| state.deinit();
    if (state_copy) |*state| subshell_executor.runtime_state = state;
    var variables_copy = if (executor.variables) |variables|
        try variables.clone(executor.gpa)
    else
        null;
    defer if (variables_copy) |*variables| variables.deinit();
    if (variables_copy) |*variables| subshell_executor.variables = variables;
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
    const values = if (clause.implicit_positional_parameters) values: {
        const parameters = scoped_executor.positionalParameters();
        const copy = try allocator.alloc([]const u8, parameters.len);
        for (parameters, copy) |parameter, *destination|
            destination.* = try allocator.dupe(u8, parameter);
        break :values copy;
    } else values: {
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
        var command_executor = executor;
        command_executor.last_status = last_status;
        command_executor.background = item.separator == .background;
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

fn executePipeline(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stages: std.ArrayList(Hir.Inst.Index) = .empty;
    var pipe_stderr: std.ArrayList(bool) = .empty;
    try collectPipeline(hir, index, allocator, &stages, &pipe_stderr);
    std.debug.assert(stages.items.len == pipe_stderr.items.len + 1);

    const prepared = try allocator.alloc(PreparedPipelineStage, stages.items.len);
    for (prepared, stages.items) |*stage, stage_index| stage.* = .{ .index = stage_index };
    for (prepared) |*stage| stage.positional_parameters = executor.positionalParameters();
    var prepared_owned = true;
    defer if (prepared_owned) for (prepared) |*stage| stage.deinit();
    var writer_mutex: std.Io.Mutex = .init;
    var in_process_count: usize = 0;
    var non_external_count: usize = 0;
    var upstream_builtin = false;
    for (prepared) |*stage| {
        if (executor.concurrent_pipeline) |config|
            stage.arena = std.heap.ArenaAllocator.init(config.allocator);
        const stage_allocator = stage.allocator(executor.gpa);
        stage.jobs = .{ .gpa = stage_allocator };
        stage.context = try executor.context.clone(stage_allocator);
        // A surrounding compound redirection changes the current executor's
        // streams without replacing the session's context. Stage snapshots
        // must inherit those effective streams.
        stage.context.?.io = executor.io;
        if (executor.concurrent_pipeline) |config| {
            if (stage.context.?.io.stdout) |stdout| {
                stage.stdout_writer = ConcurrentWriter.init(stdout, &writer_mutex, config.io);
                stage.context.?.io.stdout = &stage.stdout_writer.?.interface;
            }
            if (stage.context.?.io.stderr) |stderr| {
                stage.stderr_writer = ConcurrentWriter.init(stderr, &writer_mutex, config.io);
                stage.context.?.io.stderr = &stage.stderr_writer.?.interface;
            }
        }
        if (executor.runtime_state) |state|
            stage.state = try state.cloneWithAllocator(stage_allocator);
        if (executor.variables) |variables|
            stage.variables = try variables.clone(stage_allocator);
        const stage_executor = stage.executor(executor);
        const plan = switch (try stage_executor.preparePipelineStage(hir, stage.index, allocator)) {
            .ready => |value| value,
            .failed => |result| return result,
        };
        stage.plan = plan;
        if (plan.kind() == .in_process) in_process_count += 1;
        if (plan.kind() != .external) non_external_count += 1;
        if (plan.kind() == .in_process and upstream_builtin and executor.concurrent_pipeline == null)
            return error.UnsupportedInstruction;
        if (plan.kind() == .builtin) upstream_builtin = true;
        if (executor.background and plan.kind() != .external) return error.UnsupportedInstruction;
    }
    // A general in-process stage may read from its pipeline input. External
    // neighbours are launched first so one such stage can run synchronously;
    // two such stages require a concurrent runtime scheduler.
    if (in_process_count > 1 and executor.concurrent_pipeline == null)
        return error.UnsupportedInstruction;

    var pipeline = Pipeline.init(executor.gpa, executor.host, stages.items.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceUnavailable => return executor.pipelineFailure(.resource_unavailable),
        error.Unsupported => return executor.pipelineFailure(.unsupported),
        else => |other| return other,
    };
    var transferred = false;
    defer {
        // This pipeline can itself be a stage of a canceled outer pipeline.
        // Its children and stage-local jobs must still be killed and reaped.
        const previous_protection = if (executor.cancel_io) |io|
            io.swapCancelProtection(.blocked)
        else
            null;
        defer {
            if (previous_protection) |previous|
                _ = executor.cancel_io.?.swapCancelProtection(previous);
        }
        // Stage-local jobs can inherit an outer pipe end. Terminate them
        // before waiting for the outer pipeline to drain.
        for (prepared) |*stage| stage.deinit();
        prepared_owned = false;
        if (!transferred) pipeline.deinit();
    }
    const foreground_job = !executor.background and in_process_count == 0 and !upstream_builtin and
        executor.jobs != null and executor.jobs.?.terminal_control;
    pipeline.create_group = (executor.background or foreground_job) and executor.host.capabilities().process_groups;

    if (executor.concurrent_pipeline) |config| {
        if (non_external_count > 1) return executor.executeConcurrentPipeline(
            hir,
            prepared,
            pipe_stderr.items,
            &pipeline,
            config,
        );
    }

    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    const phase_count: usize = if (in_process_count == 0) 1 else 2;
    for (0..phase_count) |phase| {
        var remaining_stages = stages.items.len;
        while (remaining_stages != 0) {
            remaining_stages -= 1;
            const stage_index = remaining_stages;
            const kind = prepared[stage_index].plan.?.kind();
            if (phase_count != 1) {
                if (phase == 0 and kind != .external) continue;
                if (phase == 1 and kind == .external) continue;
            }

            var stage_executor = prepared[stage_index].executor(executor);
            const connections = pipeline.stage(stage_index);
            stage_executor.pipeline_stage = .{
                .input = connections.input,
                .output = connections.output,
                .pipe_stderr = stage_index < pipe_stderr.items.len and
                    pipe_stderr.items[stage_index],
                .pipeline = &pipeline,
                .index = stage_index,
            };
            const executed = stage_executor.executeInstruction(hir, prepared[stage_index].index);
            prepared[stage_index].finishJobs(stage_executor.cancel_io);
            var stage_result = executed catch |err| switch (err) {
                // A non-final in-process stage observes a closed pipeline as a
                // command failure, not as an executor infrastructure failure.
                error.WriteFailed => if (stage_index + 1 == stages.items.len)
                    return err
                else
                    Result{ .status = 1, .sandbox_coverage = .not_requested },
                else => |other| return other,
            };
            // A pipeline stage is an isolated shell environment. Its control
            // flow contributes a status but cannot leave the pipeline.
            stage_result.control_flow = .none;
            if (stage_index + 1 == stages.items.len) result.status = stage_result.status;
            result.sandbox_coverage = combineSandboxCoverage(
                result.sandbox_coverage,
                stage_result.sandbox_coverage,
            );
            pipeline.closeStage(stage_index);
            if (executor.background and pipeline.status(stage_index) == .pending) {
                pipeline.signal(.kill) catch {};
                return stage_result;
            }
        }
    }

    if (executor.background or foreground_job) {
        const jobs = executor.jobs orelse return error.UnsupportedInstruction;
        const id = jobs.add(pipeline, "pipeline", .{ .background = executor.background }) catch |err| {
            pipeline.signal(.kill) catch {};
            return err;
        };
        transferred = true;
        result.status = if (executor.background) 0 else (try jobs.foreground(id)).?;
        return result;
    }

    for (0..stages.items.len) |stage_index| {
        if (try pipeline.wait(stage_index)) |termination| {
            const status = try terminationStatus(termination);
            if (stage_index + 1 == stages.items.len) result.status = status;
        }
    }
    return result;
}

const ConcurrentStageTask = struct {
    index: usize,
    base: Executor,
    hir: Hir,
    stage: *PreparedPipelineStage,
    pipeline: *Pipeline,
    pipe_stderr: bool,
    gate: *std.Io.Event,
    abort: *std.atomic.Value(bool),
    completions: *std.Io.Queue(usize),
    io: std.Io,
    outcome: ?Error!Result = null,

    fn run(task: *ConcurrentStageTask) std.Io.Cancelable!void {
        task.gate.waitUncancelable(task.io);
        if (task.abort.load(.acquire)) return;

        const stage_index = task.index;
        var stage_executor = task.stage.executor(task.base);
        const connections = task.pipeline.stage(stage_index);
        stage_executor.pipeline_stage = .{
            .input = connections.input,
            .output = connections.output,
            .pipe_stderr = task.pipe_stderr,
            .pipeline = task.pipeline,
            .index = stage_index,
        };
        stage_executor.cancel_io = task.io;
        const executed = stage_executor.executeInstruction(task.hir, task.stage.index);
        task.stage.finishJobs(task.io);
        if (executed) |completed| {
            var result = completed;
            result.control_flow = .none;
            task.outcome = result;
        } else |err| {
            task.outcome = if (err == error.WriteFailed and stage_index + 1 < task.pipeline.stageCount())
                Result{ .status = 1, .sandbox_coverage = .not_requested }
            else
                err;
        }
        // The owning stage closes its ends before publishing completion. The
        // coordinator never frees a live task's borrowed resource reader.
        task.pipeline.closeStage(stage_index);
        task.completions.putOneUncancelable(task.io, stage_index) catch unreachable;
    }
};

fn executeConcurrentPipeline(
    executor: Executor,
    hir: Hir,
    prepared: []PreparedPipelineStage,
    pipe_stderr: []const bool,
    pipeline: *Pipeline,
    config: ConcurrentPipeline,
) Error!Result {
    var task_count: usize = 0;
    var requires_signals = false;
    for (prepared) |stage| {
        if (stage.plan.?.kind() != .external) task_count += 1;
        switch (stage.plan.?) {
            .simple => |simple| switch (simple.command) {
                .external, .function => requires_signals = true,
                .builtin => {},
            },
            .compound => requires_signals = true,
            .definition => {},
        }
    }
    if (requires_signals and !executor.host.capabilities().signals)
        return error.UnsupportedInstruction;

    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const task_slots = try allocator.alloc(ConcurrentStageTask, task_count);
    const completion_buffer = try allocator.alloc(usize, task_count);
    var completions = std.Io.Queue(usize).init(completion_buffer);
    const results = try allocator.alloc(?Result, prepared.len);
    @memset(results, null);
    var gate: std.Io.Event = .unset;
    var abort: std.atomic.Value(bool) = .init(false);
    var group: std.Io.Group = .init;
    var joined = false;
    var gate_open = false;
    defer if (!joined) {
        if (!gate_open) {
            abort.store(true, .release);
            gate.set(config.io);
        }
        pipeline.signal(.kill) catch {};
        group.cancel(config.io);
    };

    var next_task: usize = 0;
    for (prepared, 0..) |*stage, stage_index| {
        if (stage.plan.?.kind() == .external) continue;
        task_slots[next_task] = .{
            .index = stage_index,
            .base = executor,
            .hir = hir,
            .stage = stage,
            .pipeline = pipeline,
            .pipe_stderr = stage_index < pipe_stderr.len and pipe_stderr[stage_index],
            .gate = &gate,
            .abort = &abort,
            .completions = &completions,
            .io = config.io,
        };
        group.concurrent(config.io, ConcurrentStageTask.run, .{&task_slots[next_task]}) catch
            return error.UnsupportedInstruction;
        next_task += 1;
    }

    // Workers are gated, so all external stages can be spawned without a
    // concurrent Host operation or an in-process consumer observing partial
    // pipeline setup.
    var remaining = prepared.len;
    while (remaining != 0) {
        remaining -= 1;
        if (prepared[remaining].plan.?.kind() != .external) continue;
        var stage_executor = prepared[remaining].executor(executor);
        const connections = pipeline.stage(remaining);
        stage_executor.pipeline_stage = .{
            .input = connections.input,
            .output = connections.output,
            .pipe_stderr = remaining < pipe_stderr.len and pipe_stderr[remaining],
            .pipeline = pipeline,
            .index = remaining,
        };
        var stage_result = try stage_executor.executeInstruction(hir, prepared[remaining].index);
        stage_result.control_flow = .none;
        results[remaining] = stage_result;
        pipeline.closeStage(remaining);
    }

    gate.set(config.io);
    gate_open = true;
    for (0..task_count) |_| {
        const stage_index = completions.getOne(config.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable,
        };
        const task = for (task_slots) |*candidate| {
            if (candidate.index == stage_index) break candidate;
        } else unreachable;
        if (task.outcome.?) |stage_result| {
            results[stage_index] = stage_result;
        } else |err| {
            return err;
        }
    }
    try group.await(config.io);
    joined = true;

    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    for (prepared, 0..) |_, stage_index| {
        const stage_result = results[stage_index].?;
        if (stage_index + 1 == prepared.len) result.status = stage_result.status;
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            stage_result.sandbox_coverage,
        );
    }
    for (prepared, 0..) |_, stage_index| {
        const termination = pipeline.wait(stage_index) catch |err| {
            pipeline.signal(.kill) catch {};
            return err;
        };
        if (termination) |value| {
            if (stage_index + 1 == prepared.len)
                result.status = try terminationStatus(value);
        }
    }
    return result;
}

fn preparePipelineStage(
    executor: Executor,
    hir: Hir,
    index: Hir.Inst.Index,
    allocator: std.mem.Allocator,
) Error!PipelineStagePreparation {
    if (hir.instructionTag(index) != .simple_command) return switch (hir.instructionTag(index)) {
        .subshell,
        .brace_group,
        .if_clause,
        .while_clause,
        .until_clause,
        .for_clause,
        => .{ .ready = .compound },
        .function_definition => .{ .ready = .definition },
        else => error.UnsupportedInstruction,
    };

    var expansion_failure: Expander.Failure = undefined;
    const expander = executor.wordExpander(allocator, null, &expansion_failure);
    var argv: std.ArrayList([]const u8) = .empty;
    for (hir.simpleCommandParts(index)) |part| switch (hir.instructionTag(part)) {
        .assignment, .redirect => {},
        .word => {
            const expanded = expander.expandArgument(hir, part) catch |err| switch (err) {
                error.ParameterExpansionFailed => return .{ .failed = try executor.parameterExpansionFailure(
                    allocator,
                    expansion_failure,
                ) },
                else => |other| return other,
            };
            try argv.appendSlice(allocator, expanded);
        },
        else => return error.UnsupportedInstruction,
    };
    if (argv.items.len == 0) return error.UnsupportedInstruction;
    const expanded_argv = try argv.toOwnedSlice(allocator);
    const command = executor.resolveCommand(expanded_argv[0]);
    return .{ .ready = .{ .simple = .{ .argv = expanded_argv, .command = command } } };
}

fn resolveCommand(executor: Executor, name: []const u8) CommandSelection {
    const builtin = Builtin.lookup(name);
    if (builtin) |candidate| if (candidate.special) return .{ .builtin = candidate };
    if (executor.runtime_state) |state|
        if (state.functionStore().contains(name)) return .function;
    if (builtin) |candidate| return .{ .builtin = candidate };
    return .external;
}

fn collectPipeline(
    hir: Hir,
    index: Hir.Inst.Index,
    allocator: std.mem.Allocator,
    stages: *std.ArrayList(Hir.Inst.Index),
    pipe_stderr: *std.ArrayList(bool),
) std.mem.Allocator.Error!void {
    return switch (hir.instructionTag(index)) {
        .pipe, .pipe_and => {
            const operands = hir.pipeline(index);
            try collectPipeline(hir, operands.lhs, allocator, stages, pipe_stderr);
            try pipe_stderr.append(allocator, hir.instructionTag(index) == .pipe_and);
            try collectPipeline(hir, operands.rhs, allocator, stages, pipe_stderr);
        },
        else => stages.append(allocator, index),
    };
}

fn executeSimpleCommand(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const variables = executor.variableStore();
    var expansion_failure: Expander.Failure = undefined;
    const expander = executor.wordExpander(allocator, null, &expansion_failure);

    var argv: std.ArrayList([]const u8) = .empty;
    if (executor.prepared_simple) |prepared| try argv.appendSlice(allocator, prepared.argv);
    var file_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    var redirect_resources: std.ArrayList(CommandPlan.Resource) = .empty;
    defer closeRedirectResources(executor.host, &redirect_resources);
    const parts = hir.simpleCommandParts(index);
    var has_assignments = false;
    var has_redirects = false;
    var has_words = false;
    for (parts) |part| {
        switch (hir.instructionTag(part)) {
            .assignment => has_assignments = true,
            .redirect => has_redirects = true,
            .word => {
                has_words = true;
                if (executor.prepared_simple != null) continue;
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
    // Command words are expanded before redirect operands. Redirect actions
    // themselves still retain their source order when applied to the command.
    for (parts) |part| {
        if (hir.instructionTag(part) != .redirect) continue;
        if (try executor.appendRedirectActions(
            hir,
            part,
            allocator,
            expander,
            &expansion_failure,
            &file_actions,
            &redirect_resources,
        )) |failure| return failure;
    }
    if (argv.items.len == 0) {
        if (executor.pipeline_stage != null) return error.UnsupportedInstruction;
        var scope = switch (try executor.beginRedirections(
            file_actions.items,
            &redirect_resources,
            allocator,
        )) {
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
    const command = if (executor.prepared_simple) |prepared|
        prepared.command
    else
        executor.resolveCommand(argv.items[0]);
    switch (command) {
        .builtin => |candidate| {
            if (executor.background) return error.UnsupportedInstruction;
            if (executor.pipeline_stage != null and !candidate.supportsPipeline())
                return error.UnsupportedInstruction;
            var scope = switch (try executor.beginSimpleCommandRedirections(
                file_actions.items,
                &redirect_resources,
                allocator,
            )) {
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
        },
        .function => {
            if (executor.background) return error.UnsupportedInstruction;
            if (has_assignments) {
                const mutable_variables = variables orelse unreachable;
                try applyAssignments(mutable_variables, &command_variables);
            }
            var scope = switch (try executor.beginSimpleCommandRedirections(
                file_actions.items,
                &redirect_resources,
                allocator,
            )) {
                .ready => |ready| ready,
                .failed => |result| return result,
            };
            defer scope.deinit();
            // The pipeline endpoints become scoped redirections for the
            // function body. Inner commands are ordinary foreground commands,
            // not additional top-level pipeline stages.
            scope.executor.pipeline_stage = null;
            scope.executor.prepared_simple = null;
            return scope.executor.executeFunction(argv.items);
        },
        .external => {},
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
    var command_failure: ?CommandPlan.CommandFailure = null;
    const executable = (resolver.resolve(allocator, .{
        .name = argv.items[0],
        .search_path = try executor.commandSearchPath(allocator, &command_variables),
        .cwd = executor.workingDirectory(),
    }) catch |err| switch (err) {
        error.AccessDenied => denied: {
            command_failure = .access_denied;
            break :denied null;
        },
        error.OutOfMemory, error.Unexpected => return err,
    }) orelse unresolved: {
        if (command_failure == null) command_failure = .command_not_found;
        break :unresolved argv.items[0];
    };

    var effective_file_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    if (executor.background and !executor.job_control and
        (executor.pipeline_stage == null or executor.pipeline_stage.?.input == null))
    {
        if (executor.activeSandbox() == .restrict)
            return executor.commandFailure(argv.items[0], .{ .cannot_execute = .sandbox_unavailable });
        const input = try executor.host.createInput(&.{});
        redirect_resources.append(allocator, input) catch |err| {
            executor.host.closeResource(input);
            return err;
        };
        try effective_file_actions.append(allocator, .{
            .use_resource = .{ .resource = input, .target = .stdin },
        });
    }
    try effective_file_actions.appendSlice(allocator, executor.scoped_file_actions);
    if (executor.pipeline_stage) |stage| {
        if (stage.input) |resource| try effective_file_actions.append(allocator, .{
            .use_resource = .{ .resource = resource, .target = .stdin },
        });
        if (stage.output) |resource| try effective_file_actions.append(allocator, .{
            .use_resource = .{ .resource = resource, .target = .stdout },
        });
    }
    try effective_file_actions.appendSlice(allocator, file_actions.items);
    if (executor.pipeline_stage) |stage| {
        if (stage.pipe_stderr) try effective_file_actions.append(allocator, .{
            .duplicate = .{ .source = .stdout, .target = .stderr },
        });
    }
    const plan: CommandPlan = .{
        .executable = executable,
        .argv = argv.items,
        .environment = environment,
        .cwd = if (executor.workingDirectory()) |cwd| .{ .path = cwd } else .inherit,
        .file_actions = effective_file_actions.items,
        .sandbox = executor.activeSandbox(),
        .command_failure = command_failure,
    };
    if (executor.pipeline_stage == null and
        (executor.background or (executor.jobs != null and executor.jobs.?.terminal_control)))
    {
        const jobs = executor.jobs orelse return error.UnsupportedInstruction;
        var started = try Pipeline.startWithOptions(executor.gpa, executor.host, &.{plan}, .{
            .process_group = executor.host.capabilities().process_groups,
        });
        switch (started) {
            .failed => |failure| return executor.spawnFailure(
                argv.items[0],
                effective_file_actions.items,
                failure.reason,
            ),
            .started => |*pipeline| {
                const id = jobs.add(pipeline.*, argv.items[0], .{ .background = executor.background }) catch |err| {
                    pipeline.signal(.kill) catch {};
                    pipeline.deinit();
                    return err;
                };
                const coverage = pipeline.coverage(0);
                return .{
                    .status = if (executor.background) 0 else (try jobs.foreground(id)).?,
                    .sandbox_coverage = coverage,
                };
            },
        }
    }
    const spawn_outcome = (if (executor.pipeline_stage) |stage|
        stage.pipeline.spawn(stage.index, plan)
    else
        executor.host.spawn(plan)) catch |err| switch (err) {
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
    if (executor.pipeline_stage != null) {
        return .{
            .status = 0,
            .sandbox_coverage = spawned.sandbox_coverage,
        };
    }
    const termination = executor.host.wait(spawned.process) catch |err| {
        // A cancelled in-process pipeline stage may interrupt its nested wait.
        // The child is still host-owned; stop it and make one final reap attempt
        // before the stage releases its redirection resources.
        const previous_protection = if (executor.cancel_io) |io|
            io.swapCancelProtection(.blocked)
        else
            null;
        defer {
            if (previous_protection) |previous|
                _ = executor.cancel_io.?.swapCancelProtection(previous);
        }
        executor.host.signal(spawned.process, .kill) catch {};
        _ = executor.host.wait(spawned.process) catch {};
        return err;
    };
    return .{
        .status = try terminationStatus(termination),
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
    var resources: std.ArrayList(CommandPlan.Resource) = .empty;
    defer closeRedirectResources(executor.host, &resources);
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
            &resources,
        )) |failure| return .{ .failed = failure };
    }
    var start = try executor.beginSimpleCommandRedirections(
        actions.items,
        &resources,
        allocator,
    );
    if (executor.pipeline_stage != null) switch (start) {
        .ready => |*scope| scope.executor.pipeline_stage = null,
        .failed => {},
    };
    return start;
}

fn appendRedirectActions(
    executor: Executor,
    hir: Hir,
    redirect_index: Hir.Inst.Index,
    allocator: std.mem.Allocator,
    expander: Expander,
    expansion_failure: *Expander.Failure,
    actions: *std.ArrayList(CommandPlan.FileAction),
    resources: *std.ArrayList(CommandPlan.Resource),
) Error!?Result {
    const redirect = hir.redirect(redirect_index);
    const target = if (redirect.io_number) |io_number| target: {
        const descriptor = CommandPlan.FileDescriptor.parse(io_number) orelse
            return try executor.redirectFailure(.{ .invalid_file_descriptor = io_number });
        _ = standardStreamIndex(descriptor) orelse
            return try executor.redirectFailure(.{ .unsupported_file_descriptor = io_number });
        break :target descriptor;
    } else defaultRedirectDescriptor(redirect.operator);

    switch (redirect.operator) {
        .here_document, .here_document_strip_tabs => {
            const document_index = redirect.here_document.unwrap() orelse
                return error.UnsupportedInstruction;
            const document = hir.hereDocument(document_index);
            const source = document.body orelse return error.UnsupportedInstruction;
            const bytes = if (document.expand_body)
                expander.expandHereDocument(source) catch |err| switch (err) {
                    error.ParameterExpansionFailed => return try executor.parameterExpansionFailure(
                        allocator,
                        expansion_failure.*,
                    ),
                    else => |other| return other,
                }
            else
                source;
            return executor.appendInputResource(target, bytes, allocator, actions, resources);
        },
        .here_string => {
            const value = expander.expandAssignment(hir, redirect.target) catch |err| switch (err) {
                error.ParameterExpansionFailed => return try executor.parameterExpansionFailure(
                    allocator,
                    expansion_failure.*,
                ),
                else => |other| return other,
            };
            const bytes = try std.mem.concat(allocator, u8, &.{ value, "\n" });
            return executor.appendInputResource(target, bytes, allocator, actions, resources);
        },
        else => {},
    }

    const paths = expander.expandArgument(hir, redirect.target) catch |err| switch (err) {
        error.ParameterExpansionFailed => return try executor.parameterExpansionFailure(
            allocator,
            expansion_failure.*,
        ),
        else => |other| return other,
    };
    if (paths.len != 1)
        return try executor.redirectFailure(.ambiguous_redirect);

    switch (redirect.operator) {
        .duplicate_input, .duplicate_output => {
            if (std.mem.eql(u8, paths[0], "-")) {
                try actions.append(allocator, .{ .close = target });
            } else {
                const source = CommandPlan.FileDescriptor.parse(paths[0]) orelse
                    return try executor.redirectFailure(.{
                        .invalid_file_descriptor = paths[0],
                    });
                _ = standardStreamIndex(source) orelse
                    return try executor.redirectFailure(.{
                        .unsupported_file_descriptor = paths[0],
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

fn appendInputResource(
    executor: Executor,
    target: CommandPlan.FileDescriptor,
    bytes: []const u8,
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(CommandPlan.FileAction),
    resources: *std.ArrayList(CommandPlan.Resource),
) Error!?Result {
    // Host.createInput may create a temporary file in the shell process.
    // A child-only sandbox cannot constrain that preparation step.
    if (executor.activeSandbox() == .restrict)
        return try executor.redirectFailure(.{ .cannot_execute = .sandbox_unavailable });
    try actions.ensureUnusedCapacity(allocator, 1);
    try resources.ensureUnusedCapacity(allocator, 1);
    const resource = executor.host.createInput(bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceUnavailable => return try executor.redirectFailure(.input_resource_unavailable),
        else => |other| return other,
    };
    resources.appendAssumeCapacity(resource);
    actions.appendAssumeCapacity(.{ .use_resource = .{
        .resource = resource,
        .target = target,
    } });
    return null;
}

fn beginRedirections(
    executor: Executor,
    actions: []const CommandPlan.FileAction,
    owned_resources: *std.ArrayList(CommandPlan.Resource),
    allocator: std.mem.Allocator,
) Error!RedirectionStart {
    // Opens happen in the shell process. Check every action before performing
    // any of them so a later open cannot leave an earlier one behind.
    if (executor.activeSandbox() == .restrict) for (actions) |action| {
        if (action == .open)
            return .{ .failed = try executor.redirectFailure(.{ .cannot_execute = .sandbox_unavailable }) };
    };
    var scoped_executor = executor;
    var resources = owned_resources.*;
    owned_resources.* = .empty;
    var retain_resources = false;
    defer if (!retain_resources) {
        var index = resources.items.len;
        while (index != 0) {
            index -= 1;
            executor.host.closeResource(resources.items[index]);
        }
    };
    var scoped_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    try scoped_actions.appendSlice(allocator, executor.scoped_file_actions);

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
            if (open.target == .stdin) {
                scoped_executor.io.stdin = executor.host.resourceReader(resource);
            } else {
                scoped_executor.setRuntimeWriter(
                    open.target,
                    executor.host.resourceWriter(resource),
                );
            }
        },
        .duplicate => |duplicate| {
            _ = standardStreamIndex(duplicate.source) orelse
                return error.UnsupportedInstruction;
            _ = standardStreamIndex(duplicate.target) orelse
                return error.UnsupportedInstruction;
            const writer = scoped_executor.runtimeWriter(duplicate.source);
            scoped_executor.setRuntimeWriter(duplicate.target, writer);
            if (duplicate.target == .stdin)
                scoped_executor.io.stdin = if (duplicate.source == .stdin) scoped_executor.io.stdin else null;
            try scoped_actions.append(allocator, action);
        },
        .close => |descriptor| {
            _ = standardStreamIndex(descriptor) orelse
                return error.UnsupportedInstruction;
            scoped_executor.setRuntimeWriter(descriptor, null);
            if (descriptor == .stdin) scoped_executor.io.stdin = null;
            try scoped_actions.append(allocator, action);
        },
        .use_resource => |use| {
            _ = standardStreamIndex(use.target) orelse
                return error.UnsupportedInstruction;
            if (use.target == .stdin) {
                scoped_executor.io.stdin = executor.host.resourceReader(use.resource);
            } else {
                scoped_executor.setRuntimeWriter(
                    use.target,
                    executor.host.resourceWriter(use.resource),
                );
            }
            try scoped_actions.append(allocator, action);
        },
    };

    scoped_executor.scoped_file_actions = scoped_actions.items;
    retain_resources = true;
    return .{ .ready = .{
        .executor = scoped_executor,
        .resources = resources.items,
    } };
}

fn beginSimpleCommandRedirections(
    executor: Executor,
    actions: []const CommandPlan.FileAction,
    owned_resources: *std.ArrayList(CommandPlan.Resource),
    allocator: std.mem.Allocator,
) Error!RedirectionStart {
    var effective_actions: std.ArrayList(CommandPlan.FileAction) = .empty;
    if (executor.pipeline_stage) |stage| {
        if (stage.input) |resource| try effective_actions.append(allocator, .{
            .use_resource = .{ .resource = resource, .target = .stdin },
        });
        if (stage.output) |resource| try effective_actions.append(allocator, .{
            .use_resource = .{ .resource = resource, .target = .stdout },
        });
    }
    try effective_actions.appendSlice(allocator, actions);
    if (executor.pipeline_stage) |stage| {
        if (stage.pipe_stderr) try effective_actions.append(allocator, .{
            .duplicate = .{ .source = .stdout, .target = .stderr },
        });
    }
    return executor.beginRedirections(effective_actions.items, owned_resources, allocator);
}

fn closeRedirectResources(
    host: Host,
    resources: *std.ArrayList(CommandPlan.Resource),
) void {
    var index = resources.items.len;
    while (index != 0) {
        index -= 1;
        host.closeResource(resources.items[index]);
    }
    resources.* = .empty;
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

fn defaultRedirectDescriptor(operator: Hir.Redirect.Operator) CommandPlan.FileDescriptor {
    return switch (operator) {
        .input,
        .here_document,
        .here_document_strip_tabs,
        .here_string,
        .duplicate_input,
        .input_output,
        => .stdin,
        .output,
        .append,
        .duplicate_output,
        .clobber,
        .output_both,
        .append_both,
        => .stdout,
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
        .execution_context = executor.context,
        .runtime_state = executor.runtime_state,
        .positional_parameters = executor.positional_parameters_override,
        .jobs = executor.jobs,
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
    // Function HIR can originate from an earlier input, whose source is not
    // retained. Do not attach those offsets to the invoking input's diagnostics.
    function_executor.diagnostic_locations = false;
    var positional_parameters = argv[1..];
    function_executor.positional_parameters_override = &positional_parameters;
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
        .background_process_id = if (executor.jobs) |jobs| jobs.backgroundProcessIdText() else null,
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
    return executor.context.get().cwd;
}

fn invocationName(executor: Executor) []const u8 {
    if (executor.runtime_state) |state| return state.invocationName();
    return executor.invocation_name;
}

fn shellProcessId(executor: Executor) ?runtime.ProcessId {
    if (executor.runtime_state) |state| return state.shellProcessId();
    return executor.shell_process_id;
}

fn commandSearchPath(
    executor: Executor,
    allocator: std.mem.Allocator,
    overrides: *const VariableStore,
) std.mem.Allocator.Error![]const []const u8 {
    const path = overrides.get("PATH") orelse path: {
        if (executor.variableStore()) |variables|
            if (variables.get("PATH")) |value| break :path value;
        return if (executor.runtime_state) |state|
            state.defaultSearchPath()
        else
            executor.default_search_path;
    };

    var entries: std.ArrayList([]const u8) = .empty;
    errdefer entries.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (iterator.next()) |entry| try entries.append(allocator, entry);
    return entries.toOwnedSlice(allocator);
}

fn positionalParameters(executor: Executor) []const []const u8 {
    if (executor.positional_parameters_override) |parameters| return parameters.*;
    if (executor.runtime_state) |state| return state.positionalParameters();
    return executor.positional_parameters;
}

fn activeSandbox(executor: Executor) CommandPlan.Sandbox {
    return executor.context.get().sandbox;
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

fn pipelineFailure(
    executor: Executor,
    reason: runtime.Diagnostic.CannotCreatePipelineReason,
) std.Io.Writer.Error!Result {
    const diagnostic: runtime.Diagnostic = .{
        .subject = .shell,
        .kind = .{ .cannot_create_pipeline = reason },
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
            const action = file_actions[action_index];
            return switch (action) {
                .open => |open| executor.fileOpenFailure(open.path, file_action.reason),
                .duplicate, .close, .use_resource => switch (file_action.reason) {
                    .resource_unavailable => executor.commandFailure(
                        command,
                        .{ .cannot_execute = .resource_unavailable },
                    ),
                    .unsupported => executor.commandFailure(
                        command,
                        .{ .cannot_execute = .unsupported },
                    ),
                    else => error.Unexpected,
                },
            };
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
        .spawn_failed => |failure| switch (failure) {
            .command_not_found => 127,
            .file_action => 1,
            else => 126,
        },
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
