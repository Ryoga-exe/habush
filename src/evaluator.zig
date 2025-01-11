const std = @import("std");
const Allocator = std.mem.Allocator;
const initial_buffer_size = 128;
const initial_args_size = 4;
const Ast = @import("ast.zig");

const Evaluator = @This();

const builtins = struct {
    usingnamespace @import("builtins/cd.zig");
    usingnamespace @import("builtins/exit.zig");
};

// TODO: change anyerror to builtins.Error
const Error = anyerror || Allocator.Error || std.posix.ForkError || std.posix.ExecveError;

const BuiltinComandFunc = *const fn ([*:null]const ?[*:0]const u8) anyerror!void;

const builtinCommands = std.StaticStringMap(BuiltinComandFunc).initComptime([_]struct {
    []const u8,
    BuiltinComandFunc,
}{
    .{ "cd", builtins.cd },
    .{ "exit", builtins.exit },
});

allocator: Allocator,

pub fn init(allocator: Allocator) Evaluator {
    return Evaluator{
        .allocator = allocator,
    };
}

pub fn eval(self: *Evaluator, tree: *Ast) Evaluator.Error!u32 {
    var buffer = std.ArrayList(u8).initCapacity(self.allocator, initial_buffer_size) catch |err| {
        return err;
    };
    defer buffer.deinit();
    const Position = struct {
        start: usize,
        end: usize,
    };
    var positions = std.ArrayList(Position).initCapacity(self.allocator, initial_args_size) catch |err| {
        return err;
    };
    defer positions.deinit();

    const writer = buffer.writer();

    // TODO:
    // for (tree.root.commands.items) |command| {}
    const command = tree.root.commands.items[0];
    for (command.argv.items) |arg| {
        const pos_start = buffer.items.len;
        try writeWord(tree, arg, writer);
        try positions.append(.{ .start = pos_start, .end = buffer.items.len });
        try writer.writeByte(0);
    }

    const args_len = positions.items.len;
    var args_ptrs = try self.allocator.allocSentinel(?[*:0]u8, args_len + 1, null);
    defer self.allocator.free(args_ptrs);

    for (positions.items, 0..) |pos, index| {
        args_ptrs[index] = @as(*align(1) const [*:0]u8, @ptrCast(&buffer.items[pos.start..pos.end :0])).*;
    }
    args_ptrs[args_len] = null;

    const cmd = std.mem.span(args_ptrs[0].?);
    if (builtinCommands.get(cmd)) |builtin_command| {
        builtin_command(args_ptrs) catch |err| {
            return err;
        };
        return 0;
    }

    const stdout_backup = backup: {
        if (command.redirection.items.len > 0) {
            break :backup std.posix.dup(std.posix.STDOUT_FILENO) catch |err| return err;
        } else {
            break :backup null;
        }
    };
    defer {
        if (stdout_backup) |backup| {
            std.posix.close(backup);
        }
    }

    if (command.redirection.items.len > 0) {
        // TODO:
        // for (command.redirection.items) |redirection| {}
        const redirection = command.redirection.items[0];
        switch (redirection) {
            .out => |out| {
                var output_buffer = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                defer output_buffer.deinit();

                const output_buffer_writer = output_buffer.writer();
                try writeWord(tree, out.target, output_buffer_writer);

                const target_fd = std.posix.STDOUT_FILENO;
                const output_fd = std.posix.open(output_buffer.items, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .TRUNC = true,
                }, 0o644) catch |err| {
                    return err;
                };
                defer std.posix.close(output_fd);
                std.posix.dup2(output_fd, target_fd) catch |err| {
                    return err;
                };
            },
            else => {
                // not implemented yet.
            },
        }
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

        if (stdout_backup) |backup| {
            std.posix.dup2(backup, std.posix.STDOUT_FILENO) catch |err| {
                return err;
            };
        }

        return wait_result.status;
    }
}

fn writeWord(tree: *Ast, token_index: Ast.TokenIndex, writer: anytype) !void {
    for (token_index..tree.tokens.len) |index| {
        const start = tree.tokens.items(.start)[index];
        const end = tree.tokens.items(.end)[index];
        switch (tree.tokens.items(.token_type)[index]) {
            .word,
            .number,
            .quoted_double,
            => {
                var state: enum {
                    start,
                    backslash,
                } = .start;
                for (tree.source[start..end]) |c| {
                    switch (state) {
                        .start => {
                            if (c == '\\') {
                                state = .backslash;
                                continue;
                            }
                            try writer.writeByte(c);
                        },
                        .backslash => {
                            try writer.writeByte(c);
                            state = .start;
                        },
                    }
                }
            },
            .quoted_single => {
                try writer.writeAll(tree.source[start..end]);
            },
            else => break,
        }
    }
}
