//! Executes Habush HIR through a `Host`.

const std = @import("std");
const Executor = @This();
const Hir = @import("Hir.zig");
const Host = @import("Host.zig");

gpa: std.mem.Allocator,
host: Host,

pub const Error = Host.Error || error{
    UnsupportedInstruction,
    UnexpectedTermination,
};

pub fn init(gpa: std.mem.Allocator, host: Host) Executor {
    return .{ .gpa = gpa, .host = host };
}

/// Executes a complete HIR unit and returns its shell status.
pub fn execute(executor: Executor, hir: Hir) Error!u8 {
    const root = hir.root() orelse return 0;
    return executor.executeInstruction(hir, root);
}

fn executeInstruction(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!u8 {
    return switch (hir.instructionTag(index)) {
        .list => executor.executeList(hir, index),
        .simple_command => executor.executeSimpleCommand(hir, index),
        else => error.UnsupportedInstruction,
    };
}

fn executeList(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!u8 {
    var status: u8 = 0;
    for (0..hir.listItemCount(index)) |item_index| {
        const item = hir.listItem(index, item_index);
        if (item.separator == .background) return error.UnsupportedInstruction;
        status = try executor.executeInstruction(hir, item.command);
    }
    return status;
}

fn executeSimpleCommand(executor: Executor, hir: Hir, index: Hir.Inst.Index) Error!u8 {
    var arena = std.heap.ArenaAllocator.init(executor.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    for (hir.simpleCommandParts(index)) |part| {
        if (hir.instructionTag(part) != .word) return error.UnsupportedInstruction;
        try argv.append(allocator, try expandStaticWord(allocator, hir, part));
    }
    if (argv.items.len == 0) return error.UnsupportedInstruction;

    const process = try executor.host.spawn(.{ .argv = argv.items });
    return terminationStatus(try executor.host.wait(process));
}

fn expandStaticWord(
    allocator: std.mem.Allocator,
    hir: Hir,
    index: Hir.Inst.Index,
) Error![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (hir.wordParts(index), 0..) |part, part_index| {
        const tag = hir.instructionTag(part);
        const value = hir.wordPart(part);
        switch (tag) {
            .literal => {
                // These require expansion rather than simple quote removal.
                if (std.mem.indexOfAny(u8, value, "*?[") != null or
                    (part_index == 0 and std.mem.startsWith(u8, value, "~")))
                {
                    return error.UnsupportedInstruction;
                }
                try bytes.appendSlice(allocator, value);
            },
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            => try bytes.appendSlice(allocator, value),
            else => return error.UnsupportedInstruction,
        }
    }
    return bytes.toOwnedSlice(allocator);
}

fn terminationStatus(termination: Host.Termination) Error!u8 {
    return switch (termination) {
        .exited => |status| status,
        .signal => |signal| status: {
            const capped_signal: u32 = @min(signal, 127);
            const status: u32 = 128 + capped_signal;
            break :status @intCast(status);
        },
        .stopped, .unknown => error.UnexpectedTermination,
    };
}

test {
    _ = @import("executor_test.zig");
    std.testing.refAllDecls(@This());
}
