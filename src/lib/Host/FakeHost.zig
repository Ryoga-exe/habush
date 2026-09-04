const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const Policy = @import("../Security/Policy.zig");
const FakeHost = @This();

arena: std.heap.ArenaAllocator,
spawn_calls: std.ArrayList(CommandPlan) = .empty,
wait_calls: std.ArrayList(Host.Process) = .empty,
next_process: u32 = 1,
next_process_group: u32 = 1,
termination: Host.Termination = .{ .exited = 0 },
spawn_error: ?Host.Error = null,
wait_error: ?Host.Error = null,
security_coverage: ?Policy.Coverage = null,

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
    const security_coverage: Policy.Coverage = fake.security_coverage orelse switch (plan.security) {
        .inherit => .not_requested,
        .restrict => .complete,
    };
    return .{
        .process = process,
        .process_group = process_group,
        .security = security_coverage,
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
        .security = try cloneSecurity(allocator, plan.security),
    };
}

fn cloneEnvironment(
    allocator: std.mem.Allocator,
    environment: CommandPlan.Environment,
) !CommandPlan.Environment {
    return switch (environment) {
        .inherit => .inherit,
        .replace => |variables| replace: {
            const copy = try allocator.alloc(CommandPlan.EnvironmentVariable, variables.len);
            for (variables, copy) |variable, *destination| {
                destination.* = .{
                    .name = try allocator.dupe(u8, variable.name),
                    .value = try allocator.dupe(u8, variable.value),
                };
            }
            break :replace .{ .replace = copy };
        },
    };
}

fn cloneSecurity(
    allocator: std.mem.Allocator,
    security: CommandPlan.Security,
) !CommandPlan.Security {
    return switch (security) {
        .inherit => .inherit,
        .restrict => |policy| .{ .restrict = .{
            .enforcement = policy.enforcement,
            .file_system = switch (policy.file_system) {
                .unrestricted => .unrestricted,
                .allow => |rules| allow: {
                    const copy = try allocator.alloc(Policy.PathRule, rules.len);
                    for (rules, copy) |rule, *destination| {
                        destination.* = .{
                            .path = try allocator.dupe(u8, rule.path),
                            .scope = rule.scope,
                            .access = rule.access,
                        };
                    }
                    break :allow .{ .allow = copy };
                },
            },
            .network = switch (policy.network) {
                .unrestricted => .unrestricted,
                .allow => |rules| .{ .allow = try allocator.dupe(Policy.NetworkRule, rules) },
            },
        } },
    };
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.wait_error) |err| return err;
    try fake.wait_calls.append(fake.arena.allocator(), process);
    return fake.termination;
}
