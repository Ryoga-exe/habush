//! ABI v0 byte lists: little-endian u32 count, then u32 length + raw bytes.
const std = @import("std");
const Host = @import("Host.zig");

pub fn encode(gpa: std.mem.Allocator, groups: []const []const []const u8, max_bytes: u32) Host.Error![]u8 {
    var count: usize = 0;
    var size: usize = 4;
    for (groups) |group| {
        count = std.math.add(usize, count, group.len) catch return error.LimitExceeded;
        for (group) |bytes| {
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidRequest;
            size = std.math.add(usize, size, 4) catch return error.LimitExceeded;
            size = std.math.add(usize, size, bytes.len) catch return error.LimitExceeded;
            if (size > max_bytes) return error.LimitExceeded;
        }
    }
    if (size > max_bytes or count > std.math.maxInt(u32)) return error.LimitExceeded;
    const output = try gpa.alloc(u8, size);
    std.mem.writeInt(u32, output[0..4], @intCast(count), .little);
    var offset: usize = 4;
    for (groups) |group| for (group) |bytes| {
        std.mem.writeInt(u32, output[offset..][0..4], @intCast(bytes.len), .little);
        offset += 4;
        @memcpy(output[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    };
    return output;
}

/// The returned index owns only the slice table; values borrow `bytes`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, max_count: u32) Host.Error![][]const u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    const count = reader.takeInt(u32, .little) catch return error.InvalidResponse;
    if (count > max_count) return error.LimitExceeded;
    if (count > reader.bufferedLen() / 4) return error.InvalidResponse;
    const values = try gpa.alloc([]const u8, count);
    errdefer gpa.free(values);
    for (values) |*value| {
        const length = reader.takeInt(u32, .little) catch return error.InvalidResponse;
        value.* = reader.take(length) catch return error.InvalidResponse;
        if (std.mem.indexOfScalar(u8, value.*, 0) != null) return error.InvalidResponse;
    }
    if (reader.bufferedLen() != 0) return error.InvalidResponse;
    return values;
}

test "byte-list encoding is bounded and decoding rejects malformed candidates" {
    const gpa = std.testing.allocator;
    const encoded = try encode(gpa, &.{&.{"\xff"}}, 9);
    defer gpa.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 1, 0, 0, 0, 255 }, encoded);
    const decoded = try decode(gpa, encoded, 1);
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings("\xff", decoded[0]);
    try std.testing.expectError(error.LimitExceeded, encode(gpa, &.{&.{"x"}}, 8));
    try std.testing.expectError(error.InvalidRequest, encode(gpa, &.{&.{"\x00"}}, 9));
    for ([_][]const u8{
        "",
        "\x01\x00\x00\x00",
        "\x01\x00\x00\x00\x02\x00\x00\x00x",
        "\x00\x00\x00\x00trailing",
        "\x01\x00\x00\x00\x01\x00\x00\x00\x00",
    }) |bytes| try std.testing.expectError(error.InvalidResponse, decode(gpa, bytes, 1));
}
