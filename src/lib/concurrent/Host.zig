//! Serializes calls to a Host shared by concurrently executing pipeline stages.
//!
//! The wrapped Host must be used exclusively through this adapter while stages
//! run. Resource readers and writers are borrowed after the short map lookup;
//! each resource must have one stage owner and stay open until that stage's I/O
//! completes. Every child waited through this adapter must have been spawned
//! through it. Shared parent writers need `concurrent/Writer.zig` as well.

const std = @import("std");
const CommandPlan = @import("../CommandPlan.zig");
const BaseHost = @import("../Host.zig");
const ConcurrentHost = @This();

inner: BaseHost,
gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
processes: std.AutoHashMapUnmanaged(BaseHost.Process, void) = .empty,
vtable: BaseHost.VTable,

/// Blocking waits use tryWait so the mutex is never held while waiting for a
/// process. A host without polling cannot satisfy this contract.
pub fn init(gpa: std.mem.Allocator, inner: BaseHost, io: std.Io) BaseHost.Error!ConcurrentHost {
    if (!inner.capabilities().poll or inner.vtable.try_wait == null)
        return error.Unsupported;
    return .{
        .inner = inner,
        .gpa = gpa,
        .io = io,
        .vtable = .{
            .capabilities = inner.capabilities(),
            .spawn = spawn,
            .wait = wait,
            .wait_event = waitEvent,
            .wait_any = waitAny,
            .try_wait = tryWait,
            .signal = signal,
            .signal_group = signalGroup,
            .acquire_terminal = acquireTerminal,
            .release_terminal = releaseTerminal,
            .open_file = openFile,
            .create_pipe = createPipe,
            .create_input = createInput,
            .create_capture = if (inner.vtable.create_capture != null) createCapture else null,
            .close_resource = closeResource,
            .resource_writer = resourceWriter,
            .resource_reader = resourceReader,
            .resolve_working_directory = resolveWorkingDirectory,
        },
    };
}

/// All process handles created through this adapter must have finished using
/// it before deinit. The wrapped Host retains ownership of any live children.
pub fn deinit(self: *ConcurrentHost) void {
    self.processes.deinit(self.gpa);
    self.* = undefined;
}

/// The returned Host borrows this adapter; do not move or destroy it while
/// any call or borrowed resource stream can still be in use.
pub fn host(self: *ConcurrentHost) BaseHost {
    return .{ .userdata = self, .vtable = &self.vtable };
}

fn from(userdata: ?*anyopaque) *ConcurrentHost {
    return @ptrCast(@alignCast(userdata.?));
}

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) BaseHost.SpawnError!BaseHost.SpawnOutcome {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    // Reserve bookkeeping before the irreversible spawn. No OOM is possible
    // after the wrapped Host has created a child.
    try self.processes.ensureUnusedCapacity(self.gpa, 1);
    const outcome = try self.inner.spawn(plan);
    if (outcome == .spawned)
        self.processes.putAssumeCapacityNoClobber(outcome.spawned.process, {});
    return outcome;
}

fn wait(userdata: ?*anyopaque, process: BaseHost.Process) BaseHost.Error!BaseHost.Termination {
    return waitPolling(from(userdata), process, false);
}

fn waitEvent(userdata: ?*anyopaque, process: BaseHost.Process) BaseHost.Error!BaseHost.Termination {
    return waitPolling(from(userdata), process, true);
}

fn waitPolling(
    self: *ConcurrentHost,
    process: BaseHost.Process,
    return_stopped: bool,
) BaseHost.Error!BaseHost.Termination {
    while (true) {
        const outcome = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.processes.contains(process)) return error.InvalidArguments;
            const observed = try self.inner.tryWait(process);
            if (observed) |termination| self.forgetTerminal(process, termination);
            break :blk observed;
        };
        if (outcome) |termination| switch (termination) {
            .stopped => if (return_stopped) return termination,
            else => return termination,
        };
        // A stopped child can report the same event repeatedly. Sleep outside
        // the lock so other stages can spawn, close resources, or resume it.
        try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
    }
}

fn waitAny(userdata: ?*anyopaque, processes: []const BaseHost.Process) BaseHost.Error!BaseHost.ProcessEvent {
    const self = from(userdata);
    if (processes.len == 0) return error.InvalidArguments;
    while (true) {
        const outcome = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Validate all handles before a poll can consume a terminal event.
            for (processes) |process| {
                if (!self.processes.contains(process)) return error.InvalidArguments;
            }
            for (processes) |process| {
                if (try self.inner.tryWait(process)) |termination| {
                    self.forgetTerminal(process, termination);
                    break :blk BaseHost.ProcessEvent{
                        .process = process,
                        .termination = termination,
                    };
                }
            }
            break :blk null;
        };
        if (outcome) |event| return event;
        try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
    }
}

fn tryWait(userdata: ?*anyopaque, process: BaseHost.Process) BaseHost.Error!?BaseHost.Termination {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.processes.contains(process)) return error.InvalidArguments;
    const observed = try self.inner.tryWait(process);
    if (observed) |termination| self.forgetTerminal(process, termination);
    return observed;
}

fn forgetTerminal(self: *ConcurrentHost, process: BaseHost.Process, termination: BaseHost.Termination) void {
    switch (termination) {
        .stopped => {},
        else => _ = self.processes.remove(process),
    }
}

fn signal(userdata: ?*anyopaque, process: BaseHost.Process, requested: BaseHost.Signal) BaseHost.Error!void {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.signal(process, requested);
}

fn signalGroup(userdata: ?*anyopaque, group: CommandPlan.ProcessGroup, requested: BaseHost.Signal) BaseHost.Error!void {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.signalGroup(group, requested);
}

fn acquireTerminal(userdata: ?*anyopaque, group: CommandPlan.ProcessGroup) BaseHost.Error!BaseHost.TerminalLease {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.acquireTerminal(group);
}

fn releaseTerminal(userdata: ?*anyopaque, lease: BaseHost.TerminalLease) BaseHost.Error!void {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.releaseTerminal(lease);
}

fn openFile(
    userdata: ?*anyopaque,
    cwd: CommandPlan.WorkingDirectory,
    open: CommandPlan.FileAction.Open,
) BaseHost.SpawnError!BaseHost.OpenFileOutcome {
    const self = from(userdata);
    // A FIFO open can wait for another stage's matching open. Only hosts that
    // explicitly synchronize their resource table may run it without the
    // adapter's broad lock.
    if (!self.inner.capabilities().parallel_open_file)
        return .{ .failed = .unsupported };
    return self.inner.openFile(cwd, open);
}

fn createPipe(userdata: ?*anyopaque) BaseHost.Error!BaseHost.Pipe {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.createPipe();
}

fn createCapture(userdata: ?*anyopaque) BaseHost.Error!CommandPlan.Resource {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.createCapture();
}

fn createInput(userdata: ?*anyopaque, bytes: []const u8) BaseHost.Error!CommandPlan.Resource {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.createInput(bytes);
}

fn closeResource(userdata: ?*anyopaque, resource: CommandPlan.Resource) void {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.inner.closeResource(resource);
}

fn resourceWriter(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Writer {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.resourceWriter(resource);
}

fn resourceReader(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Reader {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.resourceReader(resource);
}

fn resolveWorkingDirectory(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: BaseHost.WorkingDirectoryRequest,
) BaseHost.Error![]u8 {
    const self = from(userdata);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inner.resolveWorkingDirectory(allocator, request);
}

test "requires polling and delegates resource ownership" {
    const FakeHost = @import("../Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    try std.testing.expectError(error.Unsupported, ConcurrentHost.init(std.testing.allocator, fake.host(), std.testing.io));

    var base_vtable = fake.host().vtable.*;
    base_vtable.capabilities.poll = true;
    const base: BaseHost = .{ .userdata = &fake, .vtable = &base_vtable };
    var adapter = try ConcurrentHost.init(std.testing.allocator, base, std.testing.io);
    defer adapter.deinit();
    const wrapped = adapter.host();
    try std.testing.expect(wrapped.capabilities().poll);
    try std.testing.expectEqual(
        BaseHost.OpenFileOutcome{ .failed = .unsupported },
        try wrapped.openFile(.inherit, .{
            .path = "fifo",
            .target = .stdin,
            .access = .read,
            .disposition = .open_existing,
        }),
    );
    const pipe = try wrapped.createPipe();
    try std.testing.expect(wrapped.resourceWriter(pipe.write_end) != null);
    wrapped.closeResource(pipe.read_end);
    wrapped.closeResource(pipe.write_end);
    try std.testing.expectEqual(@as(usize, 2), fake.closed_resource_count);
    try std.testing.expectEqual(@as(usize, 1), fake.create_pipe_calls);
}

test "waitEvent returns stopped while wait keeps polling to termination" {
    const FakeHost = @import("../Host/FakeHost.zig");
    const Probe = struct {
        calls: usize = 0,

        fn spawn(_: ?*anyopaque, _: CommandPlan) BaseHost.SpawnError!BaseHost.SpawnOutcome {
            return .{ .spawned = .{
                .process = @enumFromInt(1),
                .sandbox_coverage = .not_requested,
            } };
        }

        fn poll(userdata: ?*anyopaque, _: BaseHost.Process) BaseHost.Error!?BaseHost.Termination {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            return switch (self.calls) {
                1, 2 => .{ .stopped = 19 },
                else => .{ .exited = 7 },
            };
        }
    };
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    var probe: Probe = .{};
    var base_vtable = fake.host().vtable.*;
    base_vtable.capabilities.poll = true;
    base_vtable.spawn = Probe.spawn;
    base_vtable.try_wait = Probe.poll;
    const base: BaseHost = .{ .userdata = &probe, .vtable = &base_vtable };
    var adapter = try ConcurrentHost.init(std.testing.allocator, base, std.testing.io);
    defer adapter.deinit();
    const wrapped = adapter.host();
    const process = (try wrapped.spawn(.{
        .executable = "/child",
        .argv = &.{"/child"},
    })).spawned.process;

    try std.testing.expectEqual(BaseHost.Termination{ .stopped = 19 }, try wrapped.waitEvent(process));
    try std.testing.expectEqual(BaseHost.Termination{ .exited = 7 }, try wrapped.wait(process));
    try std.testing.expectEqual(@as(usize, 3), probe.calls);

    const second = (try wrapped.spawn(.{
        .executable = "/child",
        .argv = &.{"/child"},
    })).spawned.process;
    const invalid: BaseHost.Process = @enumFromInt(2);
    try std.testing.expectError(error.InvalidArguments, wrapped.waitAny(&.{ second, invalid }));
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    const event = try wrapped.waitAny(&.{second});
    try std.testing.expectEqual(second, event.process);
    try std.testing.expectEqual(BaseHost.Termination{ .exited = 7 }, event.termination);
}

test "canceled waits retain process ownership for a later reap" {
    const FakeHost = @import("../Host/FakeHost.zig");
    const CanceledSleep = struct {
        fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.try_wait_termination = null;
    var base_vtable = fake.host().vtable.*;
    base_vtable.capabilities.poll = true;
    const base: BaseHost = .{ .userdata = &fake, .vtable = &base_vtable };
    var io_vtable = std.testing.io.vtable.*;
    io_vtable.sleep = CanceledSleep.sleep;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &io_vtable };
    var adapter = try ConcurrentHost.init(std.testing.allocator, base, io);
    defer adapter.deinit();
    const wrapped = adapter.host();
    const process = (try wrapped.spawn(.{
        .executable = "/child",
        .argv = &.{"/child"},
    })).spawned.process;

    try std.testing.expectError(error.Canceled, wrapped.wait(process));
    try std.testing.expectError(error.Canceled, wrapped.waitAny(&.{process}));
    fake.try_wait_termination = .{ .exited = 0 };
    try std.testing.expectEqual(BaseHost.Termination{ .exited = 0 }, try wrapped.wait(process));
}
