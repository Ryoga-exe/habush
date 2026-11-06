//! Explicit macOS process restrictions, with an empty child environment.
//! The target can itself be habush to evaluate a whole source unit inside
//! the restricted process. The caller selects a trusted worker executable.

const std = @import("std");
const exec = @import("habush-exec");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var diagnostics = std.Io.File.stderr().writerStreaming(init.io, &.{});
    if (args.len < 4) {
        try diagnostics.interface.writeAll("usage: run-sandbox /absolute/habush writable-directory /absolute/program [args ...]\n");
        return 2;
    }
    var system: exec.Host.System = .{
        .gpa = gpa,
        .io = init.io,
        .sandbox_backend = .{ .kind = .macos_seatbelt },
        .worker_executable = args[1],
    };
    defer system.deinit();
    const host = system.host();
    const cwd = try host.resolveWorkingDirectory(gpa, .{ .current = null, .path = "." });
    defer gpa.free(cwd);
    const argv = try gpa.alloc([]const u8, args.len - 3);
    defer gpa.free(argv);
    for (argv, args[3..]) |*destination, argument| destination.* = argument;
    const rules = [_]exec.SandboxPolicy.PathRule{
        .{ .path = "/", .access = .{ .read = true, .enumerate = true, .execute = true } },
        .{ .path = args[2], .access = .{
            .write = true,
            .create = true,
            .remove = true,
            .rename = true,
            .change_metadata = true,
        } },
    };
    var result = try exec.Pipeline.run(gpa, host, &.{.{
        .executable = argv[0],
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environment = .{ .replace = &.{} },
        .sandbox = .{ .restrict = .{
            .file_system = .{ .allow = &rules },
            .network = .{ .allow = &.{} },
        } },
    }});
    defer result.deinit(gpa);
    return switch (result) {
        .completed => |stages| switch (stages[0].termination) {
            .exited => |status| status,
            .signal => |number| @truncate(number +% 128),
            .spawn_failed => |failure| switch (failure) {
                .command_not_found => 127,
                .file_action => 1,
                else => 126,
            },
            else => 1,
        },
        .failed => |failure| {
            try diagnostics.interface.print("run-sandbox: {s}\n", .{@tagName(failure.reason)});
            return 126;
        },
    };
}
