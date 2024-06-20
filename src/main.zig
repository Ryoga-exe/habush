const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer_initial_size = 1024;
const max_args = 128;

const builtins = struct {
    usingnamespace @import("builtins/cd.zig");
    usingnamespace @import("builtins/exit.zig");
};

const Lexer = struct {
    const Self = @This();

    input: []const u8,
    position: usize,
    read_position: usize,
    ch: u8,
    buffer: std.ArrayList(u8),

    pub fn init(input: []const u8, allocator: Allocator) !Self {
        var self = Self{
            .input = input,
            .position = 0,
            .read_position = 0,
            .ch = 0,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, input.len),
        };
        self.readChar();
        return self;
    }
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }
    pub fn lex(self: *Self) ![max_args:null]?[*:0]u8 {
        var index: usize = 0;
        var args_ptrs: [max_args:null]?[*:0]u8 = undefined;

        while (self.ch != 0) {
            self.skipWhitespace();

            switch (self.ch) {
                '\'' => {},
                '\"' => {},
                0 => {},
                else => {
                    const begin = self.buffer.items.len;
                    try self.lexToken();
                    try self.buffer.append(0);
                    const end = self.buffer.items.len - 1;
                    args_ptrs[index] = @as(*align(1) const [*:0]u8, @ptrCast(&self.buffer.items[begin..end :0])).*;
                },
            }
            self.readChar();
            index += 1;
        }
        args_ptrs[index] = null;
        return args_ptrs;
    }

    fn readChar(self: *Self) void {
        if (self.read_position < self.input.len) {
            self.ch = self.input[self.read_position];
        } else {
            self.ch = 0;
        }
        self.position = self.read_position;
        self.read_position += 1;
    }
    fn peekChar(self: Self) u8 {
        if (self.read_position < self.input.len) {
            return self.input[self.read_position];
        } else {
            return 0;
        }
    }
    fn skipWhitespace(self: *Self) void {
        while (std.ascii.isWhitespace(self.ch)) {
            self.readChar();
        }
    }
    fn lexToken(self: *Self) !void {
        while (self.ch != 0 and !std.ascii.isWhitespace(self.ch)) {
            switch (self.ch) {
                '\\' => {
                    if (self.peekChar() == 0) {
                        // Error
                    } else {
                        self.readChar();
                        try self.buffer.append(self.ch);
                    }
                },
                0 => {},
                else => {
                    try self.buffer.append(self.ch);
                },
            }
            self.readChar();
        }
    }
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
            try buffer.append(0);
            break :input buffer.items[0..length];
        };

        if (input.len == 0) {
            continue;
        }

        var args_ptrs: [max_args:null]?[*:0]u8 = undefined;

        var n: usize = 0;
        var ofs: usize = 0;
        for (0..input.len + 1) |i| {
            if (buffer.items[i] == 0 or std.ascii.isWhitespace(buffer.items[i])) {
                buffer.items[i] = 0;
                args_ptrs[n] = @as(*align(1) const [*:0]u8, @ptrCast(&buffer.items[ofs..i :0])).*;
                n += 1;
                ofs = i + 1;
            }
        }
        args_ptrs[n] = null;

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
