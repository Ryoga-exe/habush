//! A small, stateless Wasm theme. No imports or operating-system access.
const std = @import("std");
var request_buffer: [64 * 1024]u8 = undefined;
var reply_buffer: [8192]u8 = undefined;

export fn habush_version() u32 {
    return 0;
}
export fn habush_alloc(length: u32) u32 {
    if (length > request_buffer.len) @trap();
    return @intFromPtr(&request_buffer);
}

fn take(reader: *std.Io.Reader) []const u8 {
    return reader.take(reader.takeInt(u32, .little) catch @trap()) catch @trap();
}

fn field(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeInt(u32, @intCast(bytes.len), .little) catch @trap();
    writer.writeAll(bytes) catch @trap();
}

export fn prompt(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) != 2) @trap();
    const cwd = take(&reader);
    const code = take(&reader);
    const status = std.fmt.parseInt(u8, code, 10) catch @trap();
    if (reader.bufferedLen() != 0) @trap();
    var writer: std.Io.Writer = .fixed(&reply_buffer);
    writer.writeInt(u32, 4, .little) catch @trap();
    field(&writer, "701"); // Cyan, default background, bold.
    field(&writer, if (cwd.len == 0) "." else cwd);
    field(&writer, if (status == 0) "300" else "200");
    var tail: [24]u8 = undefined;
    field(&writer, std.fmt.bufPrint(&tail, " [{d}] ❯ ", .{status}) catch @trap());
    return @as(u64, writer.end) << 32 | @as(u64, @intFromPtr(&reply_buffer));
}
