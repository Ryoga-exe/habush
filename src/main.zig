const std = @import("std");
const habush = @import("habush");
const Io = std.Io;
const platform = @import("platform.zig");

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
        try platform.ignoreInteractiveInterrupt();
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

            const source = try readLineAlloc(self.stdin, self.allocator) orelse {
                if (self.interactive) {
                    try Io.File.stderr().writeStreamingAll(self.io, "\n");
                }
                break;
            };
            defer self.allocator.free(source);

            if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) {
                continue;
            }

            switch (try self.handleInput(source)) {
                .@"continue" => continue,
                .exit => break,
            }
        }
    }

    fn printPrompt(self: *Shell) !void {
        try Io.File.stderr().writeStreamingAll(self.io, "habush> ");
    }

    fn handleInput(self: *Shell, source: [:0]const u8) !LoopAction {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        if (std.mem.eql(u8, std.mem.trim(u8, source, &std.ascii.whitespace), "exit")) {
            return .exit;
        }

        var tree = try habush.Ast.parse(allocator, source);
        defer tree.deinit(allocator);

        var dump: Io.Writer.Allocating = .init(allocator);
        defer dump.deinit();
        try tree.dump(&dump.writer);
        try Io.File.stdout().writeStreamingAll(self.io, dump.written());

        return .@"continue";
    }
};

fn readLineAlloc(reader: *Io.Reader, allocator: std.mem.Allocator) !?[:0]u8 {
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

    const written = out.written();

    // CRLF
    if (written.len > 0 and written[written.len - 1] == '\r') {
        out.shrinkRetainingCapacity(written.len - 1);
    }

    return try out.toOwnedSliceSentinel(0);
}
