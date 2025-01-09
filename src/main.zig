const std = @import("std");
const buffer_initial_size = 1024;

const Ast = @import("ast.zig");
const Evaluator = @import("evaluator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var buffered_reader = std.io.bufferedReader(std.io.getStdIn().reader());
    var buffered_writer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdin = buffered_reader.reader();
    const stdout = buffered_writer.writer();

    var buffer = try std.ArrayList(u8).initCapacity(allocator, buffer_initial_size);
    defer buffer.deinit();

    var evaluator = Evaluator.init(allocator);

    while (true) {
        // print prompt
        try stdout.print("> ", .{});
        try buffered_writer.flush();

        buffer.clearRetainingCapacity();
        if (buffer.items.len > buffer_initial_size) {
            buffer.shrinkAndFree(buffer_initial_size);
        }

        const input = input: {
            stdin.streamUntilDelimiter(buffer.writer(), '\n', null) catch |err| switch (err) {
                error.EndOfStream => if (buffer.items.len == 0) {
                    // EOF
                    try stdout.print("\n", .{});
                    try buffered_writer.flush();
                    return;
                },
                else => |e| {
                    return e;
                },
            };
            const length = buffer.items.len;
            break :input buffer.items[0..length];
        };

        if (input.len == 0) {
            continue;
        }

        var ast = try Ast.parse(allocator, input);

        const status = evaluator.eval(&ast) catch |err| {
            try stdout.print("ERROR: {}\n", .{err});
            try buffered_writer.flush();
            return;
        };

        if (status != 0) {
            try stdout.print("Command returned {}.\n", .{status});
            try buffered_writer.flush();
        }
    }
}
