//! Unbuffered writer that serializes access to a shared parent writer.
//!
//! All wrappers pointing at the same target must share one mutex. The target,
//! mutex, and Io driver must outlive this wrapper and every concurrent write.

const std = @import("std");
const ConcurrentWriter = @This();

interface: std.Io.Writer,
target: *std.Io.Writer,
mutex: *std.Io.Mutex,
io: std.Io,

pub fn init(target: *std.Io.Writer, mutex: *std.Io.Mutex, io: std.Io) ConcurrentWriter {
    return .{
        .interface = .{ .vtable = &vtable, .buffer = &.{} },
        .target = target,
        .mutex = mutex,
        .io = io,
    };
}

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *ConcurrentWriter = @fieldParentPtr("interface", writer);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (data[0 .. data.len - 1]) |bytes| try self.target.writeAll(bytes);
    const repeated = data[data.len - 1];
    for (0..splat) |_| try self.target.writeAll(repeated);
    return std.Io.Writer.countSplat(data, splat);
}

fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const self: *ConcurrentWriter = @fieldParentPtr("interface", writer);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.target.flush();
}

test "shared lock protects concurrent writes and preserves splat output" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var mutex: std.Io.Mutex = .init;
    var first = ConcurrentWriter.init(&output.writer, &mutex, std.testing.io);
    var second = ConcurrentWriter.init(&output.writer, &mutex, std.testing.io);
    _ = try first.interface.writeSplat(&.{"ab"}, 3);

    var group: std.Io.Group = .init;
    errdefer group.cancel(std.testing.io);
    try group.concurrent(std.testing.io, writeMany, .{ &first.interface, "A" });
    try group.concurrent(std.testing.io, writeMany, .{ &second.interface, "B" });
    try group.await(std.testing.io);

    const bytes = output.written();
    try std.testing.expectEqualStrings("ababab", bytes[0..6]);
    try std.testing.expectEqual(@as(usize, 206), bytes.len);
    var a_count: usize = 0;
    var b_count: usize = 0;
    for (bytes[6..]) |byte| switch (byte) {
        'A' => a_count += 1,
        'B' => b_count += 1,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 100), a_count);
    try std.testing.expectEqual(@as(usize, 100), b_count);
}

fn writeMany(writer: *std.Io.Writer, bytes: []const u8) std.Io.Cancelable!void {
    for (0..100) |_| writer.writeAll(bytes) catch unreachable;
}
