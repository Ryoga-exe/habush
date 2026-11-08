//! Shell job identifiers and ownership of running external pipelines.
//! This table belongs to one session; cloned language scopes do not share it.

const std = @import("std");
const Host = @import("../Host.zig");
const Pipeline = @import("../Pipeline.zig");
const ExitStatus = @import("types.zig").ExitStatus;
const Io = @import("Io.zig");
const Jobs = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
next_id: u32 = 1,
terminal_control: bool = false,
last_background_process_id: ?@import("types.zig").ProcessId = null,
process_id_buffer: [10]u8 = undefined,
diagnostic_io: Io = .{},
/// The current task's cancellation provider, when the Host can cancel waits.
/// Cleanup blocks cancellation until the canceled foreground job is reaped.
cancel_io: ?std.Io = null,

pub const Id = enum(u32) { _ };
pub const Options = struct { negated: bool = false, background: bool = true };

pub const Entry = struct {
    id: Id,
    title: []u8,
    pipeline: Pipeline,
    negated: bool = false,

    pub fn exitStatus(entry: *const Entry) ?ExitStatus {
        if (entry.pipeline.state() == .stopped) {
            for (0..entry.pipeline.stageCount()) |index| {
                if (entry.pipeline.status(index) == .stopped)
                    return @truncate(@as(u64, 128) + entry.pipeline.status(index).stopped);
            }
        }
        const last = entry.pipeline.status(entry.pipeline.stageCount() - 1);
        const result: ExitStatus = switch (last) {
            .completed => |result| switch (result.termination) {
                .exited => |status| status,
                .signal => |number| @truncate(@as(u64, 128) + number),
                .stopped => unreachable,
                .unknown => 1,
                .spawn_failed => |failure| switch (failure) {
                    .command_not_found => 127,
                    .file_action => 1,
                    else => 126,
                },
            },
            .stopped => |number| @truncate(@as(u64, 128) + number),
            else => return null,
        };
        return if (entry.negated and entry.pipeline.state() == .completed)
            @intFromBool(result == 0)
        else
            result;
    }
};

/// Waits for owned jobs and releases the table. Call cancelAll explicitly
/// first when the session's shutdown policy requires termination instead.
pub fn deinit(jobs: *Jobs) void {
    for (jobs.entries.items) |*entry| {
        entry.pipeline.deinit();
        jobs.gpa.free(entry.title);
    }
    jobs.entries.deinit(jobs.gpa);
    jobs.* = undefined;
}

pub fn cancelAll(jobs: *Jobs) void {
    for (jobs.entries.items) |*entry| entry.pipeline.signal(.kill) catch {};
}

/// Transfers pipeline ownership only on success. The title is copied.
pub fn add(jobs: *Jobs, pipeline: Pipeline, title: []const u8, options: Options) std.mem.Allocator.Error!Id {
    const owned_title = try jobs.gpa.dupe(u8, title);
    errdefer jobs.gpa.free(owned_title);
    try jobs.entries.ensureUnusedCapacity(jobs.gpa, 1);
    while (jobs.next_id == 0 or jobs.get(@enumFromInt(jobs.next_id)) != null) jobs.next_id +%= 1;
    const id: Id = @enumFromInt(jobs.next_id);
    jobs.next_id +%= 1;
    jobs.entries.appendAssumeCapacity(.{
        .id = id,
        .title = owned_title,
        .pipeline = pipeline,
        .negated = options.negated,
    });
    if (options.background) jobs.last_background_process_id = pipeline.processId(pipeline.stageCount() - 1);
    return id;
}

pub fn backgroundProcessIdText(jobs: *Jobs) ?[]const u8 {
    const id = jobs.last_background_process_id orelse return null;
    return std.fmt.bufPrint(&jobs.process_id_buffer, "{d}", .{@intFromEnum(id)}) catch unreachable;
}

pub fn resolve(jobs: *Jobs, operand: []const u8) ?Id {
    if (operand.len == 0) return null;
    if (operand[0] == '%') {
        const id = std.fmt.parseUnsigned(u32, operand[1..], 10) catch return null;
        if (id == 0) return null;
        return if (jobs.get(@enumFromInt(id)) != null) @enumFromInt(id) else null;
    }
    const pid = std.fmt.parseUnsigned(u32, operand, 10) catch return null;
    for (jobs.entries.items) |*entry| {
        const native_id = entry.pipeline.processId(entry.pipeline.stageCount() - 1) orelse continue;
        if (@intFromEnum(native_id) == pid) return entry.id;
    }
    return null;
}

pub fn get(jobs: *Jobs, id: Id) ?*Entry {
    for (jobs.entries.items) |*entry| if (entry.id == id) return entry;
    return null;
}

pub fn latest(jobs: *Jobs) ?Id {
    var remaining = jobs.entries.items.len;
    while (remaining != 0) {
        remaining -= 1;
        if (jobs.entries.items[remaining].pipeline.state() != .completed)
            return jobs.entries.items[remaining].id;
    }
    return null;
}

pub fn poll(jobs: *Jobs) Host.Error!void {
    for (jobs.entries.items) |*entry| {
        _ = try entry.pipeline.poll();
        try jobs.reportFailures(&entry.pipeline);
    }
}

pub fn wait(jobs: *Jobs, id: Id) Host.Error!?ExitStatus {
    const entry = jobs.get(id) orelse return null;
    _ = try entry.pipeline.waitEvents();
    try jobs.reportFailures(&entry.pipeline);
    const status = entry.exitStatus() orelse return error.Unexpected;
    if (entry.pipeline.state() == .completed) jobs.remove(id);
    return status;
}

pub fn waitAll(jobs: *Jobs) Host.Error!ExitStatus {
    var index: usize = 0;
    while (index < jobs.entries.items.len) {
        const id = jobs.entries.items[index].id;
        _ = try jobs.wait(id);
        if (jobs.get(id) != null) index += 1;
    }
    return 0;
}

pub fn signal(jobs: *Jobs, id: Id, request: Host.Signal) Host.Error!bool {
    const entry = jobs.get(id) orelse return false;
    try entry.pipeline.signal(request);
    return true;
}

/// A canceled foreground operation terminates and consumes this job. Other
/// jobs remain owned by the session, including jobs being waited on via wait.
pub fn foreground(jobs: *Jobs, id: Id) Host.Error!?ExitStatus {
    const entry = jobs.get(id) orelse return null;
    var lease: ?Host.TerminalLease = null;
    const host = entry.pipeline.host;
    var canceled = false;
    defer {
        const previous = if (jobs.cancel_io) |io| io.swapCancelProtection(.blocked) else null;
        defer {
            if (previous) |protection| _ = jobs.cancel_io.?.swapCancelProtection(protection);
        }
        if (canceled) entry.pipeline.signal(.kill) catch {};
        if (lease) |token| host.releaseTerminal(token) catch {};
        if (canceled) jobs.remove(id);
    }
    errdefer |failure| canceled = failure == error.Canceled;
    if (entry.pipeline.suspend_on_start) {
        // Every worker stops before the target can read the TTY. Observe the
        // startup barrier before handing over the terminal and resuming the
        // group; no reader can race into SIGTTIN before this point.
        _ = try entry.pipeline.waitEvents();
        entry.pipeline.suspend_on_start = false;
    }
    _ = try entry.pipeline.poll();
    if (entry.pipeline.state() != .completed) {
        if (jobs.terminal_control) {
            const group = entry.pipeline.process_group orelse return error.Unsupported;
            lease = host.acquireTerminal(group) catch |err| retry: {
                // Fast commands can exit between the first poll and tty
                // handoff. An already completed job needs no terminal claim.
                if (try entry.pipeline.poll() == .completed) break :retry null;
                return @as(Host.Error!?ExitStatus, err);
            };
        }
        // A freshly launched reader can have received SIGTTIN before the
        // terminal claim. Resume only after foreground ownership is installed.
        _ = try entry.pipeline.poll();
        for (0..entry.pipeline.stageCount()) |index| {
            if (entry.pipeline.status(index) == .stopped) {
                try entry.pipeline.signal(.cont);
                break;
            }
        }
        _ = try entry.pipeline.waitEvents();
    }
    if (lease) |token| {
        try host.releaseTerminal(token);
        lease = null;
    }
    try jobs.reportFailures(&entry.pipeline);
    const result = entry.exitStatus() orelse return error.Unexpected;
    if (entry.pipeline.state() == .completed) jobs.remove(id);
    return result;
}

fn reportFailures(jobs: Jobs, pipeline: *Pipeline) Host.Error!void {
    for (0..pipeline.stageCount()) |index| {
        if (pipeline.takeStartupFailure(index)) |failure|
            try jobs.diagnostic_io.reportStartupFailure(failure.context, failure.reason);
    }
}

fn remove(jobs: *Jobs, id: Id) void {
    for (jobs.entries.items, 0..) |*entry, index| {
        if (entry.id != id) continue;
        entry.pipeline.deinit();
        jobs.gpa.free(entry.title);
        _ = jobs.entries.orderedRemove(index);
        return;
    }
    unreachable;
}

test "job status survives polling until wait consumes it" {
    const FakeHost = @import("../Host/FakeHost.zig");
    const CommandPlan = @import("../CommandPlan.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var jobs: Jobs = .{ .gpa = std.testing.allocator };
    defer jobs.deinit();
    const plans = [_]CommandPlan{.{ .executable = "/tool", .argv = &.{"/tool"} }};
    const started = try Pipeline.start(std.testing.allocator, fake.host(), &plans);
    const id = try jobs.add(started.started, "tool", .{});
    fake.try_wait_termination = .{ .exited = 29 };
    try jobs.poll();
    try std.testing.expectEqual(Pipeline.State.completed, jobs.get(id).?.pipeline.state());
    try std.testing.expectEqual(@as(?ExitStatus, 29), try jobs.wait(id));
    try std.testing.expect((try jobs.wait(id)) == null);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_calls.items.len);
}

test "foreground jobs consume pipelines containing a stage that never spawned" {
    const FakeHost = @import("../Host/FakeHost.zig");
    for ([_]usize{ 0, 1 }) |failed_stage| {
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        var pipeline = try Pipeline.init(std.testing.allocator, fake.host(), 2);
        var transferred = false;
        defer if (!transferred) pipeline.deinit();
        pipeline.completeUnspawned(failed_stage, 127);
        _ = try pipeline.spawn(1 - failed_stage, .{ .executable = "/child", .argv = &.{"child"} });
        var jobs: Jobs = .{ .gpa = std.testing.allocator, .terminal_control = true };
        defer jobs.deinit();
        const id = try jobs.add(pipeline, "pipeline", .{ .background = false });
        transferred = true;
        try std.testing.expectEqual(@as(ExitStatus, if (failed_stage == 1) 127 else 0), (try jobs.foreground(id)).?);
        try std.testing.expectEqual(@as(usize, 0), jobs.entries.items.len);
    }
}

test "canceled foreground jobs are reaped without consuming other background jobs" {
    const FakeHost = @import("../Host/FakeHost.zig");
    const CancelOnce = struct {
        fn waitAny(userdata: ?*anyopaque, processes: []const Host.Process) Host.Error!Host.ProcessEvent {
            const fake: *FakeHost = @ptrCast(@alignCast(userdata.?));
            if (fake.wait_error) |err| {
                fake.wait_error = null;
                return err;
            }
            return fake.host().waitAny(processes);
        }
    };
    for ([_]bool{ false, true }) |startup_gate| {
        var fake = FakeHost.init(std.testing.allocator);
        defer fake.deinit();
        fake.try_wait_termination = null;
        var vtable = fake.host().vtable.*;
        vtable.wait_any = CancelOnce.waitAny;
        const host: Host = .{ .userdata = &fake, .vtable = &vtable };
        var jobs: Jobs = .{ .gpa = std.testing.allocator };
        defer jobs.deinit();
        const background = (try Pipeline.start(std.testing.allocator, host, &.{.{ .executable = "/background", .argv = &.{"background"} }})).started;
        const background_id = try jobs.add(background, "background", .{});
        var foreground_pipeline = (try Pipeline.start(std.testing.allocator, host, &.{.{ .executable = "/foreground", .argv = &.{"foreground"} }})).started;
        foreground_pipeline.suspend_on_start = startup_gate;
        const foreground_id = try jobs.add(foreground_pipeline, "foreground", .{});
        fake.wait_error = error.Canceled;

        try std.testing.expectError(error.Canceled, jobs.foreground(foreground_id));
        try std.testing.expect(jobs.get(foreground_id) == null);
        try std.testing.expectEqual(@as(usize, 1), jobs.entries.items.len);
        try std.testing.expectEqual(Pipeline.State.running, jobs.get(background_id).?.pipeline.state());
        try std.testing.expectEqual(@as(usize, 1), fake.signal_calls.items.len);
        try std.testing.expectEqual(Host.Signal.kill, fake.signal_calls.items[0].signal);
        try std.testing.expectEqual(@as(u32, 2), @intFromEnum(fake.signal_calls.items[0].process));
        try std.testing.expectEqual(@as(usize, 1), fake.wait_calls.items.len);
        try std.testing.expectEqual(@as(u32, 2), @intFromEnum(fake.wait_calls.items[0]));

        fake.wait_error = error.Canceled;
        try std.testing.expectError(error.Canceled, jobs.wait(background_id));
        try std.testing.expect(jobs.get(background_id) != null);
        fake.wait_error = null;
    }
}
