//! Executes Habush HIR through a `Host`.

const std = @import("std");
const Builtin = @import("Builtin.zig");
const CommandPlan = @import("CommandPlan.zig");
const CommandResolver = @import("CommandResolver.zig");
const Executor = @This();
const Expander = @import("Expander.zig");
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const VariableStore = @import("VariableStore.zig");

gpa: std.mem.Allocator,
host: Host,
sandbox: CommandPlan.Sandbox,
resolver: ?CommandResolver,
search_path: []const []const u8,
cwd: ?[]const u8,
variables: ?*VariableStore,

pub const Error = Host.Error || Expander.Error || CommandResolver.Error || VariableStore.Error || error{
    UnsupportedInstruction,
    CommandResolutionUnavailable,
    UnexpectedTermination,
    VariableStateUnavailable,
};

pub const Options = struct {
    sandbox: CommandPlan.Sandbox = .inherit,
    resolver: ?CommandResolver = null,
    search_path: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// Complete shell variable state. When present, exported bindings become
    /// an exact replacement environment; `null` preserves host inheritance.
    variables: ?*VariableStore = null,
};

pub const Result = struct {
    status: u8,
    sandbox_coverage: SandboxPolicy.Coverage,
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
        .cwd = options.cwd,
        .variables = options.variables,
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
        .simple_command => executor.executeSimpleCommand(hir, index),
        else => error.UnsupportedInstruction,
    };
}

fn executeList(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var result: Result = .{ .status = 0, .sandbox_coverage = .not_requested };
    for (0..hir.listItemCount(index)) |item_index| {
        const item = hir.listItem(index, item_index);
        if (item.separator == .background) return error.UnsupportedInstruction;
        const command_result = try executor.executeInstruction(hir, item.command);
        result.status = command_result.status;
        result.sandbox_coverage = combineSandboxCoverage(
            result.sandbox_coverage,
            command_result.sandbox_coverage,
        );
    }
    return result;
}

fn executeSimpleCommand(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!Result {
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expander = Expander.initWithContext(allocator, .{
        .variables = executor.variables,
    });

    var argv: std.ArrayList([]const u8) = .empty;
    const parts = hir.simpleCommandParts(index);
    var has_assignments = false;
    for (parts) |part| {
        switch (hir.instructionTag(part)) {
            .assignment => has_assignments = true,
            .word => try argv.appendSlice(allocator, try expander.expandArgument(hir, part)),
            else => return error.UnsupportedInstruction,
        }
    }
    if (argv.items.len == 0) {
        if (!has_assignments) return error.UnsupportedInstruction;
        const variables = executor.variables orelse return error.VariableStateUnavailable;
        for (parts) |part| {
            const assignment = hir.assignment(part);
            const value = try expander.expandAssignment(hir, assignment.value);
            try variables.set(assignment.name, value);
        }
        return .{ .status = 0, .sandbox_coverage = .not_requested };
    }

    var command_variables = VariableStore.init(allocator);
    defer command_variables.deinit();
    if (has_assignments) {
        for (parts) |part| {
            if (hir.instructionTag(part) != .assignment) continue;
            const assignment = hir.assignment(part);
            const assignment_expander = Expander.initWithContext(allocator, .{
                .variables = executor.variables,
                .overrides = &command_variables,
            });
            const value = try assignment_expander.expandAssignment(hir, assignment.value);
            try command_variables.set(assignment.name, value);
        }
    }
    if (Builtin.lookup(argv.items[0])) |builtin| {
        if (builtin.special and has_assignments) {
            const variables = executor.variables orelse return error.VariableStateUnavailable;
            try applyAssignments(variables, &command_variables);
        }
        const result = builtin.run(argv.items);
        return .{ .status = result.status, .sandbox_coverage = .not_requested };
    }

    var process_environment = VariableStore.init(allocator);
    defer process_environment.deinit();
    const environment = try prepareEnvironment(
        allocator,
        executor.variables,
        &command_variables,
        &process_environment,
    );

    const executable = if (CommandPlan.isExplicitPath(argv.items[0]))
        argv.items[0]
    else if (executor.resolver) |resolver|
        (try resolver.resolve(allocator, .{
            .name = argv.items[0],
            .search_path = executor.search_path,
            .cwd = executor.cwd,
        })) orelse return error.CommandNotFound
    else
        return error.CommandResolutionUnavailable;

    const spawned = try executor.host.spawn(.{
        .executable = executable,
        .argv = argv.items,
        .environment = environment,
        .cwd = if (executor.cwd) |cwd| .{ .path = cwd } else .inherit,
        .sandbox = executor.sandbox,
    });
    return .{
        .status = try terminationStatus(try executor.host.wait(spawned.process)),
        .sandbox_coverage = spawned.sandbox_coverage,
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
