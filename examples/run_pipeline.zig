//! Structured external pipeline without parsing shell source.
//!
//! Example:
//! zig build run-pipeline -- /usr/bin/printf "hello\n" --pipe /usr/bin/wc -c

const std = @import("std");
const exec = @import("habush-exec");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var stderr_file = std.Io.File.stderr().writerStreaming(io, &.{});
    const stderr = &stderr_file.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try printUsage(stderr);
        return 2;
    }

    var system: exec.Host.System = .{ .gpa = gpa, .io = io };
    defer system.deinit();
    const host = system.host();
    const cwd = try host.resolveWorkingDirectory(gpa, .{ .current = null, .path = "." });
    defer gpa.free(cwd);

    var plans: std.ArrayList(exec.CommandPlan) = .empty;
    var group_start: usize = 1;
    for (1..args.len + 1) |index| {
        if (index != args.len and !std.mem.eql(u8, args[index], "--pipe")) continue;
        if (group_start == index) {
            try printUsage(stderr);
            return 2;
        }

        const argv = try arena.alloc([]const u8, index - group_start);
        for (args[group_start..index], argv) |argument, *destination| destination.* = argument;
        try plans.append(arena, .{
            .executable = argv[0],
            .argv = argv,
            .environment = .{ .replace = &.{} },
            .cwd = .{ .path = cwd },
        });
        group_start = index + 1;
    }

    var result = try exec.Pipeline.run(gpa, host, plans.items);
    defer result.deinit(gpa);
    return switch (result) {
        .completed => |stages| terminationStatus(stages[stages.len - 1].termination),
        .failed => |failure| {
            switch (failure.reason) {
                .file_action => |action| try stderr.print(
                    "run-pipeline: stage {d}: file action {d}: {s}\n",
                    .{ failure.stage + 1, action.action_index, @tagName(action.reason) },
                ),
                else => try stderr.print(
                    "run-pipeline: stage {d}: {s}\n",
                    .{ failure.stage + 1, @tagName(failure.reason) },
                ),
            }
            return if (failure.reason == .command_not_found) 127 else 126;
        },
    };
}

fn terminationStatus(termination: exec.Host.Termination) u8 {
    return switch (termination) {
        .exited => |status| status,
        .signal => |number| @truncate(number +% 128),
        .stopped, .unknown => 1,
        .spawn_failed => |failure| switch (failure) {
            .command_not_found => 127,
            .file_action => 1,
            else => 126,
        },
    };
}

fn printUsage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: run-pipeline executable [args ...] [--pipe executable [args ...]]...\n",
    );
}
