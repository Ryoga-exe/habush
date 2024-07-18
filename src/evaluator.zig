const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig");
const initial_buffer_size = 128;
const initial_args_size = 4;

const Evaluator = @This();

const builtins = struct {
    usingnamespace @import("builtins/cd.zig");
    usingnamespace @import("builtins/exit.zig");
};

// TODO: change anyerror to builtins.Error
const Error = anyerror || Allocator.Error || std.posix.ForkError || std.posix.ExecveError;

// pub fn eval(allocator: Allocator, command: *Command) Error!u32 {
pub fn eval(allocator: Allocator, lexer: *Lexer) Error!u32 {
    var builtinCommands = std.StringHashMap(*const fn ([*:null]const ?[*:0]const u8) anyerror!void).init(allocator);
    defer builtinCommands.deinit();

    try builtinCommands.put("cd", builtins.cd);
    try builtinCommands.put("exit", builtins.exit);

    var buffer = std.ArrayList(u8).initCapacity(allocator, initial_buffer_size) catch |err| {
        return err;
    };
    const Position = struct { begin: usize, len: usize };
    var positions = std.ArrayList(Position).initCapacity(allocator, initial_args_size) catch |err| {
        return err;
    };

    while (true) {
        var token = try lexer.nextToken(allocator);
        defer token.deinit();

        if (token.token_type == .eof) {
            break;
        }

        if (token.literal) |lit| {
            try positions.append(.{ .begin = buffer.items.len, .len = lit.len });
            try buffer.appendSlice(lit);
            try buffer.append(0);
        }
    }

    const args_len = positions.items.len;
    var args_ptrs = try allocator.allocSentinel(?[*:0]u8, args_len + 1, null);
    defer allocator.free(args_ptrs);

    for (positions.items, 0..) |pos, index| {
        const begin = pos.begin;
        const end = begin + pos.len;
        args_ptrs[index] = @as(*align(1) const [*:0]u8, @ptrCast(&buffer.items[begin..end :0])).*;
    }
    args_ptrs[args_len] = null;

    const command = std.mem.span(args_ptrs[0].?);
    if (builtinCommands.get(command)) |builtin_command| {
        builtin_command(args_ptrs) catch |err| {
            return err;
        };
        return 0;
    }

    const fork_pid = std.posix.fork() catch |err| {
        return err;
    };

    if (fork_pid == 0) {
        // child
        const env = [_:null]?[*:0]u8{null};

        const result = std.posix.execvpeZ(args_ptrs[0].?, args_ptrs, &env);

        return result;
    } else {
        // parent
        const wait_result = std.posix.waitpid(fork_pid, 0);

        return wait_result.status;
    }
}
