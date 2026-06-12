const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const sigint_ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sigint_ignore, null);

    const io = init.io;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (true) {
        try Io.File.stderr().writeStreamingAll(io, "habush> ");

        const line = try readLineAlloc(stdin_reader, gpa) orelse {
            try Io.File.stderr().writeStreamingAll(io, "\n");
            break;
        };
        defer gpa.free(line);

        const input = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (input.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, input, "exit")) {
            break;
        }

        std.log.info("input: {s}", .{input});
    }
}

fn readLineAlloc(reader: *Io.Reader, allocator: std.mem.Allocator) !?[]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const n = try reader.streamDelimiterEnding(&out.writer, '\n');

    const found_newline = reader.bufferedLen() > 0;
    if (found_newline) {
        // consume new line
        reader.toss(1);
    } else if (n == 0) {
        // EOF
        out.deinit();
        return null;
    }

    const line = out.written();

    // CRLF
    if (line.len > 0 and line[line.len - 1] == '\r') {
        out.shrinkRetainingCapacity(line.len - 1);
    }

    return try out.toOwnedSlice();
}
