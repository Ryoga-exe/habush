//! One Core Wasm module providing a command and its argument completion.
const std = @import("std");

extern "habush" fn write(descriptor: u32, pointer: [*]const u8, length: u32) i32;
extern "habush" fn read(descriptor: u32, pointer: [*]u8, length: u32) u32;
extern "habush" fn read_file(path: [*]const u8, length: u32, output_buffer: [*]u8, capacity: u32) i32;

var request_buffer: [64 * 1024]u8 = undefined;
var reply_buffer: [4096]u8 = undefined;
const status = [_]u8{7};
const choices = [_][]const u8{ "first choice", "second '$(missing)" };

export fn habush_version() u32 {
    return 0;
}

export fn habush_alloc(length: u32) u32 {
    if (length > request_buffer.len) @trap();
    return @intFromPtr(&request_buffer);
}

fn reply(bytes: []const u8) u64 {
    return @as(u64, bytes.len) << 32 | @as(u64, @intFromPtr(bytes.ptr));
}

fn take(reader: *std.Io.Reader) []const u8 {
    return reader.take(reader.takeInt(u32, .little) catch @trap()) catch @trap();
}

fn output(bytes: []const u8) void {
    if (write(1, bytes.ptr, @intCast(bytes.len)) < 0) @trap();
}

export fn command(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    const count = reader.takeInt(u32, .little) catch @trap();
    if (count == 0) @trap();
    _ = take(&reader);
    for (1..count) |_| {
        const arg = take(&reader);
        if (std.mem.eql(u8, arg, "fail")) @trap();
        if (std.mem.eql(u8, arg, "loop")) {
            output("RUNNING\n");
            while (true) {}
        }
        if (std.mem.eql(u8, arg, "read")) {
            const n = read(0, &reply_buffer, reply_buffer.len);
            output("INPUT:");
            output(reply_buffer[0..n]);
            continue;
        }
        output("VALUE:");
        output(arg);
        output("\n");
    }
    if (reader.bufferedLen() != 0) @trap();
    return reply(&status);
}

export fn complete(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) == 0) @trap();
    const prefix = take(&reader);
    if (std.mem.eql(u8, prefix, "fail")) @trap();
    var offset: usize = 4;
    var count: u32 = 0;
    for (choices) |choice| {
        if (!std.mem.startsWith(u8, choice, prefix)) continue;
        std.mem.writeInt(u32, reply_buffer[offset..][0..4], @intCast(choice.len), .little);
        offset += 4;
        @memcpy(reply_buffer[offset..][0..choice.len], choice);
        offset += choice.len;
        count += 1;
    }
    std.mem.writeInt(u32, reply_buffer[0..4], count, .little);
    return reply(reply_buffer[0..offset]);
}

export fn file(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) != 2) @trap();
    _ = take(&reader);
    const path = take(&reader);
    if (reader.bufferedLen() != 0) @trap();
    const size = read_file(path.ptr, @intCast(path.len), &reply_buffer, reply_buffer.len);
    if (size < 0) {
        output(switch (size) {
            -1 => "file not found\n",
            -2 => "not a regular file\n",
            else => "permission denied\n",
        });
        return reply(&.{1});
    }
    output(reply_buffer[0..@intCast(size)]);
    return reply(&status);
}

export fn diagnose(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) != 2) @trap();
    const revision = take(&reader);
    const source = take(&reader);
    if (reader.bufferedLen() != 0) @trap();
    const position = std.mem.indexOf(u8, source, "NOTE");
    var start: [20]u8 = undefined;
    var end: [20]u8 = undefined;
    const fields: []const []const u8 = if (position) |index| &.{
        revision,
        std.fmt.bufPrint(&start, "{d}", .{index}) catch @trap(),
        std.fmt.bufPrint(&end, "{d}", .{index + 4}) catch @trap(),
        "warning",
        "demo diagnostic: NOTE\x1b",
    } else &.{revision};
    std.mem.writeInt(u32, reply_buffer[0..4], @intCast(fields.len), .little);
    var offset: usize = 4;
    for (fields) |value| {
        std.mem.writeInt(u32, reply_buffer[offset..][0..4], @intCast(value.len), .little);
        offset += 4;
        @memcpy(reply_buffer[offset..][0..value.len], value);
        offset += value.len;
    }
    return reply(reply_buffer[0..offset]);
}
