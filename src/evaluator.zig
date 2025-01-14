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

const BuiltinComandFunc = *const fn ([*:null]const ?[*:0]const u8, u8) anyerror!void;

const builtinCommands = std.StaticStringMap(BuiltinComandFunc).initComptime([_]struct {
    []const u8,
    BuiltinComandFunc,
}{
    .{ "cd", builtins.cd },
    .{ "exit", builtins.exit },
});

const FdManager = struct {
    // TODO: use hashmap
    backup: [10]?std.posix.fd_t,
    pub fn init() FdManager {
        return FdManager{
            .backup = [_]?std.posix.fd_t{null} ** 10,
        };
    }
    pub fn reset(self: *FdManager) !void {
        for (self.backup, 0..) |backup, new_fd| {
            if (backup) |fd| {
                try std.posix.dup2(fd, @intCast(new_fd));
                std.posix.close(fd);
            }
        }
        self.backup = [_]?std.posix.fd_t{null} ** 10;
    }
    pub fn dup2(self: *FdManager, old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
        if (self.backup[@intCast(new_fd)] != null) {
            self.backup[@intCast(new_fd)] = try std.posix.dup(new_fd);
        }
        try std.posix.dup2(old_fd, new_fd);
    }
    pub fn redirect(self: *FdManager, allocator: Allocator, tree: *Ast, redirection: Ast.Redirection) !void {
        switch (redirection) {
            .in => |in| {
                var input_buffer = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer input_buffer.deinit();

                const input_buffer_writer = input_buffer.writer();
                try writeWord(tree, in.target, input_buffer_writer);

                const target_fd = std.posix.STDIN_FILENO;
                const input_fd = try std.posix.open(input_buffer.items, .{
                    .ACCMODE = .RDONLY,
                }, 0o666);
                defer std.posix.close(input_fd);
                try self.dup2(input_fd, target_fd);
            },
            .out => |out| {
                var output_buffer = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer output_buffer.deinit();

                const output_buffer_writer = output_buffer.writer();
                try writeWord(tree, out.target, output_buffer_writer);

                const target_fd = std.posix.STDOUT_FILENO;
                const output_fd = try std.posix.open(output_buffer.items, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .TRUNC = true,
                }, 0o666);
                defer std.posix.close(output_fd);
                try self.dup2(output_fd, target_fd);
            },
            .out_append => |out_append| {
                var output_buffer = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer output_buffer.deinit();

                const output_buffer_writer = output_buffer.writer();
                try writeWord(tree, out_append.target, output_buffer_writer);

                const target_fd = std.posix.STDOUT_FILENO;
                const output_fd = try std.posix.open(output_buffer.items, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .APPEND = true,
                }, 0o666);
                defer std.posix.close(output_fd);
                try self.dup2(output_fd, target_fd);
            },
            // else => {
            //     // not implemented yet.
            //     std.debug.panic("not implemented", .{});
            // },
        }
    }
};

allocator: Allocator,
last_status: u8,

pub fn init(allocator: Allocator) Evaluator {
    return Evaluator{
        .allocator = allocator,
        .last_status = 0,
    };
}

pub fn eval(self: *Evaluator, tree: *Ast) Evaluator.Error!u8 {
    var buffer = try std.ArrayList(u8).initCapacity(self.allocator, initial_buffer_size);
    defer buffer.deinit();
    const Position = struct {
        start: usize,
        end: usize,
    };
    var positions = try std.ArrayList(Position).initCapacity(self.allocator, initial_args_size);
    defer positions.deinit();

    const writer = buffer.writer();

    for (tree.root.commands.items) |command| {
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

        // FIX: panic if args_ptrs[0] is not exist
        const cmd = std.mem.span(args_ptrs[0].?);
        if (builtinCommands.get(cmd)) |builtin_command| {
            var manager = FdManager.init();
            for (command.redirection.items) |redirection| {
                try manager.redirect(self.allocator, tree, redirection);
            }
            // TODO: return status code depends on the error type
            try builtin_command(args_ptrs, self.last_status);
            try manager.reset();
            return 0;
        }

        const fork_pid = try std.posix.fork();

        if (fork_pid == 0) {
            // child
            var manager = FdManager.init();
            for (command.redirection.items) |redirection| {
                try manager.redirect(self.allocator, tree, redirection);
            }

            const env = [_:null]?[*:0]u8{null};

            const result = std.posix.execvpeZ(args_ptrs[0].?, args_ptrs, &env);

            return result;
        } else {
            // parent
            const wait_result = std.posix.waitpid(fork_pid, 0);

            self.last_status = std.posix.W.EXITSTATUS(wait_result.status);
        }

        buffer.clearRetainingCapacity();
        positions.clearRetainingCapacity();
    }

    return self.last_status;
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
