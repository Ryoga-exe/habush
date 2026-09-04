const std = @import("std");
const Host = @import("../Host.zig");
const FakeHost = @This();

arena: std.heap.ArenaAllocator,
spawn_calls: std.ArrayList(SpawnCall) = .empty,
wait_calls: std.ArrayList(Host.Process) = .empty,
next_process: u32 = 1,
termination: Host.Termination = .{ .exited = 0 },
spawn_error: ?Host.Error = null,
wait_error: ?Host.Error = null,

pub const SpawnCall = struct {
    argv: []const []const u8,
    environment: ?[]const Host.EnvironmentVariable,
    cwd: ?[]const u8,
};

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

fn spawn(userdata: ?*anyopaque, options: Host.SpawnOptions) Host.Error!Host.Process {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.spawn_error) |err| return err;

    const allocator = fake.arena.allocator();
    const argv = try allocator.alloc([]const u8, options.argv.len);
    for (options.argv, argv) |argument, *copy|
        copy.* = try allocator.dupe(u8, argument);

    const environment = if (options.environment) |variables| environment: {
        const copy = try allocator.alloc(Host.EnvironmentVariable, variables.len);
        for (variables, copy) |variable, *destination| {
            destination.* = .{
                .name = try allocator.dupe(u8, variable.name),
                .value = try allocator.dupe(u8, variable.value),
            };
        }
        break :environment copy;
    } else null;

    const cwd = if (options.cwd) |path|
        try allocator.dupe(u8, path)
    else
        null;

    try fake.spawn_calls.append(allocator, .{
        .argv = argv,
        .environment = environment,
        .cwd = cwd,
    });

    const process: Host.Process = @enumFromInt(fake.next_process);
    fake.next_process +%= 1;
    return process;
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
    if (fake.wait_error) |err| return err;
    try fake.wait_calls.append(fake.arena.allocator(), process);
    return fake.termination;
}
