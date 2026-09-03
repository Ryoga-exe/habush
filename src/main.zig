const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const interactive = try Io.File.stdin().isTty(io) and try Io.File.stderr().isTty(io);

    if (interactive) {
        ignoreSigint();
    }

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);

    var shell: Shell = .{
        .io = io,
        .allocator = gpa,
        .stdin = &stdin_file_reader.interface,
        .interactive = interactive,
    };

    try shell.run();
}

const Shell = struct {
    io: Io,
    allocator: std.mem.Allocator,
    stdin: *Io.Reader,
    interactive: bool,

    const LoopAction = enum {
        @"continue",
        exit,
    };

    fn run(self: *Shell) !void {
        while (true) {
            if (self.interactive) {
                try self.printPrompt();
            }

            const line = try readLineAlloc(self.stdin, self.allocator) orelse {
                if (self.interactive) {
                    try Io.File.stderr().writeStreamingAll(self.io, "\n");
                }
                break;
            };
            defer self.allocator.free(line);

            const input = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (input.len == 0) {
                continue;
            }

            switch (try self.handleInput(input)) {
                .@"continue" => continue,
                .exit => break,
            }
        }
    }

    fn printPrompt(self: *Shell) !void {
        try Io.File.stderr().writeStreamingAll(self.io, "habush> ");
    }

    fn handleInput(self: *Shell, input: []const u8) !LoopAction {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        _ = allocator; // autofix

        // tokenizer
        // parser

        if (std.mem.eql(u8, input, "exit")) {
            return .exit;
        }

        std.log.info("input: {s}", .{input});
        return .@"continue";
    }
};

test {
    _ = @import("tokenizer.zig");
    _ = @import("word.zig");
    _ = @import("heredoc.zig");
    _ = @import("Ast.zig");
    _ = @import("Parse.zig");
}

fn ignoreSigint() void {
    const sigint_ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sigint_ignore, null);
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
