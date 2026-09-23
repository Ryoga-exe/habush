//! Native `Host` implementation backed by Zig's cross-platform standard APIs.
//!
//! The process backend supports foreground commands and file actions for the
//! three standard descriptors. Process groups, non-standard descriptors, and
//! sandbox restrictions remain explicit unsupported boundaries.

const std = @import("std");
const builtin = @import("builtin");
const CommandPlan = @import("../CommandPlan.zig");
const Host = @import("../Host.zig");
const append_file = @import("System/append_file.zig");
const System = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// Parent process environment used as the base for `.overlay` plans.
/// The caller retains ownership and must keep it alive while this host is used.
environ_map: ?*const std.process.Environ.Map = null,
children: std.AutoHashMapUnmanaged(Host.Process, std.process.Child) = .empty,
resources: std.AutoHashMapUnmanaged(CommandPlan.Resource, *FileResource) = .empty,
next_process: u32 = 1,
next_resource: u32 = 1,

const FileResource = struct {
    storage: Storage,
    writer: ?std.Io.File.Writer,

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

pub fn deinit(system: *System) void {
    var children = system.children.valueIterator();
    while (children.next()) |child| child.kill(system.io);
    system.children.deinit(system.gpa);
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

const vtable: Host.VTable = .{
    .spawn = spawn,
    .wait = wait,
    .open_file = openFile,
    .create_input = createInput,
    .close_resource = closeResource,
    .resource_writer = resourceWriter,
    .resolve_working_directory = resolveWorkingDirectory,
};

fn spawn(userdata: ?*anyopaque, plan: CommandPlan) Host.SpawnError!Host.SpawnOutcome {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    if (plan.process_group != .inherit or plan.sandbox != .inherit)
        return .{ .failed = .unsupported };

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
                const resource = system.resources.get(use.resource) orelse
                    return fileActionFailure(action_index, .unsupported);
                bindings[target] = .{ .file = resource.file() };
            },
        }
    }

    const child_io = [_]std.process.SpawnOptions.StdIo{
        spawnStdio(bindings[0], .stdin),
        spawnStdio(bindings[1], .stdout),
        spawnStdio(bindings[2], .stderr),
    };

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
    const child = std.process.spawn(system.io, .{
        .argv = argv,
        .cwd = switch (plan.cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
        },
        .environ_map = if (environment) |*map| map else null,
        .stdin = child_io[0],
        .stdout = child_io[1],
        .stderr = child_io[2],
    }) catch |err| return .{ .failed = try mapSpawnFailure(err) };

    const process = system.nextProcess();
    system.children.putAssumeCapacityNoClobber(process, child);
    return .{ .spawned = .{
        .process = process,
        .sandbox_coverage = .not_requested,
    } };
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

    const resource_data = try system.gpa.create(FileResource);
    errdefer system.gpa.destroy(resource_data);
    resource_data.* = .{
        .storage = .{ .file = file },
        .writer = if (open.access == .read)
            null
        else
            file.writerStreaming(system.io, &.{}),
    };
    try system.resources.ensureUnusedCapacity(system.gpa, 1);
    const resource: CommandPlan.Resource = @enumFromInt(system.next_resource);
    system.next_resource +%= 1;
    system.resources.putAssumeCapacityNoClobber(resource, resource_data);
    return .{ .opened = resource };
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

    const resource_data = system.gpa.create(FileResource) catch return error.OutOfMemory;
    errdefer system.gpa.destroy(resource_data);
    resource_data.* = .{ .storage = .{ .temporary = owned_temporary }, .writer = null };
    system.resources.ensureUnusedCapacity(system.gpa, 1) catch return error.OutOfMemory;
    const resource: CommandPlan.Resource = @enumFromInt(system.next_resource);
    system.next_resource +%= 1;
    system.resources.putAssumeCapacityNoClobber(resource, resource_data);
    return resource;
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
    const data = system.resources.fetchRemove(resource) orelse return;
    data.value.deinit(system.io);
    system.gpa.destroy(data.value);
}

fn resourceWriter(userdata: ?*anyopaque, resource: CommandPlan.Resource) ?*std.Io.Writer {
    const system: *System = @ptrCast(@alignCast(userdata.?));
    const data = system.resources.get(resource) orelse return null;
    const writer = &(data.writer orelse return null);
    return &writer.interface;
}

const StdioBinding = union(enum) {
    inherit: CommandPlan.FileDescriptor,
    file: std.Io.File,
    close,
};

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
    const child = system.children.getPtr(process) orelse return error.InvalidArguments;
    const termination = child.wait(system.io) catch |err| return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
    _ = system.children.remove(process);
    return switch (termination) {
        .exited => |status| .{ .exited = status },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped => |signal| .{ .stopped = @intFromEnum(signal) },
        .unknown => |status| .{ .unknown = status },
    };
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
    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .unsupported },
        try system_host.spawn(.{
            .executable = executable,
            .argv = argv,
            .process_group = .create,
        }),
    );
    try std.testing.expectEqualDeep(
        Host.SpawnOutcome{ .failed = .unsupported },
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
    try std.testing.expectEqualStrings("firstsecond", output);
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
    try std.testing.expectEqualStrings("builtinexternal", output);
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
    try std.testing.expectEqualStrings("here-document contents\n", output);
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
    try std.testing.expectEqualStrings("outerr", output);
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
    try std.testing.expectEqualStrings("err", before);
    try std.testing.expectEqualStrings("out", after);
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
            .argv = &.{ "shell-spelling", "/D", "/C", "<nul set /p =" ++ output },
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
                "<nul set /p \"=out\" & <nul set /p \"=err\" 1>&2",
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
