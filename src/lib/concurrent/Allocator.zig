//! Serializes allocations against a backing allocator used by pipeline tasks.
//!
//! Every concurrent user of a non-thread-safe backing allocator must use the
//! same wrapper. The wrapper and its Io driver must outlive those users.

const std = @import("std");
const ConcurrentAllocator = @This();

backing: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,

pub fn allocator(self: *ConcurrentAllocator) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn from(ptr: *anyopaque) *ConcurrentAllocator {
    return @ptrCast(@alignCast(ptr));
}

fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self = from(ptr);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self = from(ptr);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self = from(ptr);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self = from(ptr);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
}

test "serializes allocations from concurrent tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var wrapper: ConcurrentAllocator = .{
        .backing = arena.allocator(),
        .io = std.testing.io,
    };
    const gpa = wrapper.allocator();
    var group: std.Io.Group = .init;
    errdefer group.cancel(std.testing.io);
    try group.concurrent(std.testing.io, allocateMany, .{gpa});
    try group.concurrent(std.testing.io, allocateMany, .{gpa});
    try group.await(std.testing.io);
}

fn allocateMany(gpa: std.mem.Allocator) std.Io.Cancelable!void {
    for (0..100) |_| {
        const bytes = gpa.alloc(u8, 64) catch unreachable;
        @memset(bytes, 1);
        gpa.free(bytes);
    }
}
