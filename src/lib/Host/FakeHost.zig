const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const SandboxPolicy = @import("../SandboxPolicy.zig");
const FakeHost = @This();

arena: std.heap.ArenaAllocator,
spawn_calls: std.ArrayList(CommandPlan) = .empty,
wait_calls: std.ArrayList(Host.Process) = .empty,
resolve_working_directory_calls: std.ArrayList(Host.WorkingDirectoryRequest) = .empty,
open_file_calls: std.ArrayList(OpenFileCall) = .empty,
create_input_calls: std.ArrayList([]const u8) = .empty,
create_pipe_calls: usize = 0,
closed_resource_count: usize = 0,
redirected_output: std.Io.Writer.Allocating,
next_process: u32 = 1,
next_process_group: u32 = 1,
next_resource: u32 = 1,
termination: Host.Termination = .{ .exited = 0 },
spawn_error: ?Host.SpawnError = null,
spawn_failure: ?Host.SpawnFailure = null,
spawn_failure_after: usize = 0,
wait_error: ?Host.Error = null,
resolve_working_directory_error: ?Host.Error = null,
working_directory_result: ?[]const u8 = null,
open_file_failure: ?Host.FileActionFailure.Reason = null,
open_file_failure_after: usize = 0,
create_input_error: ?Host.Error = null,
sandbox_coverage: ?SandboxPolicy.Coverage = null,

pub const OpenFileCall = struct {
    cwd: CommandPlan.WorkingDirectory,
    open: CommandPlan.FileAction.Open,
};

pub fn init(gpa: std.mem.Allocator) FakeHost {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .redirected_output = .init(gpa),
    };
}

pub fn deinit(fake: *FakeHost) void {
    fake.redirected_output.deinit();
    fake.arena.deinit();
    fake.* = undefined;
}

pub fn host(fake: *FakeHost) Host {
    return .{
        .userdata = fake,
        .vtable = &vtable,
    };
}

const vtable: Host.VTable = .{
    .spawn = spawn,
    .wait = wait,
    .open_file = openFile,
    .create_pipe = createPipe,
    .create_input = createInput,
    .close_resource = closeResource,
    .resource_writer = resourceWriter,
    .resolve_working_directory = resolveWorkingDirectory,
};

fn createPipe(userdata: ?*anyopaque) Host.Error!Host.Pipe {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    fake.create_pipe_calls += 1;
    const read_end: CommandPlan.Resource = @enumFromInt(fake.next_resource);
    fake.next_resource +%= 1;
    const write_end: CommandPlan.Resource = @enumFromInt(fake.next_resource);
    fake.next_resource +%= 1;
    return .{ .read_end = read_end, .write_end = write_end };
}

fn createInput(userdata: ?*anyopaque, bytes: []const u8) Host.Error!CommandPlan.Resource {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.create_input_error) |err| return err;
    const allocator = fake.arena.allocator();
    try fake.create_input_calls.append(allocator, try allocator.dupe(u8, bytes));
    const resource: CommandPlan.Resource = @enumFromInt(fake.next_resource);
    fake.next_resource +%= 1;
    return resource;
}

fn openFile(
    userdata: ?*anyopaque,
    cwd: CommandPlan.WorkingDirectory,
    open: CommandPlan.FileAction.Open,
) Host.SpawnError!Host.OpenFileOutcome {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.open_file_failure) |reason| {
        if (fake.open_file_calls.items.len >= fake.open_file_failure_after)
            return .{ .failed = reason };
    }

    const allocator = fake.arena.allocator();
    try fake.open_file_calls.append(allocator, .{
        .cwd = switch (cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = try allocator.dupe(u8, path) },
        },
        .open = .{
            .path = try allocator.dupe(u8, open.path),
            .target = open.target,
            .access = open.access,
            .disposition = open.disposition,
        },
    });
    const resource: CommandPlan.Resource = @enumFromInt(fake.next_resource);
    fake.next_resource +%= 1;
    return .{ .opened = resource };
}

fn closeResource(userdata: ?*anyopaque, resource: CommandPlan.Resource) void {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    _ = resource;
    fake.closed_resource_count += 1;
}

fn resourceWriter(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Writer {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (@intFromEnum(resource) == 0 or @intFromEnum(resource) >= fake.next_resource) return null;
    return &fake.redirected_output.writer;
}

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) Host.SpawnError!Host.SpawnOutcome {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.spawn_error) |err| return err;
    if (fake.spawn_failure) |failure| {
        if (fake.spawn_calls.items.len >= fake.spawn_failure_after)
            return .{ .failed = failure };
    }

    const allocator = fake.arena.allocator();
    try fake.spawn_calls.append(allocator, try clonePlan(allocator, plan));

    const process: Host.Process = @enumFromInt(fake.next_process);
    fake.next_process +%= 1;
    const process_group: ?CommandPlan.ProcessGroup = switch (plan.process_group) {
        .inherit => null,
        .create => group: {
            const group: CommandPlan.ProcessGroup = @enumFromInt(fake.next_process_group);
            fake.next_process_group +%= 1;
            break :group group;
        },
        .join => |group| group,
    };
    const sandbox_coverage: SandboxPolicy.Coverage = fake.sandbox_coverage orelse switch (plan.sandbox) {
        .inherit => .not_requested,
        .restrict => .complete,
    };
    return .{ .spawned = .{
        .process = process,
        .process_group = process_group,
        .sandbox_coverage = sandbox_coverage,
    } };
}

fn clonePlan(allocator: std.mem.Allocator, plan: CommandPlan) !CommandPlan {
    const argv = try allocator.alloc([]const u8, plan.argv.len);
    for (plan.argv, argv) |argument, *copy|
        copy.* = try allocator.dupe(u8, argument);

    const actions = try allocator.alloc(CommandPlan.FileAction, plan.file_actions.len);
    for (plan.file_actions, actions) |action, *copy| {
        copy.* = switch (action) {
            .open => |open| .{ .open = .{
                .path = try allocator.dupe(u8, open.path),
                .target = open.target,
                .access = open.access,
                .disposition = open.disposition,
            } },
            .duplicate => |duplicate| .{ .duplicate = duplicate },
            .use_resource => |resource| .{ .use_resource = resource },
            .close => |descriptor| .{ .close = descriptor },
        };
    }

    return .{
        .executable = try allocator.dupe(u8, plan.executable),
        .argv = argv,
        .environment = try cloneEnvironment(allocator, plan.environment),
        .cwd = switch (plan.cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = try allocator.dupe(u8, path) },
        },
        .file_actions = actions,
        .process_group = plan.process_group,
        .sandbox = try plan.sandbox.clone(allocator),
    };
}

fn cloneEnvironment(
    allocator: std.mem.Allocator,
    environment: CommandPlan.Environment,
) !CommandPlan.Environment {
    return switch (environment) {
        .inherit => .inherit,
        .overlay => |variables| .{ .overlay = try cloneEnvironmentVariables(allocator, variables) },
        .replace => |variables| .{ .replace = try cloneEnvironmentVariables(allocator, variables) },
    };
}

fn cloneEnvironmentVariables(
    allocator: std.mem.Allocator,
    variables: []const CommandPlan.EnvironmentVariable,
) ![]const CommandPlan.EnvironmentVariable {
    const copy = try allocator.alloc(CommandPlan.EnvironmentVariable, variables.len);
    for (variables, copy) |variable, *destination| {
        destination.* = .{
            .name = try allocator.dupe(u8, variable.name),
            .value = try allocator.dupe(u8, variable.value),
        };
    }
    return copy;
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.wait_error) |err| return err;
    try fake.wait_calls.append(fake.arena.allocator(), process);
    return fake.termination;
}

fn resolveWorkingDirectory(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Host.WorkingDirectoryRequest,
) Host.Error![]u8 {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.resolve_working_directory_error) |err| return err;
    const result = fake.working_directory_result orelse return error.Unsupported;

    const record_allocator = fake.arena.allocator();
    try fake.resolve_working_directory_calls.append(record_allocator, .{
        .current = if (request.current) |current|
            try record_allocator.dupe(u8, current)
        else
            null,
        .path = try record_allocator.dupe(u8, request.path),
    });
    return allocator.dupe(u8, result);
}
