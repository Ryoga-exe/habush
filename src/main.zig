const std = @import("std");
const buffer_initial_size = 1024;

const Lexer = @import("lexer.zig");

const builtins = struct {
    usingnamespace @import("builtins/cd.zig");
    usingnamespace @import("builtins/exit.zig");
};

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

    var builtinCommands = std.StringHashMap(*const fn ([*:null]const ?[*:0]const u8) anyerror!void).init(allocator);
    defer builtinCommands.deinit();

    try builtinCommands.put("cd", builtins.cd);
    try builtinCommands.put("exit", builtins.exit);

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

        var lexer = try Lexer.init(input, allocator);
        defer lexer.deinit();

        const args_ptrs = try lexer.lex();

        const command = std.mem.span(args_ptrs[0].?);
        if (builtinCommands.get(command)) |builtin_command| {
            builtin_command(&args_ptrs) catch |err| {
                try stdout.print("ERROR: {}\n", .{err});
            };
            continue;
        }

        const fork_pid = try std.posix.fork();
        if (fork_pid == 0) {
            // child
            const env = [_:null]?[*:0]u8{null};

            const result = std.posix.execvpeZ(args_ptrs[0].?, &args_ptrs, &env);

            try stdout.print("ERROR: {}\n", .{result});
            try buffered_writer.flush();
            return;
        } else {
            // parent
            const wait_result = std.posix.waitpid(fork_pid, 0);

            if (wait_result.status != 0) {
                try stdout.print("Command returned {}.\n", .{wait_result.status});
                try buffered_writer.flush();
            }
        }
    }
}
