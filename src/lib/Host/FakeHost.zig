const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const SandboxPolicy = @import("../SandboxPolicy.zig");
const FakeHost = @This();

arena: std.heap.ArenaAllocator,
spawn_calls: std.ArrayList(CommandPlan) = .empty,
wait_calls: std.ArrayList(Host.Process) = .empty,
resolve_working_directory_calls: std.ArrayList(Host.WorkingDirectoryRequest) = .empty,
next_process: u32 = 1,
next_process_group: u32 = 1,
termination: Host.Termination = .{ .exited = 0 },
spawn_error: ?Host.Error = null,
wait_error: ?Host.Error = null,
resolve_working_directory_error: ?Host.Error = null,
working_directory_result: ?[]const u8 = null,
sandbox_coverage: ?SandboxPolicy.Coverage = null,

pub fn init(gpa: std.mem.Allocator) FakeHost {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

pub fn deinit(fake: *FakeHost) void {
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
    .resolve_working_directory = resolveWorkingDirectory,
};

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) Host.Error!Host.SpawnResult {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.spawn_error) |err| return err;

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
    return .{
        .process = process,
        .process_group = process_group,
        .sandbox_coverage = sandbox_coverage,
    };
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
