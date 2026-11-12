//! Host resource and process lifetime for a connected command pipeline.
//!
//! Stage preparation, command language state, and result interpretation belong
//! to the caller. A pipeline owns pipe endpoints and spawned process handles;
//! its `Host` and submitted plans remain borrowed during each operation.

const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const Host = @import("Host.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");
const ProcessId = @import("runtime/types.zig").ProcessId;
const Source = @import("Source.zig");
const Pipeline = @This();

gpa: std.mem.Allocator,
host: Host,
pipes: []PipeState,
processes: []ProcessRecord,
create_group: bool = false,
/// Pending initial stop, consumed by the caller before granting TTY ownership.
suspend_on_start: bool = false,
process_group: ?CommandPlan.ProcessGroup = null,

pub const Error = Host.Error || Host.SpawnError;

pub const Stage = struct {
    input: ?CommandPlan.Resource,
    output: ?CommandPlan.Resource,
};

pub const StageResult = struct {
    termination: Host.Termination,
    sandbox_coverage: SandboxPolicy.Coverage,
};

/// The original request information needed to explain a delayed startup
/// failure. It contains no environment, output capture, or language state.
/// Views borrow this pipeline until deinit.
pub const FailureContext = struct {
    command: []const u8,
    file_actions: []const CommandPlan.FileAction,
    source: ?Source.Location,

    const Owned = struct {
        command: []u8,
        file_actions: []CommandPlan.FileAction,
        origin: ?Source,
        location: ?Source.Location,

        fn init(gpa: std.mem.Allocator, plan: CommandPlan, location: ?Source.Location) std.mem.Allocator.Error!Owned {
            const command = try gpa.dupe(u8, plan.argv[0]);
            errdefer gpa.free(command);
            const actions = try gpa.dupe(CommandPlan.FileAction, plan.file_actions);
            var initialized: usize = 0;
            errdefer {
                for (actions[0..initialized]) |action| if (action == .open) gpa.free(action.open.path);
                gpa.free(actions);
            }
            for (actions) |*action| {
                if (action.* == .open) action.open.path = try gpa.dupe(u8, action.open.path);
                initialized += 1;
            }
            const origin = if (location) |value|
                if (value.origin) |input| try Source.init(gpa, input) else null
            else
                null;
            return .{ .command = command, .file_actions = actions, .origin = origin, .location = location };
        }

        fn view(owned: Owned) FailureContext {
            var location = owned.location;
            if (location) |*value| value.origin = if (owned.origin) |origin| origin.view() else null;
            return .{ .command = owned.command, .file_actions = owned.file_actions, .source = location };
        }

        fn deinit(owned: *Owned, gpa: std.mem.Allocator) void {
            gpa.free(owned.command);
            for (owned.file_actions) |action| if (action == .open) gpa.free(action.open.path);
            gpa.free(owned.file_actions);
            if (owned.origin) |*origin| origin.deinit(gpa);
            owned.* = undefined;
        }
    };
};

pub const StartupFailure = struct { context: FailureContext, reason: Host.SpawnFailure };

pub const State = enum { running, stopped, completed };

pub const StageStatus = union(enum) {
    pending,
    running,
    stopped: u32,
    completed: StageResult,
};

pub const StartResult = union(enum) {
    started: Pipeline,
    failed: RunResult.Failure,
};

pub const StartOptions = struct {
    process_group: bool = false,
    suspend_on_start: bool = false,
    /// Empty, or one source location per submitted plan. Borrowed until start
    /// returns; each successfully spawned stage owns its attribution copy.
    origins: []const ?Source.Location = &.{},
};

pub const RunResult = union(enum) {
    completed: []StageResult,
    failed: Failure,

    pub const Failure = struct {
        stage: usize,
        reason: Host.SpawnFailure,
    };

    pub fn deinit(result: *RunResult, gpa: std.mem.Allocator) void {
        switch (result.*) {
            .completed => |stages| gpa.free(stages),
            .failed => {},
        }
        result.* = undefined;
    }
};

const PipeState = struct {
    endpoints: Host.Pipe,
    read_open: bool = true,
    write_open: bool = true,
};

const ProcessRecord = struct {
    spawned: bool = false,
    result: ?Host.SpawnResult = null,
    termination: ?Host.Termination = null,
    stopped: ?u32 = null,
    sandbox_coverage: SandboxPolicy.Coverage = .not_requested,
    process_id: ?ProcessId = null,
    context: ?FailureContext.Owned = null,
    failure_reported: bool = false,

    fn observe(record: *ProcessRecord, termination: Host.Termination) void {
        if (termination == .stopped) {
            record.stopped = termination.stopped;
            return;
        }
        record.termination = termination;
        record.stopped = null;
        record.result = null;
    }
};

pub fn init(gpa: std.mem.Allocator, host: Host, stage_count: usize) Host.Error!Pipeline {
    if (stage_count == 0) return error.InvalidArguments;
    const pipes = try gpa.alloc(PipeState, stage_count - 1);
    errdefer gpa.free(pipes);
    const processes = try gpa.alloc(ProcessRecord, stage_count);
    errdefer gpa.free(processes);
    @memset(processes, .{});

    var initialized_pipes: usize = 0;
    errdefer for (pipes[0..initialized_pipes]) |pipe| {
        host.closeResource(pipe.endpoints.read_end);
        host.closeResource(pipe.endpoints.write_end);
    };
    for (pipes) |*pipe| {
        pipe.* = .{ .endpoints = try host.createPipe() };
        initialized_pipes += 1;
    }
    return .{
        .gpa = gpa,
        .host = host,
        .pipes = pipes,
        .processes = processes,
    };
}

pub fn stage(pipeline: *const Pipeline, index: usize) Stage {
    std.debug.assert(index < pipeline.processes.len);
    return .{
        .input = if (index == 0 or !pipeline.pipes[index - 1].read_open)
            null
        else
            pipeline.pipes[index - 1].endpoints.read_end,
        .output = if (index == pipeline.pipes.len or !pipeline.pipes[index].write_open)
            null
        else
            pipeline.pipes[index].endpoints.write_end,
    };
}

pub fn stageCount(pipeline: *const Pipeline) usize {
    return pipeline.processes.len;
}

/// Records the final outcome of a stage which did not create a process. The
/// caller already handled its synchronous diagnostic. It must not remain
/// pending when this pipeline is transferred to a job or polled for completion.
pub fn completeUnspawned(pipeline: *Pipeline, index: usize, status_code: u8) void {
    const record = &pipeline.processes[index];
    std.debug.assert(!record.spawned and record.result == null and record.termination == null);
    record.spawned = true;
    record.termination = .{ .exited = status_code };
}

pub fn coverage(pipeline: *const Pipeline, index: usize) SandboxPolicy.Coverage {
    return pipeline.processes[index].sandbox_coverage;
}

pub fn processId(pipeline: *const Pipeline, index: usize) ?ProcessId {
    return pipeline.processes[index].process_id;
}

/// Records only a successfully spawned process. Each stage can spawn once;
/// failed attempts may be retried while their pipe endpoints remain open.
pub fn spawn(
    pipeline: *Pipeline,
    index: usize,
    plan: CommandPlan,
) Host.SpawnError!Host.SpawnOutcome {
    return pipeline.spawnWithOrigin(index, plan, null);
}

/// Copies command/path/source attribution before spawning. These values remain
/// available even if the caller frees its plan before the worker completes.
pub fn spawnWithOrigin(
    pipeline: *Pipeline,
    index: usize,
    plan: CommandPlan,
    origin: ?Source.Location,
) Host.SpawnError!Host.SpawnOutcome {
    try plan.validate();
    std.debug.assert(index < pipeline.processes.len);
    const record = &pipeline.processes[index];
    if (record.spawned) return error.InvalidArguments;
    var context = try FailureContext.Owned.init(pipeline.gpa, plan, origin);
    var context_owned = true;
    defer if (context_owned) context.deinit(pipeline.gpa);
    var effective_plan = plan;
    if (pipeline.suspend_on_start) effective_plan.suspend_before_execute = true;
    if (pipeline.create_group) {
        if (plan.process_group != .inherit) return error.InvalidArguments;
        effective_plan.process_group = if (pipeline.process_group) |group| .{ .join = group } else .create;
    }
    const outcome = try pipeline.host.spawn(effective_plan);
    switch (outcome) {
        .spawned => |result| {
            record.spawned = true;
            record.result = result;
            record.sandbox_coverage = result.sandbox_coverage;
            record.process_id = result.process_id;
            record.context = context;
            context_owned = false;
            if (pipeline.create_group) pipeline.process_group = result.process_group;
        },
        .failed => {},
    }
    return outcome;
}

pub fn failureContext(pipeline: *const Pipeline, index: usize) ?FailureContext {
    return if (pipeline.processes[index].context) |context| context.view() else null;
}

/// Delivers each delayed startup failure at most once. Ordinary exit statuses
/// and stopped processes do not become startup failures.
pub fn takeStartupFailure(pipeline: *Pipeline, index: usize) ?StartupFailure {
    const record = &pipeline.processes[index];
    const termination = record.termination orelse return null;
    if (termination != .spawn_failed or record.failure_reported) return null;
    const context = record.context orelse return null;
    record.failure_reported = true;
    return .{ .context = context.view(), .reason = termination.spawn_failed };
}

/// A successful wait consumes the process record; an unspawned or already
/// waited stage returns null. On wait error, deinit will retry once.
pub fn wait(pipeline: *Pipeline, index: usize) Host.Error!?Host.Termination {
    std.debug.assert(index < pipeline.processes.len);
    const record = &pipeline.processes[index];
    const spawned = record.result orelse return null;
    const termination = try pipeline.host.wait(spawned.process);
    record.observe(termination);
    return termination;
}

/// Completed results remain available until deinit. A stopped stage still
/// owns its process and can be resumed or terminated.
pub fn status(pipeline: *const Pipeline, index: usize) StageStatus {
    const record = &pipeline.processes[index];
    if (record.termination) |termination| return .{ .completed = .{
        .termination = termination,
        .sandbox_coverage = record.sandbox_coverage,
    } };
    if (record.stopped) |signal_number| return .{ .stopped = signal_number };
    return if (record.spawned) .running else .pending;
}

pub fn state(pipeline: *const Pipeline) State {
    var running = false;
    var stopped = false;
    for (pipeline.processes) |record| {
        if (record.stopped != null) {
            stopped = true;
            continue;
        }
        if (record.termination == null) running = true;
    }
    return if (running) .running else if (stopped) .stopped else .completed;
}

/// Observes each live process without waiting for it to finish. Unsupported
/// polling is reported by the host; it never silently becomes a blocking wait.
pub fn poll(pipeline: *Pipeline) Host.Error!State {
    for (pipeline.processes) |*record| {
        const spawned = record.result orelse continue;
        if (try pipeline.host.tryWait(spawned.process)) |termination|
            record.observe(termination);
    }
    return pipeline.state();
}

/// Sends a request to all live stages. Completed stages are never signalled.
/// A partial delivery cannot be rolled back; remaining stages are attempted
/// even if an earlier request fails.
pub fn signal(pipeline: *Pipeline, request: Host.Signal) Host.Error!void {
    if (pipeline.process_group) |group| {
        if (pipeline.state() == .completed) return;
        try pipeline.host.signalGroup(group, request);
        if (request == .cont) for (pipeline.processes) |*record| {
            record.stopped = null;
        };
        return;
    }
    var failure: ?Host.Error = null;
    for (pipeline.processes) |*record| {
        const spawned = record.result orelse continue;
        pipeline.host.signal(spawned.process, request) catch |err| {
            failure = failure orelse err;
            continue;
        };
        if (request == .cont) record.stopped = null;
    }
    if (failure) |err| return err;
}

pub fn waitAll(pipeline: *Pipeline) Host.Error!State {
    if (pipeline.state() == .stopped) return .stopped;
    for (0..pipeline.processes.len) |index| {
        if (pipeline.processes[index].stopped != null) continue;
        _ = try pipeline.wait(index);
    }
    return pipeline.state();
}

/// Waits for completion or a stop notification, retaining every live handle.
pub fn waitEvents(pipeline: *Pipeline) Host.Error!State {
    const processes = try pipeline.gpa.alloc(Host.Process, pipeline.stageCount());
    defer pipeline.gpa.free(processes);
    while (pipeline.state() == .running) {
        var count: usize = 0;
        for (pipeline.processes) |record| {
            if (record.stopped != null) continue;
            if (record.result) |spawned| {
                processes[count] = spawned.process;
                count += 1;
            }
        }
        if (count == 0) break;
        const event = try pipeline.host.waitAny(processes[0..count]);
        for (pipeline.processes) |*record| {
            const spawned = record.result orelse continue;
            if (spawned.process == event.process) {
                record.observe(event.termination);
                break;
            }
        }
    }
    return pipeline.state();
}

/// Releases the parent copies of the endpoints adjacent to this stage.
/// Repeated calls are harmless; deinit closes any endpoints left open.
pub fn closeStage(pipeline: *Pipeline, index: usize) void {
    std.debug.assert(index < pipeline.processes.len);
    if (index != 0) pipeline.closeRead(index - 1);
    if (index != pipeline.pipes.len) pipeline.closeWrite(index);
}

/// Closes every remaining pipe endpoint before waiting for unconsumed child
/// processes. This may block: it does not cancel running commands. Wait errors
/// cannot be returned from deinit and are ignored.
pub fn deinit(pipeline: *Pipeline) void {
    for (pipeline.pipes, 0..) |_, index| {
        pipeline.closeRead(index);
        pipeline.closeWrite(index);
    }
    for (pipeline.processes) |*record| {
        if (record.result) |spawned| {
            _ = pipeline.host.wait(spawned.process) catch {};
            record.result = null;
        }
        if (record.context) |*context| context.deinit(pipeline.gpa);
    }
    pipeline.gpa.free(pipeline.pipes);
    pipeline.gpa.free(pipeline.processes);
    pipeline.* = undefined;
}

fn closeRead(pipeline: *Pipeline, index: usize) void {
    const pipe = &pipeline.pipes[index];
    if (!pipe.read_open) return;
    pipeline.host.closeResource(pipe.endpoints.read_end);
    pipe.read_open = false;
}

fn closeWrite(pipeline: *Pipeline, index: usize) void {
    const pipe = &pipeline.pipes[index];
    if (!pipe.write_open) return;
    pipeline.host.closeResource(pipe.endpoints.write_end);
    pipe.write_open = false;
}

/// Runs fully prepared external stages. Connection actions precede each
/// plan's file actions, so explicit redirections keep their source order.
/// Terminations are returned in stage order even though spawning is reversed.
/// A spawn failure does not undo stages already started; cleanup waits for them.
/// A file-action failure index refers to this combined action sequence.
pub fn run(
    gpa: std.mem.Allocator,
    host: Host,
    plans: []const CommandPlan,
) Error!RunResult {
    var started = try Pipeline.start(gpa, host, plans);
    const pipeline = switch (started) {
        .started => |*value| value,
        .failed => |failure| return .{ .failed = failure },
    };
    defer pipeline.deinit();

    const stages = try gpa.alloc(StageResult, plans.len);
    errdefer gpa.free(stages);
    for (stages, 0..) |*stage_result, index| {
        _ = try pipeline.wait(index);
        stage_result.* = pipeline.status(index).completed;
    }
    return .{ .completed = stages };
}

/// Starts every external stage and returns ownership without waiting. Plans
/// and argument storage are borrowed only until this call returns; Host.spawn
/// must consume or copy them before returning. Parent pipe ends are closed
/// after each stage inherits them, so delayed waiting cannot keep a pipe alive.
/// On startup failure a kill request is attempted for already started peers
/// before waiting for them. Hosts without that operation may still block.
pub fn start(
    gpa: std.mem.Allocator,
    host: Host,
    plans: []const CommandPlan,
) Error!StartResult {
    return startWithOptions(gpa, host, plans, .{});
}

pub fn startWithOptions(
    gpa: std.mem.Allocator,
    host: Host,
    plans: []const CommandPlan,
    options: StartOptions,
) Error!StartResult {
    if (options.origins.len != 0 and options.origins.len != plans.len) return error.InvalidArguments;
    // Plans are already concrete: reject malformed input before creating
    // resources or launching any of the neighbouring commands.
    for (plans) |plan| try plan.validate();
    if (options.process_group and !host.capabilities().process_groups) return error.Unsupported;
    if (options.suspend_on_start and !host.capabilities().suspend_before_execute) return error.Unsupported;
    var pipeline = try Pipeline.init(gpa, host, plans.len);
    pipeline.create_group = options.process_group;
    pipeline.suspend_on_start = options.suspend_on_start;
    var transferred = false;
    defer if (!transferred) {
        pipeline.signal(.kill) catch {};
        pipeline.deinit();
    };

    for (0..plans.len) |offset| {
        const index = plans.len - 1 - offset;
        const connections = pipeline.stage(index);
        const connection_count: usize = @as(usize, @intFromBool(connections.input != null)) +
            @intFromBool(connections.output != null);
        const actions = try gpa.alloc(
            CommandPlan.FileAction,
            connection_count + plans[index].file_actions.len,
        );
        defer gpa.free(actions);
        var next_action: usize = 0;
        if (connections.input) |input| {
            actions[next_action] = .{ .use_resource = .{
                .resource = input,
                .target = .stdin,
            } };
            next_action += 1;
        }
        if (connections.output) |output| {
            actions[next_action] = .{ .use_resource = .{
                .resource = output,
                .target = .stdout,
            } };
            next_action += 1;
        }
        @memcpy(actions[next_action..], plans[index].file_actions);
        var plan = plans[index];
        plan.file_actions = actions;
        const outcome = try pipeline.spawnWithOrigin(index, plan, if (options.origins.len == 0) null else options.origins[index]);
        switch (outcome) {
            .spawned => {},
            .failed => |reason| return .{ .failed = .{ .stage = index, .reason = reason } },
        }
        pipeline.closeStage(index);
    }

    transferred = true;
    return .{ .started = pipeline };
}

test "run connects stages before explicit actions and reaps in stage order" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.sandbox_coverage = .partial;
    var checking_vtable = fake.host().vtable.*;
    checking_vtable.wait = waitAfterAllPipeEndsClose;
    const checking_host: Host = .{ .userdata = &fake, .vtable = &checking_vtable };
    const plans = [_]CommandPlan{
        .{ .executable = "/first", .argv = &.{"/first"} },
        .{
            .executable = "/middle",
            .argv = &.{"/middle"},
            .file_actions = &.{.{ .open = .{
                .path = "output",
                .target = .stdout,
                .access = .write,
                .disposition = .create_or_truncate,
            } }},
        },
        .{ .executable = "/last", .argv = &.{"/last"} },
    };
    var result = try Pipeline.run(std.testing.allocator, checking_host, &plans);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), fake.create_pipe_calls);
    try std.testing.expectEqual(@as(usize, 4), fake.closed_resource_count);
    try std.testing.expectEqual(@as(usize, 3), fake.spawn_calls.items.len);
    try std.testing.expectEqual(@as(usize, 3), fake.wait_calls.items.len);
    try std.testing.expectEqualStrings("/last", fake.spawn_calls.items[0].executable);
    try std.testing.expectEqualStrings("/middle", fake.spawn_calls.items[1].executable);
    try std.testing.expectEqualStrings("/first", fake.spawn_calls.items[2].executable);

    const last_actions = fake.spawn_calls.items[0].file_actions;
    try std.testing.expectEqual(@as(usize, 1), last_actions.len);
    try std.testing.expectEqual(CommandPlan.FileDescriptor.stdin, last_actions[0].use_resource.target);
    try std.testing.expectEqual(@as(u32, 3), @backingInt(last_actions[0].use_resource.resource));
    const middle_actions = fake.spawn_calls.items[1].file_actions;
    try std.testing.expectEqual(@as(usize, 3), middle_actions.len);
    try std.testing.expectEqual(CommandPlan.FileDescriptor.stdin, middle_actions[0].use_resource.target);
    try std.testing.expectEqual(@as(u32, 1), @backingInt(middle_actions[0].use_resource.resource));
    try std.testing.expectEqual(CommandPlan.FileDescriptor.stdout, middle_actions[1].use_resource.target);
    try std.testing.expectEqual(@as(u32, 4), @backingInt(middle_actions[1].use_resource.resource));
    try std.testing.expectEqualStrings("output", middle_actions[2].open.path);
    const first_actions = fake.spawn_calls.items[2].file_actions;
    try std.testing.expectEqual(@as(usize, 1), first_actions.len);
    try std.testing.expectEqual(CommandPlan.FileDescriptor.stdout, first_actions[0].use_resource.target);
    try std.testing.expectEqual(@as(u32, 2), @backingInt(first_actions[0].use_resource.resource));

    try std.testing.expectEqual(@as(u32, 3), @backingInt(fake.wait_calls.items[0]));
    try std.testing.expectEqual(@as(u32, 2), @backingInt(fake.wait_calls.items[1]));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(fake.wait_calls.items[2]));
    try std.testing.expectEqual(@as(usize, 3), result.completed.len);
    for (result.completed) |stage_result| {
        try std.testing.expectEqual(SandboxPolicy.Coverage.partial, stage_result.sandbox_coverage);
        try std.testing.expectEqual(@as(u8, 0), stage_result.termination.exited);
    }
}

fn waitAfterAllPipeEndsClose(
    userdata: ?*anyopaque,
    process: Host.Process,
) Host.Error!Host.Termination {
    const FakeHost = @import("Host/FakeHost.zig");
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.closed_resource_count != 4) return error.Unexpected;
    return fake.host().wait(process);
}

test "init closes earlier pipes when later pipe creation fails" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var failing_vtable = fake.host().vtable.*;
    failing_vtable.create_pipe = failSecondPipe;
    const failing_host: Host = .{ .userdata = &fake, .vtable = &failing_vtable };

    try std.testing.expectError(
        error.ResourceUnavailable,
        Pipeline.init(std.testing.allocator, failing_host, 3),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.create_pipe_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.closed_resource_count);
}

fn failSecondPipe(userdata: ?*anyopaque) Host.Error!Host.Pipe {
    const FakeHost = @import("Host/FakeHost.zig");
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.create_pipe_calls == 1) return error.ResourceUnavailable;
    return fake.host().createPipe();
}

test "stage close and wait are idempotent while a stage cannot spawn twice" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var pipeline = try Pipeline.init(std.testing.allocator, fake.host(), 2);
    defer pipeline.deinit();
    const plan: CommandPlan = .{ .executable = "/first", .argv = &.{"/first"} };

    try std.testing.expect(pipeline.stage(0).input == null);
    try std.testing.expect(pipeline.stage(0).output != null);
    try std.testing.expect(pipeline.stage(1).input != null);
    try std.testing.expect(pipeline.stage(1).output == null);
    const outcome = try pipeline.spawn(1, plan);
    try std.testing.expect(outcome == .spawned);
    try std.testing.expectError(error.InvalidArguments, pipeline.spawn(1, plan));
    pipeline.closeStage(1);
    pipeline.closeStage(1);
    try std.testing.expectEqual(@as(usize, 1), fake.closed_resource_count);
    try std.testing.expect(pipeline.stage(1).input == null);
    try std.testing.expect((try pipeline.wait(1)) != null);
    try std.testing.expect((try pipeline.wait(1)) == null);
    try std.testing.expectError(error.InvalidArguments, pipeline.spawn(1, plan));
    pipeline.closeStage(0);
    pipeline.closeStage(0);
    try std.testing.expectEqual(@as(usize, 2), fake.closed_resource_count);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
}

test "spawn failure closes pipes and reaps already spawned stages" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.spawn_failure = .command_not_found;
    fake.spawn_failure_after = 1;
    const plans = [_]CommandPlan{
        .{ .executable = "/first", .argv = &.{"/first"} },
        .{ .executable = "/middle", .argv = &.{"/middle"} },
        .{ .executable = "/last", .argv = &.{"/last"} },
    };
    var result = try Pipeline.run(std.testing.allocator, fake.host(), &plans);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.failed.stage);
    try std.testing.expect(result.failed.reason == .command_not_found);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_calls.items.len);
    try std.testing.expectEqualStrings("/last", fake.spawn_calls.items[0].executable);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 4), fake.closed_resource_count);
}

test "run validates every plan before starting the pipeline" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const plans = [_]CommandPlan{
        .{ .executable = "/first", .argv = &.{} },
        .{ .executable = "/last", .argv = &.{"/last"} },
    };
    try std.testing.expectError(
        error.InvalidArguments,
        Pipeline.run(std.testing.allocator, fake.host(), &plans),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.create_pipe_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_calls.items.len);
}

test "pipeline run handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runWithAllocator,
        .{},
    );
}

fn runWithAllocator(gpa: std.mem.Allocator) !void {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const plans = [_]CommandPlan{
        .{ .executable = "/first", .argv = &.{"/first"} },
        .{ .executable = "/last", .argv = &.{"/last"} },
    };
    var result = try Pipeline.run(gpa, fake.host(), &plans);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), result.completed.len);
    try std.testing.expectEqual(@as(usize, 2), fake.closed_resource_count);
}

test "start returns live ownership and poll retains completed results" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.try_wait_termination = null;
    fake.sandbox_coverage = .partial;
    const plans = [_]CommandPlan{
        .{ .executable = "/first", .argv = &.{"/first"} },
        .{ .executable = "/last", .argv = &.{"/last"} },
    };
    var result = try Pipeline.start(std.testing.allocator, fake.host(), &plans);
    const pipeline = &result.started;
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 2), fake.closed_resource_count);
    try std.testing.expectEqual(State.running, try pipeline.poll());

    fake.try_wait_termination = .{ .exited = 23 };
    try std.testing.expectEqual(State.completed, try pipeline.poll());
    try std.testing.expectEqual(@as(u8, 23), pipeline.status(0).completed.termination.exited);
    try std.testing.expectEqual(SandboxPolicy.Coverage.partial, pipeline.status(1).completed.sandbox_coverage);
    const calls = fake.try_wait_calls.items.len;
    try std.testing.expectEqual(State.completed, try pipeline.poll());
    try std.testing.expectEqual(State.completed, try pipeline.waitAll());
    try pipeline.signal(.kill);
    try std.testing.expectEqual(calls, fake.try_wait_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.signal_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
}

test "stopped stages retain ownership until resumed and waited" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    const plans = [_]CommandPlan{.{ .executable = "/command", .argv = &.{"/command"} }};
    var result = try Pipeline.start(std.testing.allocator, fake.host(), &plans);
    const pipeline = &result.started;
    defer pipeline.deinit();
    fake.try_wait_termination = .{ .stopped = 19 };
    try std.testing.expectEqual(State.stopped, try pipeline.poll());
    try std.testing.expectEqual(@as(u32, 19), pipeline.status(0).stopped);
    try std.testing.expectEqual(State.stopped, try pipeline.waitAll());
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
    try pipeline.signal(.cont);
    try std.testing.expectEqual(State.running, pipeline.state());
    fake.termination = .{ .exited = 7 };
    try std.testing.expectEqual(State.completed, try pipeline.waitAll());
    try std.testing.expectEqual(@as(u8, 7), pipeline.status(0).completed.termination.exited);
    try std.testing.expectEqual(Host.Signal.cont, fake.signal_calls.items[0].signal);
}

test "unsupported polling preserves a live pipeline for blocking wait" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.try_wait_error = error.Unsupported;
    const plans = [_]CommandPlan{.{ .executable = "/command", .argv = &.{"/command"} }};
    var result = try Pipeline.start(std.testing.allocator, fake.host(), &plans);
    const pipeline = &result.started;
    defer pipeline.deinit();
    try std.testing.expectError(error.Unsupported, pipeline.poll());
    try std.testing.expectEqual(State.running, pipeline.state());
    try std.testing.expectEqual(State.completed, try pipeline.waitAll());
}

test "a real input-blocked process can be started polled and killed" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var system: Host.System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const host = system.host();
    const input = try host.createPipe();
    defer host.closeResource(input.read_end);
    defer host.closeResource(input.write_end);
    const plans = [_]CommandPlan{.{
        .executable = "/bin/cat",
        .argv = &.{"/bin/cat"},
        .file_actions = &.{.{ .use_resource = .{ .resource = input.read_end, .target = .stdin } }},
    }};
    var result = try Pipeline.start(std.testing.allocator, host, &plans);
    const pipeline = &result.started;
    defer pipeline.deinit();
    try std.testing.expectEqual(State.running, try pipeline.poll());
    try pipeline.signal(.kill);
    try std.testing.expectEqual(State.completed, try pipeline.waitAll());
    try std.testing.expect(pipeline.status(0).completed.termination == .signal);
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test {
    std.testing.refAllDecls(@This());
}
