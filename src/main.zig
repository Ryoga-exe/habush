const std = @import("std");
const Io = std.Io;
const buffer_initial_size = 1024;

const Ast = @import("ast.zig");
const Evaluator = @import("evaluator.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var buffer = try Io.Writer.Allocating.initCapacity(gpa, buffer_initial_size);
    defer buffer.deinit();
    const buffer_writer = &buffer.writer;

    var evaluator = Evaluator.init(gpa);

    while (true) {
        // print prompt
        try stdout_writer.print("habush> ", .{});
        try stdout_writer.flush();

        // buffer.clearRetainingCapacity();
        // if (buffer.items.len > buffer_initial_size) {
        //     buffer.shrinkAndFree(gpa, buffer_initial_size);
        // }

        const input = input: {
            _ = stdin_reader.streamDelimiter(buffer_writer, '\n') catch |err| switch (err) {
                error.EndOfStream => if (buffer.written().len == 0) {
                    // EOF
                    try stdout_writer.print("\n", .{});
                    try stdout_writer.flush();
                    return;
                },
                else => |e| {
                    return e;
                },
            };
            break :input buffer.written();
        };

        if (input.len == 0) {
            continue;
        }

        var ast = try Ast.parse(gpa, input);
        defer ast.deinit(gpa);

        const status = evaluator.eval(&ast) catch |err| {
            try stdout_writer.print("ERROR: {}\n", .{err});
            try stdout_writer.flush();
            return;
        };

        if (status != 0) {
            try stdout_writer.print("Command returned {}.\n", .{status});
            try stdout_writer.flush();
        }
    }
}
