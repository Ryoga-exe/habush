//! Explicit, native integration checks for the macOS sandbox worker path.
//! Run with `zig build test-sandbox`; the worker is the trusted CLI artifact.

const std = @import("std");
const builtin = @import("builtin");
const exec = @import("habush-exec");

const read_execute: exec.SandboxPolicy.FileSystemAccess = .{
    .read = true,
    .enumerate = true,
    .execute = true,
};
const write_bundle: exec.SandboxPolicy.FileSystemAccess = .{
    .write = true,
    .create = true,
    .remove = true,
    .rename = true,
    .change_metadata = true,
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (builtin.target.os.tag != .macos) {
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &.{});
        try stderr.interface.writeAll("sandbox integration skipped: macOS only\n");
        return 0;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--identity-target"))
        return identityTarget(init);
    if (args.len < 2) return error.MissingWorkerExecutable;

    const gpa = init.gpa;
    const io = init.io;
    // Build's artifact argument can be relative to the workspace even though
    // the backend requires an absolute path to this trusted executable.
    const worker = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], gpa);
    defer gpa.free(worker);
    const self_executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_executable);
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    const hex = std.fmt.hex(@as(u128, @bitCast(random)));
    const scratch = try gpa.print("/tmp/habush-sandbox-{s}", .{hex[0..]});
    defer gpa.free(scratch);
    try std.Io.Dir.createDirAbsolute(io, scratch, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    const allowed = try std.fs.path.join(gpa, &.{ scratch, "allowed" });
    defer gpa.free(allowed);
    try std.Io.Dir.createDirAbsolute(io, allowed, .default_dir);

    var system: exec.Host.System = .{
        .gpa = gpa,
        .io = io,
        .sandbox_backend = .{ .kind = .macos_seatbelt },
        .worker_executable = worker,
    };
    defer system.deinit();
    const host = system.host();
    const rules = [_]exec.SandboxPolicy.PathRule{
        .{ .path = "/", .access = read_execute },
        .{ .path = allowed, .access = write_bundle },
    };
    const file_policy: exec.SandboxPolicy = .{
        .file_system = .{ .allow = &rules },
        .network = .{ .allow = &.{} },
    };

    try checkFileActions(gpa, io, host, worker, scratch, allowed, file_policy);
    try checkNetwork(gpa, io, host);
    try checkIdentity(gpa, io, host, allowed, self_executable);
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    try stderr.interface.writeAll("sandbox integration passed\n");
    return 0;
}

fn checkFileActions(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: exec.Host,
    worker: []const u8,
    scratch: []const u8,
    allowed: []const u8,
    policy: exec.SandboxPolicy,
) !void {
    const denied_output = try std.fs.path.join(gpa, &.{ scratch, "denied-output" });
    defer gpa.free(denied_output);
    const denied_compound = try std.fs.path.join(gpa, &.{ scratch, "denied-compound" });
    defer gpa.free(denied_compound);
    const marker = try std.fs.path.join(gpa, &.{ allowed, "target-marker" });
    defer gpa.free(marker);
    const compound_marker = try std.fs.path.join(gpa, &.{ allowed, "compound-marker" });
    defer gpa.free(compound_marker);
    const allowed_output = try std.fs.path.join(gpa, &.{ allowed, "output" });
    defer gpa.free(allowed_output);

    const denied_action = [_]exec.CommandPlan.FileAction{.{ .open = .{
        .path = denied_output,
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_truncate,
    } }};
    const denied_plan: exec.CommandPlan = .{
        .executable = "/usr/bin/touch",
        .argv = &.{ "/usr/bin/touch", marker },
        .file_actions = &denied_action,
        .sandbox = .{ .restrict = policy },
    };
    const denied = try runOne(gpa, io, host, denied_plan);
    try check(io, denied.termination == .spawn_failed and
        denied.termination.spawn_failed == .file_action and
        denied.termination.spawn_failed.file_action.action_index == 0 and
        denied.termination.spawn_failed.file_action.reason == .access_denied, "worker redirection denial must report its file action before target exec");
    try check(io, denied.sandbox_coverage == .complete, "denial coverage must be complete");
    try expectMissing(io, denied_output);
    try expectMissing(io, marker);

    const input = try host.createInput("borrowed input\n");
    defer host.closeResource(input);
    const prefixed_actions = [_]exec.CommandPlan.FileAction{
        .{ .use_resource = .{ .resource = input, .target = .stdin } },
        denied_action[0],
    };
    var prefixed_plan = denied_plan;
    prefixed_plan.file_actions = &prefixed_actions;
    const prefixed = try runOne(gpa, io, host, prefixed_plan);
    try check(io, prefixed.termination == .spawn_failed and
        prefixed.termination.spawn_failed == .file_action and
        prefixed.termination.spawn_failed.file_action.action_index == 1, "startup report must retain original file-action indexes after resource bindings");

    const missing_path = try std.fs.path.join(gpa, &.{ scratch, "missing-executable" });
    defer gpa.free(missing_path);
    const missing = try runOne(gpa, io, host, .{
        .executable = missing_path,
        .argv = &.{missing_path},
        .sandbox = .{ .restrict = policy },
    });
    try check(io, missing.termination == .spawn_failed and missing.termination.spawn_failed == .command_not_found, "worker exec failure must retain its structured reason");
    const target_126 = try runOne(gpa, io, host, .{
        .executable = "/bin/sh",
        .argv = &.{ "/bin/sh", "-c", "exit 126" },
        .sandbox = .{ .restrict = policy },
    });
    try check(io, exitedWith(target_126, 126), "target exit 126 must remain distinct from worker startup failure");

    const allowed_action = [_]exec.CommandPlan.FileAction{.{ .open = .{
        .path = allowed_output,
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_truncate,
    } }};
    const allowed_result = try runOne(gpa, io, host, .{
        .executable = "/bin/echo",
        .argv = &.{ "/bin/echo", "allowed" },
        .file_actions = &allowed_action,
        .sandbox = .{ .restrict = policy },
    });
    try check(io, exitedWith(allowed_result, 0), "allowed worker redirection must succeed");
    try check(io, allowed_result.sandbox_coverage == .complete, "allowed coverage must be complete");
    const output = try std.Io.Dir.cwd().readFileAlloc(io, allowed_output, gpa, .limited(64));
    defer gpa.free(output);
    try check(io, std.mem.eql(u8, output, "allowed\n"), "allowed output contents differ");

    const source = try gpa.print("/usr/bin/touch {s} > {s}", .{ compound_marker, denied_compound });
    defer gpa.free(source);
    const compound = try runOne(gpa, io, host, .{
        .executable = worker,
        .argv = &.{ worker, "-c", source },
        .sandbox = .{ .restrict = policy },
    });
    try check(io, exitedWithNonzero(compound) and !exitedWith(compound, 126), "whole-evaluation compound redirection must fail in target");
    try expectMissing(io, denied_compound);
    try expectMissing(io, compound_marker);

    // A missing adapter must reject before launching the marker command.
    var default_system: exec.Host.System = .{ .gpa = gpa, .io = io };
    defer default_system.deinit();
    try expectUnavailable(io, default_system.host(), denied_plan);
    try expectMissing(io, marker);
}

fn checkNetwork(gpa: std.mem.Allocator, io: std.Io, host: exec.Host) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port_number = server.socket.address.getPort();
    const port = try gpa.print("{d}", .{port_number});
    defer gpa.free(port);
    const argv: []const []const u8 = &.{ "/usr/bin/nc", "-z", "-w", "1", "127.0.0.1", port };
    var plan: exec.CommandPlan = .{
        .executable = argv[0],
        .argv = argv,
        .sandbox = .{ .restrict = .{} },
    };
    const baseline = try runOne(gpa, io, host, plan);
    try check(io, exitedWith(baseline, 0), "listener baseline through worker must connect");
    try check(io, baseline.sandbox_coverage == .complete, "baseline coverage must be complete");

    plan.sandbox.restrict.network = .{ .allow = &.{} };
    const denied = try runOne(gpa, io, host, plan);
    try check(io, exitedWithNonzero(denied) and !exitedWith(denied, 126), "sandboxed localhost connection must fail in target");
    try check(io, denied.sandbox_coverage == .complete, "network denial coverage must be complete");

    const allow_port = [_]exec.SandboxPolicy.NetworkRule{.{
        .protocol = .tcp,
        .operation = .connect,
        .ports = .{ .first = port_number, .last = port_number },
    }};
    plan.sandbox.restrict.network = .{ .allow = &allow_port };
    try expectUnavailable(io, host, plan);
    plan.sandbox.restrict.enforcement = .best_effort;
    const partial = try runOne(gpa, io, host, plan);
    try check(io, exitedWith(partial, 0), "best-effort target must still connect");
    try check(io, partial.sandbox_coverage == .partial, "best-effort coverage must be partial");
}

fn checkIdentity(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: exec.Host,
    cwd: []const u8,
    self_executable: []const u8,
) !void {
    const output = try host.createPipe();
    defer host.closeResource(output.read_end);
    defer host.closeResource(output.write_end);
    const script = "printf '%s\\n' \"$$\"; exec \"$1\" --identity-target";
    const actions = [_]exec.CommandPlan.FileAction{.{ .use_resource = .{
        .resource = output.write_end,
        .target = .stdout,
    } }};
    const result = try host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "/bin/sh", "-c", script, "shell-spelling", self_executable },
        .environment = .{ .replace = &.{.{ .name = "TEST_MARK", .value = "worker-env" }} },
        .cwd = .{ .path = cwd },
        .file_actions = &actions,
        .process_group = .create,
        .sandbox = .{ .restrict = .{ .network = .{ .allow = &.{} } } },
    });
    const spawned = switch (result) {
        .spawned => |value| value,
        .failed => |failure| {
            try report(io, "PID check failed to spawn: {s}", .{@tagName(failure)});
            return error.UnexpectedSpawnFailure;
        },
    };
    errdefer _ = host.wait(spawned.process) catch {};
    errdefer host.signal(spawned.process, .kill) catch {};
    host.closeResource(output.write_end);
    const reader = host.resourceReader(output.read_end) orelse return error.MissingResourceReader;
    const text = try reader.allocRemaining(gpa, .limited(256));
    defer gpa.free(text);
    host.closeResource(output.read_end);
    const termination = try host.wait(spawned.process);
    try check(io, termination == .exited and termination.exited == 0, "PID check target must exit 0");
    try check(io, spawned.sandbox_coverage == .complete, "PID check coverage must be complete");
    try check(io, spawned.process_id != null and spawned.process_group != null, "worker must expose PID and PGID");
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const shell_pid = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.MissingPid, 10);
    const native_pid = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.MissingPid, 10);
    const native_group = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.MissingPgid, 10);
    const printed_cwd = fields.next() orelse return error.MissingCwd;
    const printed_env = fields.next() orelse return error.MissingEnvironment;
    const canonical_cwd = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd, gpa);
    defer gpa.free(canonical_cwd);
    try check(io, fields.next() == null, "PID output has extra fields");
    try check(io, shell_pid == native_pid, "shell exec must preserve PID");
    try check(io, native_pid == @backingInt(spawned.process_id.?), "worker must preserve target PID");
    try check(io, native_group == @backingInt(spawned.process_group.?), "worker must preserve PGID");
    try check(io, std.mem.eql(u8, printed_cwd, canonical_cwd), "worker must preserve cwd");
    try check(io, std.mem.eql(u8, printed_env, "worker-env"), "worker must preserve environment");
}

fn identityTarget(init: std.process.Init) !u8 {
    if (builtin.target.os.tag != .macos) return error.Unsupported;
    const Libc = struct {
        extern "c" fn getpgrp() c_int;
    };
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(init.io, &cwd_buffer);
    const mark = init.environ_map.get("TEST_MARK") orelse "";
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try stdout.interface.print("{d}\n{d}\n{s}\n{s}\n", .{
        std.posix.system.getpid(),
        Libc.getpgrp(),
        cwd_buffer[0..cwd_len],
        mark,
    });
    return 0;
}

fn runOne(gpa: std.mem.Allocator, io: std.Io, host: exec.Host, plan: exec.CommandPlan) !exec.Pipeline.StageResult {
    var outcome = try exec.Pipeline.run(gpa, host, &.{plan});
    defer outcome.deinit(gpa);
    return switch (outcome) {
        .completed => |stages| stages[0],
        .failed => |failure| {
            try report(io, "unexpected launcher failure: {s}", .{@tagName(failure.reason)});
            return error.UnexpectedSpawnFailure;
        },
    };
}

fn expectUnavailable(io: std.Io, host: exec.Host, plan: exec.CommandPlan) !void {
    const outcome = try host.spawn(plan);
    switch (outcome) {
        .spawned => |spawned| {
            host.signal(spawned.process, .kill) catch {};
            _ = host.wait(spawned.process) catch {};
            try report(io, "unexpected unrestricted spawn", .{});
            return error.AssertionFailed;
        },
        .failed => |failure| try check(io, failure == .sandbox_unavailable, "required sandbox must fail closed"),
    }
}

fn expectMissing(io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
        try report(io, "unexpected file: {s}", .{path});
        return error.AssertionFailed;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

fn exitedWith(result: exec.Pipeline.StageResult, status: u8) bool {
    return result.termination == .exited and result.termination.exited == status;
}

fn exitedWithNonzero(result: exec.Pipeline.StageResult) bool {
    return result.termination == .exited and result.termination.exited != 0;
}

fn check(io: std.Io, condition: bool, message: []const u8) !void {
    if (condition) return;
    try report(io, "{s}", .{message});
    return error.AssertionFailed;
}

fn report(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    try stderr.interface.writeAll("sandbox integration: ");
    try stderr.interface.print(format, args);
    try stderr.interface.writeByte('\n');
}
