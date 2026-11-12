//! One active completion and one replacement request per input. Providers and
//! their snapshots outlive deinit; the allocator must support concurrent use.
const std = @import("std");
const edit = @import("habush-edit");
const CompletionService = @import("CompletionService.zig");
const AsyncCompletion = @This();

io: std.Io,
service: CompletionService,
job: ?*Job = null,
queued: ?edit.Completion.Request = null,

const Job = struct {
    io: std.Io,
    service: CompletionService,
    request: edit.Completion.Request,
    future: std.Io.Future(edit.Completion.Error!?edit.Completion.Result) = undefined,
    stopping: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    discarded: bool = false,

    fn run(job: *Job) edit.Completion.Error!?edit.Completion.Result {
        defer job.done.store(true, .release);
        const interface = job.service.completion();
        return interface.query(interface.userdata, job.request);
    }

    fn stop(job: *Job) void {
        _ = job.future.cancel(job.io) catch {};
        job.stopped.store(true, .release);
    }
};

pub fn completion(service: *AsyncCompletion) edit.Completion {
    return .{ .userdata = service, .query = query, .poll = poll, .cancel = cancel, .choose = choose };
}

pub fn deinit(service: *AsyncCompletion) void {
    cancel(service);
    if (service.job) |job| {
        if (job.stopping) |*stopping| stopping.await(service.io);
        service.freeJob();
    }
    service.service.deinit();
    service.* = undefined;
}

fn freeJob(service: *AsyncCompletion) void {
    const job = service.job.?;
    const gpa = service.service.gpa;
    job.service.deinit();
    gpa.free(job.request.source);
    gpa.destroy(job);
    service.job = null;
}

fn cancel(userdata: *anyopaque) void {
    const service: *AsyncCompletion = @ptrCast(@alignCast(userdata));
    if (service.queued) |request| service.service.gpa.free(request.source);
    service.queued = null;
    if (service.job) |job| {
        if (job.discarded) return;
        job.discarded = true;
        job.stopping = service.io.concurrent(Job.stop, .{job}) catch {
            // Resource exhaustion still joins the request rather than leaking it.
            Job.stop(job);
            return;
        };
    }
}

fn query(userdata: *anyopaque, request: edit.Completion.Request) edit.Completion.Error!?edit.Completion.Result {
    const service: *AsyncCompletion = @ptrCast(@alignCast(userdata));
    cancel(service);
    var retained = request;
    retained.source = try service.service.gpa.dupe(u8, request.source);
    service.queued = retained;
    if (service.job == null and !try service.launch()) return null;
    return .{ .pending = true };
}

fn launch(service: *AsyncCompletion) edit.Completion.Error!bool {
    const request = service.queued orelse return false;
    const gpa = service.service.gpa;
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{
        .io = service.io,
        .service = .{ .gpa = gpa, .prefix = service.service.prefix, .providers = service.service.providers, .limits = service.service.limits },
        .request = request,
    };
    job.future = service.io.concurrent(Job.run, .{job}) catch {
        gpa.destroy(job);
        gpa.free(request.source);
        service.queued = null;
        return false;
    };
    service.queued = null;
    service.job = job;
    return true;
}

fn same(first: edit.Completion.Request, second: edit.Completion.Request) bool {
    return first.input_id == second.input_id and first.id == second.id and first.revision == second.revision and
        first.cursor == second.cursor and std.mem.eql(u8, first.source, second.source);
}

fn poll(userdata: *anyopaque, request: edit.Completion.Request) edit.Completion.Error!?edit.Completion.Result {
    const service: *AsyncCompletion = @ptrCast(@alignCast(userdata));
    if (service.job) |job| {
        if (job.discarded) {
            if (!job.stopped.load(.acquire)) return null;
            if (job.stopping) |*stopping| stopping.await(service.io);
            service.freeJob();
        }
    }
    if (service.job == null) {
        if (!try service.launch()) return .{};
    }
    const job = service.job.?;
    if (!same(job.request, request)) {
        cancel(service);
        return .{};
    }
    if (!job.done.load(.acquire)) return null;
    return (try job.future.await(service.io)) orelse .{};
}

fn choose(userdata: *anyopaque, gpa: std.mem.Allocator, request: edit.Completion.Request, index: usize) edit.Completion.Error!?edit.Completion.Edit {
    const service: *AsyncCompletion = @ptrCast(@alignCast(userdata));
    const job = service.job orelse return null;
    if (job.discarded or !job.done.load(.acquire) or !same(job.request, request)) return null;
    const interface = job.service.completion();
    return interface.choose(interface.userdata, gpa, request, index);
}

test "editing cancels pending work, replacements reject stale input IDs, and shutdown joins providers" {
    const habush = @import("habush");
    const io = std.testing.io;
    const Probe = struct {
        finish: std.Io.Event = .unset,
        calls: std.atomic.Value(u32) = .init(0),
        active: std.atomic.Value(u32) = .init(0),
        fn complete(userdata: ?*anyopaque, _: habush.Completion.Provider.Request, collector: *habush.Completion.Provider.Collector) habush.Completion.Provider.Error!void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = probe.active.fetchAdd(1, .monotonic);
            defer _ = probe.active.fetchSub(1, .release);
            _ = probe.calls.fetchAdd(1, .release);
            try probe.finish.wait(std.testing.io);
            _ = try collector.add(.{ .value = "choice" });
        }
    };
    var probe: Probe = .{};
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(2));
    {
        var service: AsyncCompletion = .{ .io = io, .service = .{
            .gpa = std.testing.allocator,
            .prefix = "",
            .providers = &.{.{ .userdata = &probe, .complete = Probe.complete }},
        } };
        defer service.deinit();
        var editor: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator }, .completion = service.completion(), .input_id = 9 };
        defer editor.deinit();
        try std.testing.expect(try editor.insert("cmd old"));
        _ = try editor.perform(.complete);
        while (probe.calls.load(.acquire) == 0) {
            if (std.Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.TestUnexpectedResult;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(try editor.insert("X"));
        try std.testing.expectEqualStrings("cmd oldX", editor.buffer.text());
        try std.testing.expect(!editor.completion_pending);
        probe.finish.set(io);
        _ = try editor.perform(.complete);
        while (editor.completion_pending) {
            if (std.Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.TestUnexpectedResult;
            _ = try editor.pollCompletion();
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqualStrings("cmd 'choice'", editor.buffer.text());
        var stale = service.job.?.request;
        stale.input_id += 1;
        const interface = service.completion();
        try std.testing.expect(try interface.choose(interface.userdata, std.testing.allocator, stale, 0) == null);
        probe.finish.reset();
        const count = probe.calls.load(.acquire);
        _ = try editor.perform(.complete);
        while (probe.calls.load(.acquire) == count) {
            if (std.Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.TestUnexpectedResult;
            _ = try editor.pollCompletion();
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), probe.active.load(.acquire));
}
