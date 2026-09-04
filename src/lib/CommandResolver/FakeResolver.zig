const std = @import("std");
const CommandResolver = @import("../CommandResolver.zig");
const FakeResolver = @This();

arena: std.heap.ArenaAllocator,
calls: std.ArrayList(CommandResolver.Request) = .empty,
result: ?[]const u8 = null,
resolve_error: ?CommandResolver.Error = null,

pub fn init(gpa: std.mem.Allocator) FakeResolver {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

pub fn deinit(fake: *FakeResolver) void {
    fake.arena.deinit();
    fake.* = undefined;
}

pub fn resolver(fake: *FakeResolver) CommandResolver {
    return .{
        .userdata = fake,
        .vtable = &vtable,
    };
}

const vtable: CommandResolver.VTable = .{
    .resolve = resolve,
};

fn resolve(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: CommandResolver.Request,
) CommandResolver.Error!?[]u8 {
    const fake: *FakeResolver = @ptrCast(@alignCast(userdata.?));
    if (fake.resolve_error) |err| return err;

    const record_allocator = fake.arena.allocator();
    const search_path = try record_allocator.alloc([]const u8, request.search_path.len);
    for (request.search_path, search_path) |entry, *copy|
        copy.* = try record_allocator.dupe(u8, entry);
    try fake.calls.append(record_allocator, .{
        .name = try record_allocator.dupe(u8, request.name),
        .search_path = search_path,
        .cwd = if (request.cwd) |cwd|
            try record_allocator.dupe(u8, cwd)
        else
            null,
    });

    return if (fake.result) |path|
        try allocator.dupe(u8, path)
    else
        null;
}
