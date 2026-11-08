//! Native `Host` implementation backed by Zig's cross-platform standard APIs.
//!
//! The backend owns child processes and standard-stream resources, exposes
//! process events, and leases foreground terminals on POSIX systems. Native
//! restrictions use an explicitly configured backend and trusted worker;
//! arbitrary file descriptors remain an unsupported boundary.

const std = @import("std");
const builtin = @import("builtin");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const SandboxBackend = @import("../SandboxBackend.zig");
const command_worker = @import("../worker.zig");
const runtime_types = @import("../runtime/types.zig");
const append_file = @import("System/append_file.zig");
const pipe = @import("System/pipe.zig");
const worker_channel = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
    struct {}
else
    @import("System/worker_channel.zig");
const WorkerReport = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) void else worker_channel.Report;
const terminal = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
    struct {}
else
    @import("System/terminal.zig");
const windows_spawn = if (builtin.os.tag == .windows) @import("System/windows_spawn.zig") else struct {};
const System = @This();
const TerminalModes = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
    u8
else
    terminal.Modes;

/// Must be safe for concurrent use when `parallel_open_file` is exercised.
gpa: std.mem.Allocator,
io: std.Io,
/// Parent process environment used as the base for `.overlay` plans.
/// The caller retains ownership and must keep it alive while this host is used.
environ_map: ?*const std.process.Environ.Map = null,
/// Explicit opt-in process restriction adapter. The worker path is borrowed
/// and must name this application's trusted sandbox worker entry point.
sandbox_backend: ?SandboxBackend = null,
worker_executable: ?[]const u8 = null,
children: std.AutoHashMapUnmanaged(Host.Process, ChildRecord) = .empty,
resources: std.AutoHashMapUnmanaged(CommandPlan.Resource, *FileResource) = .empty,
/// Protects only the resource table, numeric IDs, and lazy reader creation.
/// A FIFO open or file close must never hold this mutex.
resource_mutex: std.Io.Mutex = .init,
job_terminal_modes: std.AutoHashMapUnmanaged(CommandPlan.ProcessGroup, TerminalModes) = .empty,
terminal_lease: ?TerminalRecord = null,
next_process: u32 = 1,
next_resource: u32 = 1,
next_terminal_lease: u32 = 1,

const FileResource = struct {
    storage: Storage,
    writer: ?std.Io.File.Writer,
    readable: bool = false,
    reader: ?std.Io.File.Reader = null,
    positional_read: bool = false,
    // `read` uses takeByte, so a one-byte buffer does not read past the
    // consumed byte before a child inherits the descriptor. Other Reader
    // operations can still read ahead and need shared input ownership.
    read_buffer: [1]u8 = undefined,

    const Storage = union(enum) {
        file: std.Io.File,
        temporary: TemporaryFile,

        const TemporaryFile = struct {
            file: std.Io.File,
            cleanup: ?Cleanup,

            const Cleanup = struct {
                dir: std.Io.Dir,
                close_dir: bool,
                basename_hex: u64,
            };

            fn deinit(temporary: TemporaryFile, io: std.Io) void {
                temporary.file.close(io);
                if (temporary.cleanup) |cleanup| {
                    const basename = std.fmt.hex(cleanup.basename_hex);
                    cleanup.dir.deleteFile(io, &basename) catch {};
                    if (cleanup.close_dir) cleanup.dir.close(io);
                }
            }
        };
    };

    fn file(resource: *const FileResource) std.Io.File {
        return switch (resource.storage) {
            .file => |handle| handle,
            .temporary => |temporary| temporary.file,
        };
    }

    fn deinit(resource: *FileResource, io: std.Io) void {
        switch (resource.storage) {
            .file => |handle| handle.close(io),
            .temporary => |temporary| temporary.deinit(io),
        }
        resource.* = undefined;
    }
};

const ChildRecord = struct {
    child: std.process.Child,
    process_group: ?CommandPlan.ProcessGroup,
    report: ?WorkerReport = null,
};

const TerminalRecord = struct {
    token: Host.TerminalLease,
    tty: std.Io.File,
    group: CommandPlan.ProcessGroup,
    previous_group: u32,
    shell_modes: TerminalModes,
    foreground_restored: bool = false,
};

pub fn deinit(system: *System) void {
    const io = system.io;
    const previous_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_protection);
    if (system.terminal_lease) |lease| {
        releaseTerminal(system, lease.token) catch {};
        if (system.terminal_lease) |still_active| {
            if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
                if (!still_active.foreground_restored) {
                    const previous: std.posix.pid_t = @intCast(still_active.previous_group);
                    terminal.setForegroundGroup(still_active.tty, previous) catch {};
                }
                terminal.setModes(still_active.tty, still_active.shell_modes) catch {};
            }
            still_active.tty.close(system.io);
        }
        system.terminal_lease = null;
    }
    var children = system.children.valueIterator();
    while (children.next()) |record| {
        if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            if (record.report) |report| report.deinit();
        }
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            record.child.kill(system.io);
        } else {
            // TERM cannot be handled while a child is stopped. KILL lets the
            // host reap every process it still owns during teardown.
            if (record.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
            _ = record.child.wait(system.io) catch {};
        }
    }
    system.children.deinit(system.gpa);
    system.job_terminal_modes.deinit(system.gpa);
    var resources = system.resources.valueIterator();
    while (resources.next()) |resource| {
        resource.*.deinit(system.io);
        system.gpa.destroy(resource.*);
    }
    system.resources.deinit(system.gpa);
    system.* = undefined;
}

pub fn host(system: *System) Host {
    return .{
        .userdata = system,
        .vtable = &vtable,
    };
}

fn workerHost(system: *System) Host {
    return .{ .userdata = system, .vtable = &worker_vtable };
}

const worker_vtable: Host.VTable = blk: {
    var value = vtable;
    value.spawn = spawnWorker;
    break :blk value;
};

const vtable: Host.VTable = .{
    .capabilities = .{
        .process_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi,
        .terminal_control = builtin.os.tag != .windows and builtin.os.tag != .wasi,
        .suspend_before_execute = builtin.os.tag != .windows and builtin.os.tag != .wasi,
        .poll = builtin.os.tag != .wasi,
        .signals = builtin.os.tag != .wasi,
        .parallel_open_file = true,
    },
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
    .create_capture = createCapture,
    .close_resource = closeResource,
    .resource_writer = resourceWriter,
    .resource_reader = resourceReader,
    .resolve_working_directory = resolveWorkingDirectory,
    .read_directory = readDirectory,
};

fn readDirectory(userdata: ?*anyopaque, gpa: std.mem.Allocator, cwd: CommandPlan.WorkingDirectory, path: []const u8) Host.Error!?Host.Directory {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const resolved = if (std.fs.path.isAbsolute(path))
        try gpa.dupe(u8, path)
    else switch (cwd) {
        .inherit => try gpa.dupe(u8, path),
        .path => |base| try std.fs.path.join(gpa, &.{ base, path }),
    };
    defer gpa.free(resolved);
    const directory = std.Io.Dir.cwd().openDir(system.io, resolved, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        error.Canceled => return error.Canceled,
        else => return error.ResourceUnavailable,
    };
    defer directory.close(system.io);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var iterator = directory.iterate();
    while (iterator.next(system.io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        else => return error.Unexpected,
    }) |entry| {
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try names.append(gpa, name);
    }
    return .{ .names = try names.toOwnedSlice(gpa) };
}

fn createPipe(userdata: ?*anyopaque) Host.Error!Host.Pipe {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const files = pipe.create() catch |err| return switch (err) {
        error.OperationUnsupported => error.Unsupported,
        else => error.ResourceUnavailable,
    };
    errdefer files[0].close(system.io);
    errdefer files[1].close(system.io);

    system.resource_mutex.lockUncancelable(system.io);
    defer system.resource_mutex.unlock(system.io);
    const read_data = try system.gpa.create(FileResource);
    errdefer system.gpa.destroy(read_data);
    const write_data = try system.gpa.create(FileResource);
    errdefer system.gpa.destroy(write_data);
    try system.resources.ensureUnusedCapacity(system.gpa, 2);

    read_data.* = .{ .storage = .{ .file = files[0] }, .writer = null, .readable = true };
    write_data.* = .{
        .storage = .{ .file = files[1] },
        .writer = files[1].writerStreaming(system.io, &.{}),
    };
    const read_end: CommandPlan.Resource = @enumFromInt(system.next_resource);
    system.next_resource +%= 1;
    const write_end: CommandPlan.Resource = @enumFromInt(system.next_resource);
    system.next_resource +%= 1;
    system.resources.putAssumeCapacityNoClobber(read_end, read_data);
    system.resources.putAssumeCapacityNoClobber(write_end, write_data);
    return .{ .read_end = read_end, .write_end = write_end };
}

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) Host.SpawnError!Host.SpawnOutcome {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (plan.sandbox == .restrict) {
        const backend = system.sandbox_backend orelse return .{ .failed = .sandbox_unavailable };
        const worker_executable = system.worker_executable orelse return .{ .failed = .sandbox_unavailable };
        return backend.launch(system.gpa, system.io, system.workerHost(), worker_executable, plan);
    }
    if (plan.suspend_before_execute) {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .{ .failed = .unsupported };
        const worker_executable = system.worker_executable orelse return .{ .failed = .unsupported };
        return command_worker.launch(system.gpa, system.workerHost(), worker_executable, plan) catch |err| switch (err) {
            error.Unsupported => if (firstFifoAction(system, plan) == null)
                system.launchPreboundWorker(worker_executable, plan)
            else
                .{ .failed = .unsupported },
            else => |other| return other,
        };
    }
    // FIFO opens can wait for another stage. Defer those actions to a fresh
    // worker so the parent can finish launching its peers. Ordinary file opens
    // retain their existing structured failures and source-order behavior.
    if (firstFifoAction(system, plan)) |action_index| {
        if (system.worker_executable) |worker_executable| {
            return command_worker.launch(system.gpa, system.workerHost(), worker_executable, plan) catch |err| switch (err) {
                error.Unsupported => fileActionFailure(action_index, .unsupported),
                else => |other| return other,
            };
        }
        return fileActionFailure(action_index, .unsupported);
    }
    return system.spawnNative(plan, false);
}

/// Ordinary interleaved resource actions already work through native stdio
/// preparation. Preserve their order instead of making interactive execution
/// less capable. Blocking FIFO and restricted opens never enter this fallback.
fn launchPreboundWorker(system: *System, executable: []const u8, plan: CommandPlan) Host.SpawnError!Host.SpawnOutcome {
    std.debug.assert(plan.sandbox == .inherit);
    var target = plan;
    target.file_actions = &.{};
    var prepared = command_worker.prepare(system.gpa, target) catch |err| switch (err) {
        error.Unsupported => return .{ .failed = .unsupported },
        else => |other| return other,
    };
    defer prepared.deinit(system.gpa);
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(system.gpa);
    try arguments.appendSlice(system.gpa, &.{ executable, command_worker.argument });
    try arguments.appendSlice(system.gpa, prepared.arguments);
    var wrapped = plan;
    wrapped.executable = executable;
    wrapped.argv = arguments.items;
    wrapped.command_failure = null;
    wrapped.suspend_before_execute = false;
    return system.workerHost().spawn(wrapped);
}

fn spawnWorker(userdata: ?*anyopaque, plan: CommandPlan) Host.SpawnError!Host.SpawnOutcome {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .{ .failed = .unsupported };
    const worker_index = for (plan.argv, 0..) |value, index| {
        if (std.mem.eql(u8, value, command_worker.argument)) break index;
    } else return error.InvalidArguments;
    // This host is private to trusted launch preparation. No public plan field
    // or environment value is interpreted as worker-channel configuration.
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(system.gpa);
    try arguments.appendSlice(system.gpa, plan.argv[0 .. worker_index + 1]);
    try arguments.append(system.gpa, command_worker.bootstrap_argument);
    try arguments.appendSlice(system.gpa, plan.argv[worker_index + 1 ..]);
    var wrapped = plan;
    wrapped.argv = arguments.items;
    return system.spawnNative(wrapped, true);
}

fn spawnNative(system: *System, plan: CommandPlan, bootstrap_worker: bool) Host.SpawnError!Host.SpawnOutcome {
    if ((builtin.os.tag == .windows or builtin.os.tag == .wasi) and plan.process_group != .inherit)
        return .{ .failed = .unsupported };
    if (plan.process_group == .join and
        !system.ownsProcessGroup(plan.process_group.join))
        return error.InvalidArguments;
    const pgid: ?std.posix.pid_t = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
        null
    else switch (plan.process_group) {
        .inherit => null,
        .create => 0,
        .join => |group| std.math.cast(std.posix.pid_t, @intFromEnum(group)) orelse
            return error.InvalidArguments,
    };

    var bindings = [_]StdioBinding{
        .{ .inherit = .stdin },
        .{ .inherit = .stdout },
        .{ .inherit = .stderr },
    };
    var open_files: std.ArrayList(std.Io.File) = .empty;
    defer {
        for (open_files.items) |file| file.close(system.io);
        open_files.deinit(system.gpa);
    }

    var working_directory: ?std.Io.Dir = null;
    defer if (working_directory) |directory| directory.close(system.io);
    if (plan.file_actions.len != 0) {
        working_directory = switch (plan.cwd) {
            .inherit => null,
            .path => |path| std.Io.Dir.cwd().openDir(system.io, path, .{}) catch |err| {
                return fileActionFailure(0, fileActionReason(err) orelse return error.Unexpected);
            },
        };
    }
    const action_directory = working_directory orelse std.Io.Dir.cwd();
    for (plan.file_actions, 0..) |action, action_index_usize| {
        const action_index = std.math.cast(u32, action_index_usize) orelse
            return error.InvalidArguments;
        switch (action) {
            .open => |open| {
                const target = stdioIndex(open.target) orelse
                    return fileActionFailure(action_index, .unsupported);
                const file = openRedirectFile(system.io, action_directory, open) catch |err| {
                    return fileActionFailure(
                        action_index,
                        fileActionReason(err) orelse return error.Unexpected,
                    );
                };
                open_files.append(system.gpa, file) catch {
                    file.close(system.io);
                    return error.OutOfMemory;
                };
                bindings[target] = .{ .file = file };
            },
            .duplicate => |duplicate| {
                const source = stdioIndex(duplicate.source) orelse
                    return fileActionFailure(action_index, .unsupported);
                const target = stdioIndex(duplicate.target) orelse
                    return fileActionFailure(action_index, .unsupported);
                bindings[target] = bindings[source];
            },
            .close => |descriptor| {
                const target = stdioIndex(descriptor) orelse
                    return fileActionFailure(action_index, .unsupported);
                bindings[target] = .close;
            },
            .use_resource => |use| {
                const target = stdioIndex(use.target) orelse
                    return fileActionFailure(action_index, .unsupported);
                system.resource_mutex.lockUncancelable(system.io);
                const resource = system.resources.get(use.resource) orelse {
                    system.resource_mutex.unlock(system.io);
                    return fileActionFailure(action_index, .unsupported);
                };
                const file = resource.file();
                system.resource_mutex.unlock(system.io);
                bindings[target] = .{ .file = file };
            },
        }
    }

    if (plan.command_failure) |failure| return .{ .failed = switch (failure) {
        .command_not_found => .command_not_found,
        .access_denied => .access_denied,
    } };

    var child_io = [_]std.process.SpawnOptions.StdIo{
        spawnStdio(bindings[0], .stdin),
        spawnStdio(bindings[1], .stdout),
        spawnStdio(bindings[2], .stderr),
    };
    var channel: if (builtin.os.tag == .windows or builtin.os.tag == .wasi) ?void else ?worker_channel.Parent = null;
    defer if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (channel) |*parent| parent.deinit();
    };
    if (bootstrap_worker) {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .{ .failed = .unsupported };
        channel = worker_channel.Parent.init(bindingFile(bindings[0])) catch return .{ .failed = .resource_unavailable };
        child_io[0] = .{ .file = channel.?.childInput() };
    }

    var owned_argv: ?[][]const u8 = null;
    defer if (owned_argv) |argv| system.gpa.free(argv);
    // `std.process.spawn` identifies the executable through `argv[0]`. Use the
    // already-resolved executable here so the host never performs another PATH
    // search; the remaining arguments retain the command plan's representation.
    const argv = if (std.mem.eql(u8, plan.executable, plan.argv[0]))
        plan.argv
    else argv: {
        const copy = try system.gpa.dupe([]const u8, plan.argv);
        copy[0] = plan.executable;
        owned_argv = copy;
        break :argv copy;
    };

    var environment = try system.prepareEnvironment(plan.environment);
    defer if (environment) |*map| map.deinit();

    try system.children.ensureUnusedCapacity(system.gpa, 1);
    var child = if (builtin.os.tag == .windows and needsWindowsHandleSpawn(bindings)) child: {
        const outcome = try windows_spawn.spawn(
            system.gpa,
            argv,
            switch (plan.cwd) {
                .inherit => null,
                .path => |path| path,
            },
            if (environment) |*map| map else system.environ_map,
            .{
                bindingFile(bindings[0]),
                bindingFile(bindings[1]),
                bindingFile(bindings[2]),
            },
        );
        break :child switch (outcome) {
            .spawned => |spawned| spawned,
            .failed => |failure| return .{ .failed = failure },
        };
    } else std.process.spawn(system.io, .{
        .argv = argv,
        .cwd = switch (plan.cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
        },
        .environ_map = if (environment) |*map| map else null,
        .stdin = child_io[0],
        .stdout = child_io[1],
        .stderr = child_io[2],
        .pgid = pgid,
    }) catch |err| return .{ .failed = try mapSpawnFailure(err) };

    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (channel) |*parent| parent.sendInput() catch {
            // Spawn has already transferred a native process to us. A failed
            // bootstrap must release it before reporting a startup failure.
            const previous_protection = system.io.swapCancelProtection(.blocked);
            defer _ = system.io.swapCancelProtection(previous_protection);
            if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
            _ = child.wait(system.io) catch {};
            return .{ .failed = .resource_unavailable };
        };
    }

    const process_group: ?CommandPlan.ProcessGroup = switch (plan.process_group) {
        .inherit => null,
        .create => if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
            unreachable
        else
            @enumFromInt(@as(u32, @intCast(child.id.?))),
        .join => |group| group,
    };
    const process = system.nextProcess();
    system.children.putAssumeCapacityNoClobber(process, .{
        .child = child,
        .process_group = process_group,
        .report = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
            null
        else if (channel) |*parent|
            parent.takeReport(std.math.cast(u32, plan.file_actions.len) orelse unreachable)
        else
            null,
    });
    return .{ .spawned = .{
        .process = process,
        .process_id = nativeProcessId(child),
        .process_group = process_group,
        .sandbox_coverage = .not_requested,
    } };
}

fn firstFifoAction(system: *System, plan: CommandPlan) ?u32 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    const has_open = for (plan.file_actions) |action| {
        if (action == .open) break true;
    } else false;
    if (!has_open) return null;
    var owned_directory: ?std.Io.Dir = null;
    defer if (owned_directory) |directory| directory.close(system.io);
    const directory = switch (plan.cwd) {
        .inherit => std.Io.Dir.cwd(),
        .path => |path| dir: {
            owned_directory = std.Io.Dir.cwd().openDir(system.io, path, .{}) catch return null;
            break :dir owned_directory.?;
        },
    };
    for (plan.file_actions, 0..) |action, index| {
        if (action != .open) continue;
        const stat = directory.statFile(system.io, action.open.path, .{}) catch continue;
        if (stat.kind == .named_pipe) return std.math.cast(u32, index);
    }
    return null;
}

fn nativeProcessId(child: std.process.Child) ?runtime_types.ProcessId {
    if (builtin.os.tag == .wasi) return null;
    if (builtin.os.tag != .windows)
        return @enumFromInt(std.math.cast(u32, child.id orelse return null) orelse return null);

    const windows = std.os.windows;
    var info: windows.PROCESS.BASIC_INFORMATION = undefined;
    if (windows.ntdll.NtQueryInformationProcess(
        child.id orelse return null,
        .BasicInformation,
        &info,
        @sizeOf(windows.PROCESS.BASIC_INFORMATION),
        null,
    ) != .SUCCESS) return null;
    return @enumFromInt(std.math.cast(u32, info.UniqueProcessId) orelse return null);
}

fn openFile(
    userdata: ?*anyopaque,
    cwd: CommandPlan.WorkingDirectory,
    open: CommandPlan.FileAction.Open,
) Host.SpawnError!Host.OpenFileOutcome {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    var working_directory: ?std.Io.Dir = null;
    defer if (working_directory) |directory| directory.close(system.io);
    working_directory = switch (cwd) {
        .inherit => null,
        .path => |path| std.Io.Dir.cwd().openDir(system.io, path, .{}) catch |err| {
            return .{ .failed = fileActionReason(err) orelse return error.Unexpected };
        },
    };
    const directory = working_directory orelse std.Io.Dir.cwd();
    const file = openRedirectFile(system.io, directory, open) catch |err| {
        return .{ .failed = fileActionReason(err) orelse return error.Unexpected };
    };
    errdefer file.close(system.io);

    const resource = try system.registerResource(.{
        .storage = .{ .file = file },
        .writer = if (open.access == .read)
            null
        else
            file.writerStreaming(system.io, &.{}),
        .readable = open.access != .write,
    });
    return .{ .opened = resource };
}

fn registerResource(system: *System, initial: FileResource) std.mem.Allocator.Error!CommandPlan.Resource {
    system.resource_mutex.lockUncancelable(system.io);
    defer system.resource_mutex.unlock(system.io);
    const data = try system.gpa.create(FileResource);
    errdefer system.gpa.destroy(data);
    try system.resources.ensureUnusedCapacity(system.gpa, 1);
    data.* = initial;
    const resource: CommandPlan.Resource = @enumFromInt(system.next_resource);
    system.next_resource +%= 1;
    system.resources.putAssumeCapacityNoClobber(resource, data);
    return resource;
}

fn createCapture(userdata: ?*anyopaque) Host.Error!CommandPlan.Resource {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const resource = try createInput(userdata, &.{});
    system.resource_mutex.lockUncancelable(system.io);
    defer system.resource_mutex.unlock(system.io);
    const data = system.resources.get(resource).?;
    data.writer = data.file().writerStreaming(system.io, &.{});
    data.positional_read = true;
    return resource;
}

fn createInput(userdata: ?*anyopaque, bytes: []const u8) Host.Error!CommandPlan.Resource {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const permissions: std.Io.File.Permissions = switch (builtin.os.tag) {
        .windows => .default_file,
        else => .fromMode(0o600),
    };
    var temporary_dir = system.inputResourceDirectory();
    var owns_temporary_dir = temporary_dir.close;
    errdefer if (owns_temporary_dir) temporary_dir.dir.close(system.io);
    const temporary = while (true) {
        var basename_hex: u64 = undefined;
        system.io.random(std.mem.asBytes(&basename_hex));
        const basename = std.fmt.hex(basename_hex);
        const file = temporary_dir.dir.createFile(system.io, &basename, .{
            .read = true,
            .exclusive = true,
            .permissions = permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists, error.FileBusy, error.DeviceBusy => continue,
            else => return error.ResourceUnavailable,
        };
        break FileResource.Storage.TemporaryFile{
            .file = file,
            .cleanup = .{
                .dir = temporary_dir.dir,
                .close_dir = temporary_dir.close,
                .basename_hex = basename_hex,
            },
        };
    };
    var owned_temporary = temporary;
    owns_temporary_dir = false;
    errdefer owned_temporary.deinit(system.io);
    // Unlink immediately when the platform permits it. The open handle stays
    // usable by children; platforms that reject this keep the exclusive 0600
    // name until resource teardown.
    const cleanup = owned_temporary.cleanup.?;
    const basename = std.fmt.hex(cleanup.basename_hex);
    if (cleanup.dir.deleteFile(system.io, &basename)) {
        if (cleanup.close_dir) cleanup.dir.close(system.io);
        owned_temporary.cleanup = null;
    } else |_| {}

    owned_temporary.file.writeStreamingAll(system.io, bytes) catch
        return error.ResourceUnavailable;
    var writer = owned_temporary.file.writerStreaming(system.io, &.{});
    writer.seekTo(0) catch return error.ResourceUnavailable;

    return system.registerResource(.{
        .storage = .{ .temporary = owned_temporary },
        .writer = null,
        .readable = true,
    });
}

const InputResourceDirectory = struct {
    dir: std.Io.Dir,
    close: bool,
};

fn inputResourceDirectory(system: *System) InputResourceDirectory {
    if (system.environ_map) |environment| {
        const configured_path = switch (builtin.os.tag) {
            .windows => environment.get("TEMP") orelse environment.get("TMP"),
            else => environment.get("TMPDIR"),
        };
        if (configured_path) |path| {
            if (path.len != 0) {
                const dir = if (std.fs.path.isAbsolute(path))
                    std.Io.Dir.openDirAbsolute(system.io, path, .{})
                else
                    std.Io.Dir.cwd().openDir(system.io, path, .{});
                if (dir) |opened| return .{ .dir = opened, .close = true } else |_| {}
            }
        }
    }
    if (builtin.os.tag != .windows) {
        if (std.Io.Dir.openDirAbsolute(system.io, "/tmp", .{})) |dir|
            return .{ .dir = dir, .close = true }
        else |_| {}
    }
    return .{ .dir = .cwd(), .close = false };
}

fn closeResource(userdata: ?*anyopaque, resource: CommandPlan.Resource) void {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const data = blk: {
        system.resource_mutex.lockUncancelable(system.io);
        defer system.resource_mutex.unlock(system.io);
        break :blk system.resources.fetchRemove(resource) orelse return;
    };
    // Closing a file can block; no table lock is held after removing it.
    data.value.deinit(system.io);
    system.gpa.destroy(data.value);
}

fn resourceWriter(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Writer {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    system.resource_mutex.lockUncancelable(system.io);
    defer system.resource_mutex.unlock(system.io);
    const data = system.resources.get(resource) orelse return null;
    const writer = &(data.writer orelse return null);
    return &writer.interface;
}

fn resourceReader(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Reader {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    system.resource_mutex.lockUncancelable(system.io);
    defer system.resource_mutex.unlock(system.io);
    const data = system.resources.get(resource) orelse return null;
    if (!data.readable) return null;
    if (data.reader == null) data.reader = if (data.positional_read)
        data.file().reader(system.io, &data.read_buffer)
    else
        data.file().readerStreaming(system.io, &data.read_buffer);
    const reader = &(data.reader orelse return null);
    return &reader.interface;
}

const StdioBinding = union(enum) {
    inherit: CommandPlan.FileDescriptor,
    file: std.Io.File,
    close,
};

fn needsWindowsHandleSpawn(bindings: [3]StdioBinding) bool {
    for (bindings, 0..) |binding, index| switch (binding) {
        .file => return true,
        .inherit => |source| if (stdioIndex(source).? != index) return true,
        .close => {},
    };
    return false;
}

fn bindingFile(binding: StdioBinding) ?std.Io.File {
    return switch (binding) {
        .inherit => |source| stdioFile(source),
        .file => |file| file,
        .close => null,
    };
}

fn spawnStdio(
    binding: StdioBinding,
    target: CommandPlan.FileDescriptor,
) std.process.SpawnOptions.StdIo {
    return switch (binding) {
        .inherit => |source| if (source == target)
            .inherit
        else
            .{ .file = stdioFile(source) },
        .file => |file| .{ .file = file },
        .close => .close,
    };
}

fn stdioFile(descriptor: CommandPlan.FileDescriptor) std.Io.File {
    return switch (descriptor) {
        .stdin => .stdin(),
        .stdout => .stdout(),
        .stderr => .stderr(),
        else => unreachable,
    };
}

fn stdioIndex(descriptor: CommandPlan.FileDescriptor) ?usize {
    return switch (descriptor) {
        .stdin => 0,
        .stdout => 1,
        .stderr => 2,
        else => null,
    };
}

fn openRedirectFile(
    io: std.Io,
    directory: std.Io.Dir,
    open: CommandPlan.FileAction.Open,
) !std.Io.File {
    const absolute = std.fs.path.isAbsolute(open.path);
    return switch (open.disposition) {
        .open_existing => if (absolute)
            std.Io.Dir.openFileAbsolute(io, open.path, .{
                .mode = openMode(open.access),
                .allow_directory = false,
            })
        else
            directory.openFile(io, open.path, .{
                .mode = openMode(open.access),
                .allow_directory = false,
            }),
        .create_or_open => createRedirectFile(io, directory, open, absolute, false, false),
        .create_or_truncate => createRedirectFile(io, directory, open, absolute, true, false),
        .create_or_append => append_file.open(
            io,
            directory,
            open.path,
            absolute,
            open.access == .read_write,
        ),
        .create_exclusive => createRedirectFile(io, directory, open, absolute, true, true),
    };
}

fn createRedirectFile(
    io: std.Io,
    directory: std.Io.Dir,
    open: CommandPlan.FileAction.Open,
    absolute: bool,
    truncate: bool,
    exclusive: bool,
) !std.Io.File {
    if (open.access == .read) return error.AccessDenied;
    const options: std.Io.Dir.CreateFileOptions = .{
        .read = open.access == .read_write,
        .truncate = truncate,
        .exclusive = exclusive,
    };
    return if (absolute)
        std.Io.Dir.createFileAbsolute(io, open.path, options)
    else
        directory.createFile(io, open.path, options);
}

fn openMode(access: CommandPlan.FileAction.Open.Access) std.Io.Dir.OpenFileOptions.Mode {
    return switch (access) {
        .read => .read_only,
        .write => .write_only,
        .read_write => .read_write,
    };
}

fn fileActionFailure(
    action_index: u32,
    reason: Host.FileActionFailure.Reason,
) Host.SpawnOutcome {
    return .{ .failed = .{ .file_action = .{
        .action_index = action_index,
        .reason = reason,
    } } };
}

fn fileActionReason(err: anyerror) ?Host.FileActionFailure.Reason {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.NetworkNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied, error.IsDir => .access_denied,
        error.InvalidName, error.BadPathName, error.NameTooLong => .invalid_path,
        error.PathAlreadyExists => .path_already_exists,
        error.NoDevice,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.FileBusy,
        error.PipeBusy,
        => .resource_unavailable,
        error.Unseekable, error.OperationUnsupported => .unsupported,
        else => null,
    };
}

fn prepareEnvironment(
    system: *System,
    environment: CommandPlan.Environment,
) Host.SpawnError!?std.process.Environ.Map {
    return switch (environment) {
        .inherit => null,
        .overlay => |variables| map: {
            if (variables.len == 0) break :map null;
            const parent = system.environ_map orelse return error.InvalidArguments;
            var map = parent.clone(system.gpa) catch return error.OutOfMemory;
            errdefer map.deinit();
            try applyEnvironmentVariables(&map, variables);
            break :map map;
        },
        .replace => |variables| map: {
            var map = std.process.Environ.Map.init(system.gpa);
            errdefer map.deinit();
            try applyEnvironmentVariables(&map, variables);
            break :map map;
        },
    };
}

fn applyEnvironmentVariables(
    map: *std.process.Environ.Map,
    variables: []const CommandPlan.EnvironmentVariable,
) Host.SpawnError!void {
    for (variables) |variable| {
        if (!std.process.Environ.Map.validateKeyForPut(variable.name))
            return error.InvalidArguments;
        map.put(variable.name, variable.value) catch return error.OutOfMemory;
    }
}

fn wait(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    while (true) {
        if (try tryWait(userdata, process)) |termination| {
            if (termination != .stopped) return termination;
        }
        // Child.wait may clean up its native handle even on cancellation.
        // Polling retains ownership until a terminal result has been observed.
        try std.Io.sleep(system.io, .fromMilliseconds(2), .awake);
    }
}

fn reapWindows(system: *System, process: Host.Process) Host.Error!Host.Termination {
    const record = system.children.getPtr(process) orelse return error.InvalidArguments;
    const group = record.process_group;
    // Called only after the process handle is signaled. Finish the native
    // cleanup atomically with respect to task cancellation.
    const previous_protection = system.io.swapCancelProtection(.blocked);
    defer _ = system.io.swapCancelProtection(previous_protection);
    const termination = record.child.wait(system.io) catch |err| return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
    _ = system.children.remove(process);
    system.discardTerminalModesIfUnowned(group);
    return switch (termination) {
        .exited => |status| .{ .exited = status },
        .signal => |native_signal| .{ .signal = @intFromEnum(native_signal) },
        .stopped => |native_signal| .{ .stopped = @intFromEnum(native_signal) },
        .unknown => |status| .{ .unknown = status },
    };
}

fn tryWait(userdata: ?*anyopaque, process: Host.Process) Host.Error!?Host.Termination {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const record = system.children.getPtr(process) orelse return error.InvalidArguments;
    if (builtin.os.tag == .windows) return tryWaitWindows(system, process, record);
    if (builtin.os.tag == .wasi) return error.Unsupported;
    return tryWaitPosix(system, process, record);
}

fn waitEvent(userdata: ?*anyopaque, process: Host.Process) Host.Error!Host.Termination {
    return (try waitAny(userdata, &.{process})).termination;
}

fn waitAny(userdata: ?*anyopaque, processes: []const Host.Process) Host.Error!Host.ProcessEvent {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (processes.len == 0) return error.InvalidArguments;
    if (builtin.os.tag == .wasi) return error.Unsupported;
    for (processes) |process| {
        if (!system.children.contains(process)) return error.InvalidArguments;
    }
    while (true) {
        for (processes) |process| {
            if (try system.host().tryWait(process)) |termination| return .{
                .process = process,
                .termination = termination,
            };
        }
        try std.Io.sleep(system.io, .fromMilliseconds(2), .awake);
    }
}

fn tryWaitPosix(
    system: *System,
    process: Host.Process,
    record: *ChildRecord,
) Host.Error!?Host.Termination {
    return waitForPosix(system, process, record, std.posix.W.NOHANG | std.posix.W.UNTRACED);
}

fn waitForPosix(
    system: *System,
    process: Host.Process,
    record: *ChildRecord,
    flags: u32,
) Host.Error!?Host.Termination {
    const pid = record.child.id orelse return error.InvalidArguments;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, @intCast(flags));
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                const bits: u32 = @bitCast(status);
                var result: Host.Termination = if (std.posix.W.IFEXITED(bits))
                    .{ .exited = std.posix.W.EXITSTATUS(bits) }
                else if (std.posix.W.IFSIGNALED(bits))
                    .{ .signal = @intFromEnum(std.posix.W.TERMSIG(bits)) }
                else if (std.posix.W.IFSTOPPED(bits))
                    .{ .stopped = @intFromEnum(std.posix.W.STOPSIG(bits)) }
                else
                    return error.Unexpected;
                switch (result) {
                    .exited, .signal => {
                        const group = record.process_group;
                        const report = record.report;
                        cleanupWaitedChildPosix(&record.child, system.io);
                        _ = system.children.remove(process);
                        system.discardTerminalModesIfUnowned(group);
                        if (report) |startup| {
                            if (startup.read()) |failure| {
                                if (failure) |reported| result = .{ .spawn_failed = reported };
                            } else |_| {
                                // waitpid already consumed the process. Return
                                // a terminal result so upper layers release its
                                // handle even when the private protocol failed.
                                result = .{ .unknown = 0 };
                            }
                        }
                    },
                    .stopped => {},
                    .unknown, .spawn_failed => unreachable,
                }
                return result;
            },
            .INTR => continue,
            .CHILD => return error.InvalidArguments,
            else => return error.Unexpected,
        }
    }
}

fn cleanupWaitedChildPosix(child: *std.process.Child, io: std.Io) void {
    if (child.stdin) |file| file.close(io);
    if (child.stdout) |file| file.close(io);
    if (child.stderr) |file| file.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    child.id = null;
}

fn tryWaitWindows(
    system: *System,
    process: Host.Process,
    record: *ChildRecord,
) Host.Error!?Host.Termination {
    const windows = std.os.windows;
    const handle = record.child.id orelse return error.InvalidArguments;
    const timeout: windows.LARGE_INTEGER = 0;
    return switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &timeout)) {
        windows.NTSTATUS.WAIT_0 => try reapWindows(system, process),
        .TIMEOUT => null,
        .ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn signal(userdata: ?*anyopaque, process: Host.Process, requested: Host.Signal) Host.Error!void {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const record = system.children.getPtr(process) orelse return error.InvalidArguments;
    if (builtin.os.tag == .windows) return signalWindows(record, requested);
    if (builtin.os.tag == .wasi) return error.Unsupported;
    return signalPosix(record, requested);
}

fn signalGroup(
    userdata: ?*anyopaque,
    group: CommandPlan.ProcessGroup,
    requested: Host.Signal,
) Host.Error!void {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
    if (!system.ownsProcessGroup(group)) return error.InvalidArguments;
    const pgid = std.math.cast(std.posix.pid_t, @intFromEnum(group)) orelse
        return error.InvalidArguments;
    if (pgid <= 0) return error.InvalidArguments;
    const native: std.posix.SIG = switch (requested) {
        .interrupt => .INT,
        .terminate => .TERM,
        .kill => .KILL,
        .stop => .STOP,
        .cont => .CONT,
    };
    std.posix.kill(-pgid, native) catch |err| return switch (err) {
        error.ProcessNotFound => return,
        error.PermissionDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn acquireTerminal(userdata: ?*anyopaque, group: CommandPlan.ProcessGroup) Host.Error!Host.TerminalLease {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
    if (system.terminal_lease != null) return error.ResourceUnavailable;
    if (!system.ownsProcessGroup(group)) return error.InvalidArguments;
    const pgid = std.math.cast(std.posix.pid_t, @intFromEnum(group)) orelse
        return error.InvalidArguments;
    if (pgid <= 0) return error.InvalidArguments;
    // Release must be able to save a stopped job's modes without allocating.
    if (!system.job_terminal_modes.contains(group))
        try system.job_terminal_modes.ensureUnusedCapacity(system.gpa, 1);

    const tty = std.Io.Dir.openFileAbsolute(system.io, "/dev/tty", .{
        .mode = .read_write,
        .allow_ctty = false,
    }) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.FileNotFound, error.NoDevice => error.Unsupported,
        else => error.ResourceUnavailable,
    };
    errdefer tty.close(system.io);
    const previous = terminal.foregroundGroup(tty) catch |err| return mapTerminalError(err);
    const shell_group = terminal.currentProcessGroup() catch |err| return mapTerminalError(err);
    if (previous != shell_group) return error.AccessDenied;
    const shell_modes = terminal.getModes(tty) catch |err| return mapTerminalError(err);
    errdefer terminal.setModes(tty, shell_modes) catch {};
    if (system.job_terminal_modes.get(group)) |job_modes|
        terminal.setModes(tty, job_modes) catch |err| return mapTerminalError(err);
    terminal.setForegroundGroup(tty, pgid) catch |err| return mapTerminalError(err);

    const token: Host.TerminalLease = @enumFromInt(system.next_terminal_lease);
    system.next_terminal_lease +%= 1;
    if (system.next_terminal_lease == 0) system.next_terminal_lease = 1;
    system.terminal_lease = .{
        .token = token,
        .tty = tty,
        .group = group,
        .previous_group = @intCast(previous),
        .shell_modes = shell_modes,
    };
    return token;
}

fn releaseTerminal(userdata: ?*anyopaque, token: Host.TerminalLease) Host.Error!void {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
    const lease = &(system.terminal_lease orelse return error.InvalidArguments);
    if (lease.token != token) return error.InvalidArguments;
    if (!lease.foreground_restored) {
        // Completed groups have no future resume, so keep no stale mode entry.
        if (system.ownsProcessGroup(lease.group)) {
            if (terminal.getModes(lease.tty)) |job_modes| {
                system.job_terminal_modes.putAssumeCapacity(lease.group, job_modes);
            } else |_| {}
        }
        const previous: std.posix.pid_t = @intCast(lease.previous_group);
        terminal.setForegroundGroup(lease.tty, previous) catch |err| return mapTerminalError(err);
        lease.foreground_restored = true;
    }
    terminal.setModes(lease.tty, lease.shell_modes) catch |err| return mapTerminalError(err);
    lease.tty.close(system.io);
    system.terminal_lease = null;
}

fn mapTerminalError(err: terminal.Error) Host.Error {
    return switch (err) {
        error.NotATerminal => error.Unsupported,
        error.PermissionDenied => error.AccessDenied,
        error.InvalidGroup => error.InvalidArguments,
        error.Unexpected => error.Unexpected,
    };
}

fn signalPosix(record: *ChildRecord, requested: Host.Signal) Host.Error!void {
    const pid = record.child.id orelse return error.InvalidArguments;
    const native: std.posix.SIG = switch (requested) {
        .interrupt => .INT,
        .terminate => .TERM,
        .kill => .KILL,
        .stop => .STOP,
        .cont => .CONT,
    };
    std.posix.kill(pid, native) catch |err| return switch (err) {
        // An owned child can have exited between lookup and delivery; wait
        // still owns and reaps it.
        error.ProcessNotFound => return,
        error.PermissionDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn signalWindows(record: *ChildRecord, requested: Host.Signal) Host.Error!void {
    const windows = std.os.windows;
    const code: u32 = switch (requested) {
        .terminate => 143,
        .kill => 137,
        else => return error.Unsupported,
    };
    const handle = record.child.id orelse return error.InvalidArguments;
    switch (windows.ntdll.NtTerminateProcess(handle, @enumFromInt(code))) {
        .SUCCESS, .PROCESS_IS_TERMINATING => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => return error.Unexpected,
    }
}

fn ownsProcessGroup(system: *System, group: CommandPlan.ProcessGroup) bool {
    var records = system.children.valueIterator();
    while (records.next()) |record| {
        if (record.process_group) |owned| {
            if (owned == group) return true;
        }
    }
    return false;
}

fn discardTerminalModesIfUnowned(system: *System, maybe_group: ?CommandPlan.ProcessGroup) void {
    const group = maybe_group orelse return;
    if (!system.ownsProcessGroup(group)) _ = system.job_terminal_modes.remove(group);
}

fn nextProcess(system: *System) Host.Process {
    while (true) {
        const process: Host.Process = @enumFromInt(system.next_process);
        system.next_process +%= 1;
        if (system.next_process == 0) system.next_process = 1;
        if (!system.children.contains(process)) return process;
    }
}

fn mapSpawnFailure(err: std.process.SpawnError) Host.SpawnError!Host.SpawnFailure {
    return switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => .command_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.InvalidExe, error.IsDir => .invalid_executable,
        error.NoDevice,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ResourceLimitReached,
        => .resource_unavailable,
        error.OperationUnsupported => .unsupported,
        error.InvalidWtf8,
        error.InvalidBatchScriptArg,
        error.InvalidName,
        error.InvalidProcessGroupId,
        error.ProcessAlreadyExec,
        error.BadPathName,
        error.NameTooLong,
        => return error.InvalidArguments,
        else => return error.Unexpected,
    };
}

fn resolveWorkingDirectory(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Host.WorkingDirectoryRequest,
) Host.Error![]u8 {
    const system: *System = @ptrCast(@alignCast(userdata.?));

    const resolved = if (std.fs.path.isAbsolute(request.path))
        try std.fs.path.resolve(allocator, &.{request.path})
    else if (request.current) |current|
        if (std.fs.path.isAbsolute(current))
            try std.fs.path.resolve(allocator, &.{ current, request.path })
        else
            try resolveFromProcessDirectory(system.io, allocator, &.{ current, request.path })
    else
        try resolveFromProcessDirectory(system.io, allocator, &.{request.path});
    errdefer allocator.free(resolved);

    const directory = std.Io.Dir.cwd().openDir(system.io, resolved, .{
        .access_sub_paths = false,
    }) catch |err| return mapOpenDirectoryError(err);
    directory.close(system.io);
    return resolved;
}

fn resolveFromProcessDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) Host.Error![]u8 {
    std.debug.assert(paths.len <= 2);
    const process_directory = std.process.currentPathAlloc(io, allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CurrentDirUnlinked => error.InvalidArguments,
        else => error.Unexpected,
    };
    defer allocator.free(process_directory);

    var all_paths: [3][]const u8 = undefined;
    all_paths[0] = process_directory;
    @memcpy(all_paths[1..][0..paths.len], paths);
    return std.fs.path.resolve(allocator, all_paths[0 .. paths.len + 1]);
}

fn mapOpenDirectoryError(err: std.Io.Dir.OpenError) Host.Error {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NoDevice,
        error.SystemResources,
        => error.ResourceUnavailable,
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        error.NetworkNotFound,
        error.NameTooLong,
        error.BadPathName,
        => error.InvalidArguments,
        else => error.Unexpected,
    };
}

test "system host resolves and validates working directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "child", .default_dir);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    const expected = try std.fs.path.resolve(std.testing.allocator, &.{ root_path, "child" });
    defer std.testing.allocator.free(expected);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = root_path,
        .path = "child" ++ std.fs.path.sep_str ++ ".." ++ std.fs.path.sep_str ++ "child",
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "directory snapshots use explicit cwd and own entry names" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "child", .default_dir);
    for ([_][]const u8{ "child/visible", "child/.hidden", "file" }) |path| {
        const file = try temporary.dir.createFile(std.testing.io, path, .{});
        file.close(std.testing.io);
    }
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &buffer);
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const cwd: CommandPlan.WorkingDirectory = .{ .path = buffer[0..length] };
    const entries = (try system.host().readDirectory(std.testing.allocator, cwd, "child")).?;
    defer entries.deinit(std.testing.allocator);
    try temporary.dir.deleteFile(std.testing.io, "child/visible");
    try std.testing.expectEqual(@as(usize, 2), entries.names.len);
    for (entries.names) |name|
        try std.testing.expect(std.mem.eql(u8, name, "visible") or std.mem.eql(u8, name, ".hidden"));
    try std.testing.expect((try system.host().readDirectory(std.testing.allocator, cwd, "missing")) == null);
    try std.testing.expect((try system.host().readDirectory(std.testing.allocator, cwd, "file")) == null);
}

test "system host accepts absolute directories independently of shell state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = "relative-shell-directory",
        .path = path,
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(path, resolved);
}

test "system host uses the process directory when shell state is unavailable" {
    const expected = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const resolved = try system.host().resolveWorkingDirectory(std.testing.allocator, .{
        .current = null,
        .path = ".",
    });
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "system host rejects missing paths and non-directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "file", .{});
    file.close(std.testing.io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.resolveWorkingDirectory(std.testing.allocator, .{
            .current = root_path,
            .path = "missing",
        }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.resolveWorkingDirectory(std.testing.allocator, .{
            .current = root_path,
            .path = "file",
        }),
    );
}

test "system host working-directory resolution handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveWithAllocator,
        .{ system.host(), root_buffer[0..root_len] },
    );
}

fn resolveWithAllocator(
    allocator: std.mem.Allocator,
    system_host: Host,
    current: []const u8,
) !void {
    const resolved = try system_host.resolveWorkingDirectory(allocator, .{
        .current = current,
        .path = ".",
    });
    defer allocator.free(resolved);
}

test "system host owns foreground processes until wait" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();

    const spawned = (try system_host.spawn(exitCommand(23))).spawned;
    try std.testing.expectEqual(@as(usize, 1), system.children.count());
    try std.testing.expectEqual(@as(?CommandPlan.ProcessGroup, null), spawned.process_group);
    try std.testing.expectEqual(.not_requested, spawned.sandbox_coverage);
    try std.testing.expect(spawned.process_id != null);
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(
            @as(u32, @intCast(system.children.get(spawned.process).?.child.id.?)),
            @intFromEnum(spawned.process_id.?),
        );
    }

    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 23 },
        try system_host.wait(spawned.process),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.wait(spawned.process),
    );
}

test "canceled native waits retain the child for later reaping" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const CanceledSleep = struct {
        fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var io_vtable = std.testing.io.vtable.*;
    io_vtable.sleep = CanceledSleep.sleep;
    var system: System = .{
        .gpa = std.testing.allocator,
        .io = .{ .userdata = std.testing.io.userdata, .vtable = &io_vtable },
    };
    defer system.deinit();
    const system_host = system.host();
    const input = try system_host.createPipe();
    defer system_host.closeResource(input.read_end);
    defer system_host.closeResource(input.write_end);
    const spawned = (try system_host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "/bin/sh", "-c", "read value; exit 23" },
        .file_actions = &.{.{ .use_resource = .{ .resource = input.read_end, .target = .stdin } }},
    })).spawned;
    system_host.closeResource(input.read_end);

    try std.testing.expectError(error.Canceled, system_host.waitAny(&.{spawned.process}));
    try std.testing.expectError(error.Canceled, system_host.waitEvent(spawned.process));
    try std.testing.expectError(error.Canceled, system_host.wait(spawned.process));
    try std.testing.expect(system.children.contains(spawned.process));
    try std.testing.expect(system.children.get(spawned.process).?.child.id != null);
    system.io = std.testing.io;
    system_host.closeResource(input.write_end);
    try std.testing.expectEqualDeep(Host.Termination{ .exited = 23 }, try system_host.wait(spawned.process));
    try std.testing.expect(!system.children.contains(spawned.process));
}

test "system host polls and reaps an exited child once" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    try std.testing.expect(system_host.capabilities().poll);

    const spawned = (try system_host.spawn(exitCommand(23))).spawned;
    var result: ?Host.Termination = null;
    for (0..1000) |_| {
        result = try system_host.tryWait(spawned.process);
        if (result != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqualDeep(Host.Termination{ .exited = 23 }, result.?);
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
    try std.testing.expectError(error.InvalidArguments, system_host.wait(spawned.process));
}

test "system host keeps a stopped POSIX child until it resumes and exits" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    try std.testing.expect(system_host.capabilities().signals);
    const input = try system_host.createPipe();
    defer system_host.closeResource(input.read_end);
    defer system_host.closeResource(input.write_end);

    const spawned = (try system_host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "shell-spelling", "-c", "read value; exit 0" },
        .file_actions = &.{.{ .use_resource = .{
            .resource = input.read_end,
            .target = .stdin,
        } }},
    })).spawned;
    system_host.closeResource(input.read_end);
    try system_host.signal(spawned.process, .stop);

    var stopped: ?Host.Termination = null;
    for (0..1000) |_| {
        stopped = try system_host.tryWait(spawned.process);
        if (stopped != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqualDeep(
        Host.Termination{ .stopped = @intFromEnum(std.posix.SIG.STOP) },
        stopped.?,
    );
    try std.testing.expectEqual(@as(usize, 1), system.children.count());
    try system_host.signal(spawned.process, .cont);
    system_host.closeResource(input.write_end);
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 0 },
        try system_host.wait(spawned.process),
    );
}

test "system host waits for the stopped child among several owned processes" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const input = try system_host.createPipe();
    defer system_host.closeResource(input.read_end);
    defer system_host.closeResource(input.write_end);

    const blocked = (try system_host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "shell-spelling", "-c", "read value; exit 0" },
        .file_actions = &.{.{ .use_resource = .{
            .resource = input.read_end,
            .target = .stdin,
        } }},
    })).spawned;
    system_host.closeResource(input.read_end);
    const stopping = (try system_host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "shell-spelling", "-c", "kill -STOP $$; exit 0" },
    })).spawned;

    try std.testing.expectError(error.InvalidArguments, system_host.waitAny(&.{}));
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.waitAny(&.{ blocked.process, @enumFromInt(std.math.maxInt(u32)) }),
    );
    try std.testing.expectEqualDeep(Host.ProcessEvent{
        .process = stopping.process,
        .termination = .{ .stopped = @intFromEnum(std.posix.SIG.STOP) },
    }, try system_host.waitAny(&.{ blocked.process, stopping.process }));
    try system_host.signal(stopping.process, .cont);
    system_host.closeResource(input.write_end);
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 0 },
        try system_host.wait(stopping.process),
    );
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 0 },
        try system_host.wait(blocked.process),
    );
}

test "system host creates a POSIX process group" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const input = try system_host.createPipe();
    defer system_host.closeResource(input.read_end);
    defer system_host.closeResource(input.write_end);

    const spawned = (try system_host.spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "shell-spelling", "-c", "read value" },
        .file_actions = &.{.{ .use_resource = .{
            .resource = input.read_end,
            .target = .stdin,
        } }},
        .process_group = .create,
    })).spawned;
    try system.job_terminal_modes.put(
        std.testing.allocator,
        spawned.process_group.?,
        std.mem.zeroes(TerminalModes),
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(system.children.get(spawned.process).?.child.id.?)),
        @intFromEnum(spawned.process_group.?),
    );

    var join_plan = exitCommand(0);
    join_plan.process_group = .{ .join = spawned.process_group.? };
    const joined = (try system_host.spawn(join_plan)).spawned;
    try std.testing.expectEqual(spawned.process_group, joined.process_group);
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = 0 },
        try system_host.wait(joined.process),
    );
    try std.testing.expect(system.job_terminal_modes.contains(spawned.process_group.?));
    try system_host.signalGroup(spawned.process_group.?, .stop);
    try std.testing.expectEqualDeep(
        Host.Termination{ .stopped = @intFromEnum(std.posix.SIG.STOP) },
        try system_host.waitEvent(spawned.process),
    );
    try std.testing.expectEqual(@as(usize, 1), system.children.count());
    try system_host.signalGroup(spawned.process_group.?, .cont);
    system_host.closeResource(input.write_end);
    _ = try system_host.wait(spawned.process);
    try std.testing.expect(!system.job_terminal_modes.contains(spawned.process_group.?));
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.signalGroup(spawned.process_group.?, .stop),
    );
    try std.testing.expectError(error.InvalidArguments, system_host.spawn(join_plan));
}

test "system host requires an owned group for terminal handoff" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const unknown: CommandPlan.ProcessGroup = @enumFromInt(424242);
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        try std.testing.expectError(error.Unsupported, system_host.acquireTerminal(unknown));
        return;
    }
    try std.testing.expect(system_host.capabilities().terminal_control);
    try std.testing.expectError(error.InvalidArguments, system_host.acquireTerminal(unknown));
    try std.testing.expectError(
        error.InvalidArguments,
        system_host.releaseTerminal(@enumFromInt(1)),
    );
}

test "system host reports missing executables" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const missing = "habush-executable-that-does-not-exist";

    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .command_not_found },
        try system.host().spawn(.{ .executable = missing, .argv = &.{missing} }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host rejects process features before spawning" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const executable = exitCommand(0).executable;
    const argv = exitCommand(0).argv;
    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .{ .file_action = .{
            .action_index = 0,
            .reason = .unsupported,
        } } },
        try system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .file_actions = &.{.{ .use_resource = .{
                .resource = @enumFromInt(1),
                .target = .stdout,
            } }},
        }),
    );
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        try std.testing.expectEqualDeep(
            Host.SpawnOutcome{ .failed = .unsupported },
            try system_host.spawn(.{
                .executable = executable,
                .argv = argv,
                .process_group = .create,
            }),
        );
    }
    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .sandbox_unavailable },
        try system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .sandbox = .{ .restrict = .{} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host applies output file actions relative to the command directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();

    var first = outputCommand("first");
    first.cwd = .{ .path = directory };
    first.file_actions = &.{.{ .open = .{
        .path = "output.txt",
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_truncate,
    } }};
    try expectExitStatus(system_host, first, 0);

    var second = outputCommand("second");
    second.cwd = .{ .path = directory };
    second.file_actions = &.{.{ .open = .{
        .path = "output.txt",
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_append,
    } }};
    try expectExitStatus(system_host, second, 0);

    const output = try temporary.dir.readFileAlloc(
        std.testing.io,
        "output.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        if (builtin.os.tag == .windows) "first\r\nsecond\r\n" else "firstsecond",
        output,
    );
}

test "system host shares scoped output resources with child processes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const opened = try system_host.openFile(.{ .path = directory }, .{
        .path = "scoped.txt",
        .target = .stdout,
        .access = .write,
        .disposition = .create_or_truncate,
    });
    const resource = opened.opened;
    defer system_host.closeResource(resource);

    try system_host.resourceWriter(resource).?.writeAll("builtin");
    var child = outputCommand("external");
    child.file_actions = &.{.{ .use_resource = .{
        .resource = resource,
        .target = .stdout,
    } }};
    try expectExitStatus(system_host, child, 0);

    const output = try temporary.dir.readFileAlloc(
        std.testing.io,
        "scoped.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        if (builtin.os.tag == .windows) "builtinexternal\r\n" else "builtinexternal",
        output,
    );
}

test "system host provides seekable input resources to child processes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const input = try system_host.createInput("here-document contents\n");
    defer system_host.closeResource(input);
    const reader = system_host.resourceReader(input).?;
    try std.testing.expectEqual(@as(u8, 'h'), try reader.takeByte());

    try expectExitStatus(system_host, .{
        .executable = "/bin/cat",
        .argv = &.{"/bin/cat"},
        .cwd = .{ .path = directory },
        .file_actions = &.{
            .{ .use_resource = .{ .resource = input, .target = .stdin } },
            .{ .open = .{
                .path = "output.txt",
                .target = .stdout,
                .access = .write,
                .disposition = .create_or_truncate,
            } },
        },
    }, 0);

    const output = try temporary.dir.readFileAlloc(
        std.testing.io,
        "output.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("ere-document contents\n", output);
}

test "capture reads from zero after both parent and child output exceed a pipe buffer" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();
    const capture = try system_host.createCapture();
    defer system_host.closeResource(capture);
    const writer = system_host.resourceWriter(capture).?;
    const bytes = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');
    try writer.writeAll(bytes);
    try writer.flush();
    var plan = outputCommand("tail");
    plan.file_actions = &.{.{ .use_resource = .{ .resource = capture, .target = .stdout } }};
    try expectExitStatus(system_host, plan, 0);
    const reader = system_host.resourceReader(capture).?;
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    _ = try reader.streamRemaining(&actual.writer);
    try std.testing.expectEqualSlices(u8, bytes, actual.written()[0..bytes.len]);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "tail\r\n" else "tail", actual.written()[bytes.len..]);
}

test "system host creates and closes pipeline resources" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const system_host = system.host();

    const pipeline_pipe = try system_host.createPipe();
    try std.testing.expectEqual(@as(usize, 2), system.resources.count());
    try std.testing.expect(system_host.resourceWriter(pipeline_pipe.read_end) == null);
    try std.testing.expect(system_host.resourceWriter(pipeline_pipe.write_end) != null);
    try std.testing.expect(system_host.resourceReader(pipeline_pipe.read_end) != null);
    try std.testing.expect(system_host.resourceReader(pipeline_pipe.write_end) == null);

    system_host.closeResource(pipeline_pipe.write_end);
    system_host.closeResource(pipeline_pipe.read_end);
    try std.testing.expectEqual(@as(usize, 0), system.resources.count());
}

test "known lookup failures preserve ordered redirect effects and errors" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var plan: CommandPlan = .{
        .executable = "missing",
        .argv = &.{"missing"},
        .cwd = .{ .path = directory_buffer[0..directory_len] },
        .command_failure = .command_not_found,
        .file_actions = &.{
            .{ .open = .{ .path = "first", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
            .{ .open = .{ .path = "second", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
        },
    };
    try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .command_not_found }, try system.host().spawn(plan));
    for ([_][]const u8{ "first", "second" }) |path| {
        const stat = try temporary.dir.statFile(std.testing.io, path, .{});
        try std.testing.expectEqual(@as(u64, 0), stat.size);
    }
    plan.file_actions = &.{
        .{ .open = .{ .path = "absent/output", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
        .{ .open = .{ .path = "never", .target = .stdout, .access = .write, .disposition = .create_or_truncate } },
    };
    try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .{ .file_action = .{ .action_index = 0, .reason = .not_found } } }, try system.host().spawn(plan));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "never", .{}));
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host duplicates redirected standard streams" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var plan = outputBothCommand();
    plan.cwd = .{ .path = directory_buffer[0..directory_len] };
    plan.file_actions = &.{
        .{ .open = .{
            .path = "both.txt",
            .target = .stdout,
            .access = .write,
            .disposition = .create_or_truncate,
        } },
        .{ .duplicate = .{ .source = .stdout, .target = .stderr } },
    };
    try expectExitStatus(system.host(), plan, 0);

    const output = try temporary.dir.readFileAlloc(
        std.testing.io,
        "both.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        if (builtin.os.tag == .windows) "out\r\nerr\r\n" else "outerr",
        output,
    );
}

test "system host preserves file action source order" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);

    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var plan = outputBothCommand();
    plan.cwd = .{ .path = directory_buffer[0..directory_len] };
    plan.file_actions = &.{
        .{ .open = .{
            .path = "before.txt",
            .target = .stdout,
            .access = .write,
            .disposition = .create_or_truncate,
        } },
        .{ .duplicate = .{ .source = .stdout, .target = .stderr } },
        .{ .open = .{
            .path = "after.txt",
            .target = .stdout,
            .access = .write,
            .disposition = .create_or_truncate,
        } },
    };
    try expectExitStatus(system.host(), plan, 0);

    const before = try temporary.dir.readFileAlloc(
        std.testing.io,
        "before.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(before);
    const after = try temporary.dir.readFileAlloc(
        std.testing.io,
        "after.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "err\r\n" else "err", before);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "out\r\n" else "out", after);
}

test "system host identifies a failing input file action" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var plan = exitCommand(0);
    plan.file_actions = &.{.{ .open = .{
        .path = "habush-input-that-does-not-exist",
        .target = .stdin,
        .access = .read,
        .disposition = .open_existing,
    } }};

    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .{ .file_action = .{
            .action_index = 0,
            .reason = .not_found,
        } } },
        try system.host().spawn(plan),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

test "system host prepares replacement and overlay environments" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PARENT", "visible");
    try parent.put("SHARED", "parent");
    var system: System = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &parent,
    };
    defer system.deinit();

    var overlay = (try system.prepareEnvironment(.{ .overlay = &.{
        .{ .name = "CHILD", .value = "visible" },
        .{ .name = "SHARED", .value = "child" },
    } })).?;
    defer overlay.deinit();
    try std.testing.expectEqualStrings("visible", overlay.get("PARENT").?);
    try std.testing.expectEqualStrings("visible", overlay.get("CHILD").?);
    try std.testing.expectEqualStrings("child", overlay.get("SHARED").?);
    try std.testing.expectEqualStrings("parent", parent.get("SHARED").?);

    var replacement = (try system.prepareEnvironment(.{ .replace = &.{
        .{ .name = "ONLY", .value = "replacement" },
    } })).?;
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 1), replacement.count());
    try std.testing.expectEqualStrings("replacement", replacement.get("ONLY").?);
    try std.testing.expect(replacement.get("PARENT") == null);
}

test "system host requires a parent environment for overlays" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        system.host().spawn(.{
            .executable = exitCommand(0).executable,
            .argv = exitCommand(0).argv,
            .environment = .{ .overlay = &.{.{ .name = "NAME", .value = "value" }} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}

fn exitCommand(comptime status: u8) CommandPlan {
    const script = std.fmt.comptimePrint("exit {d}", .{status});
    return switch (@import("builtin").os.tag) {
        .windows => .{
            .executable = "cmd.exe",
            .argv = &.{ "shell-spelling", "/C", script },
        },
        else => .{
            .executable = "/bin/sh",
            .argv = &.{ "shell-spelling", "-c", script },
        },
    };
}

fn outputCommand(comptime output: []const u8) CommandPlan {
    return switch (@import("builtin").os.tag) {
        .windows => .{
            .executable = "cmd.exe",
            .argv = &.{ "shell-spelling", "/D", "/C", "echo " ++ output },
        },
        else => .{
            .executable = "/bin/sh",
            .argv = &.{ "shell-spelling", "-c", "printf " ++ output },
        },
    };
}

fn outputBothCommand() CommandPlan {
    return switch (@import("builtin").os.tag) {
        .windows => .{
            .executable = "cmd.exe",
            .argv = &.{
                "shell-spelling",
                "/D",
                "/C",
                "echo out&echo err>&2",
            },
        },
        else => .{
            .executable = "/bin/sh",
            .argv = &.{ "shell-spelling", "-c", "printf out; printf err >&2" },
        },
    };
}

fn expectExitStatus(system_host: Host, plan: CommandPlan, expected: u8) !void {
    const outcome = try system_host.spawn(plan);
    const spawned = switch (outcome) {
        .spawned => |spawned| spawned,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualDeep(
        Host.Termination{ .exited = expected },
        try system_host.wait(spawned.process),
    );
}

test "malformed worker report still consumes the terminal process handle" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const outcome = try system.host().spawn(.{
        .executable = "/bin/sh",
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
    });
    const process = outcome.spawned.process;
    var channel = try worker_channel.Parent.init(null);
    defer channel.deinit();
    try channel.childInput().writeStreamingAll(std.testing.io, "HBW1");
    system.children.getPtr(process).?.report = channel.takeReport(0);
    const termination = try system.host().wait(process);
    try std.testing.expectEqualDeep(Host.Termination{ .unknown = 0 }, termination);
    try std.testing.expect(!system.children.contains(process));
    try std.testing.expectError(error.InvalidArguments, system.host().tryWait(process));
}

test "startup suspension without a worker is rejected before creating children" {
    var system: System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    const outcome = try system.host().spawn(.{
        .executable = "/bin/cat",
        .argv = &.{"/bin/cat"},
        .suspend_before_execute = true,
    });
    try std.testing.expectEqualDeep(Host.SpawnOutcome{ .failed = .unsupported }, outcome);
    try std.testing.expectEqual(@as(usize, 0), system.children.count());
}
