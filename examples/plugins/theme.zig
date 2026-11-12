//! A stateless theme; only plugin-local settings, no operating-system access.
const std = @import("std");
extern "habush" fn option(key: [*]const u8, key_length: u32, output: [*]u8, capacity: u32) i32;
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

fn setting(key: []const u8, buffer: []u8, fallback: []const u8) []const u8 {
    const length = option(key.ptr, @intCast(key.len), buffer.ptr, @intCast(buffer.len));
    return if (length < 0) fallback else buffer[0..@intCast(length)];
}

fn color(key: []const u8, fallback: []const u8) u8 {
    var buffer: [16]u8 = undefined;
    const value = setting(key, &buffer, fallback);
    for ([_][]const u8{ "default", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }, 0..) |name, index| {
        if (std.mem.eql(u8, name, value)) return '0' + @as(u8, @intCast(index));
    }
    @trap();
}

export fn prompt(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) != 8) @trap();
    if (!std.mem.eql(u8, take(&reader), "1")) @trap();
    const cwd = take(&reader);
    const code = take(&reader);
    const status = std.fmt.parseInt(u8, code, 10) catch @trap();
    const duration = take(&reader);
    const jobs = take(&reader);
    _ = take(&reader); // Repository root; this theme only needs the name.
    const branch = take(&reader);
    const commit = take(&reader);
    if (reader.bufferedLen() != 0) @trap();
    var writer: std.Io.Writer = .fixed(&reply_buffer);
    writer.writeInt(u32, 6, .little) catch @trap();
    field(&writer, &.{ color("cwd_color", "cyan"), '0', '1' });
    const directory_name = std.fs.path.basename(cwd);
    field(&writer, if (cwd.len == 0) "." else if (directory_name.len == 0) cwd else directory_name);
    field(&writer, "000");
    var details: [1024]u8 = undefined;
    var detail: std.Io.Writer = .fixed(&details);
    if (duration.len != 0) detail.print(" {s}ms", .{duration}) catch @trap();
    if (!std.mem.eql(u8, jobs, "0")) detail.print(" jobs:{s}", .{jobs}) catch @trap();
    if (branch.len != 0) detail.print(" git:{s}", .{branch}) catch @trap() else if (commit.len != 0)
        detail.print(" git:{s}", .{commit[0..@min(commit.len, 8)]}) catch @trap();
    field(&writer, details[0..detail.end]);
    field(&writer, &.{ if (status == 0) color("success_color", "green") else color("failure_color", "red"), '0', '0' });
    var symbol_buffer: [1024]u8 = undefined;
    const symbol = setting("symbol", &symbol_buffer, "❯");
    var tail: [1040]u8 = undefined;
    field(&writer, std.fmt.bufPrint(&tail, " [{d}] {s} ", .{ status, symbol }) catch @trap());
    return @as(u64, writer.end) << 32 | @as(u64, @intFromPtr(&reply_buffer));
}
