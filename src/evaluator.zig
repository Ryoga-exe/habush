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

    // TODO:
    // for (tree.root.commands.items) |command| {
    // }
    const command = tree.root.commands.items[0];
    for (command.argv.items) |arg| {
        const pos_start = buffer.items.len;
        const start = tree.tokens.items(.start)[arg];
        for (start..tree.source.len) |i| {
            if (std.ascii.isWhitespace(tree.source[i])) {
                break;
            }
            try buffer.append(tree.source[i]);
        }
        try positions.append(.{ .start = pos_start, .end = buffer.items.len });
        try buffer.append(0);
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
