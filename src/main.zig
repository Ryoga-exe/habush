const std = @import("std");
const buffer_size = 1024;
const max_args = 128;

pub fn main() !void {
    var buffered_reader = std.io.bufferedReader(std.io.getStdIn().reader());
    var buffered_writer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdin = buffered_reader.reader();
    const stdout = buffered_writer.writer();

    var buffer: [buffer_size]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});
        try buffered_writer.flush();
        const input = (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) orelse {
            try stdout.print("\n", .{});
            try buffered_writer.flush();
            return;
        };
        if (input.len == 0) {
            continue;
        }

        var args_ptrs: [max_args:null]?[*:0]u8 = undefined;

        var n: usize = 0;
        var ofs: usize = 0;
        for (0..input.len + 1) |i| {
            if (std.ascii.isWhitespace(buffer[i])) {
                buffer[i] = 0;
                args_ptrs[n] = @as(*align(1) const [*:0]u8, @ptrCast(&buffer[ofs..i :0])).*;
                n += 1;
                ofs = i + 1;
            }
        }
        args_ptrs[n] = null;

        const fork_pid = try std.posix.fork();
        if (fork_pid == 0) {
            // child
            const env = [_:null]?[*:0]u8{null};

            const result = std.posix.execvpeZ(args_ptrs[0].?, &args_ptrs, &env);

            try stdout.print("ERROR: {}\n", .{result});
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
