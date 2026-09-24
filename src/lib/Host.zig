//! Host operations used by the Habush runtime.
//!
//! This is a shell-domain boundary rather than a replacement for `std.Io`.
//! A system implementation may use `std.Io` internally, while tests and
//! sandbox-enforcing hosts can provide another implementation.

const std = @import("std");
const Host = @This();
const CommandPlan = @import("CommandPlan.zig");
const runtime_types = @import("runtime/types.zig");
const SandboxPolicy = @import("SandboxPolicy.zig");

pub const System = @import("Host/System.zig");

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    spawn: *const fn (?*anyopaque, CommandPlan) SpawnError!SpawnOutcome,
    wait: *const fn (?*anyopaque, Process) Error!Termination,
    open_file: *const fn (
        ?*anyopaque,
        CommandPlan.WorkingDirectory,
        CommandPlan.FileAction.Open,
    ) SpawnError!OpenFileOutcome,
    create_pipe: *const fn (?*anyopaque) Error!Pipe,
    create_input: *const fn (?*anyopaque, []const u8) Error!CommandPlan.Resource,
    close_resource: *const fn (?*anyopaque, CommandPlan.Resource) void,
    resource_writer: *const fn (?*anyopaque, CommandPlan.Resource) ?*std.Io.Writer,
    resolve_working_directory: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        WorkingDirectoryRequest,
    ) Error![]u8 = null,
};

pub const OpenFileOutcome = union(enum) {
    opened: CommandPlan.Resource,
    failed: FileActionFailure.Reason,
};

pub const Pipe = struct {
    read_end: CommandPlan.Resource,
    write_end: CommandPlan.Resource,
};

pub const Error = error{
    OutOfMemory,
    InvalidArguments,
    CommandNotFound,
    AccessDenied,
    InvalidExecutable,
    ResourceUnavailable,
    SandboxUnavailable,
    Unsupported,
    Unexpected,
};

/// Infrastructure failures that prevent a spawn attempt from producing a
/// shell-visible `SpawnOutcome`.
pub const SpawnError = error{
    OutOfMemory,
    InvalidArguments,
    Unexpected,
};

/// An opaque process handle owned by the host implementation.
pub const Process = enum(u32) {
    _,
};

pub const SpawnResult = struct {
    process: Process,
    /// Populated when this spawn created or joined a process group.
    process_group: ?CommandPlan.ProcessGroup = null,
    sandbox_coverage: SandboxPolicy.Coverage,
};

/// The expected outcome of attempting to spawn a command. Infrastructure
/// failures continue to use `Error`; shell-visible failures are structured so
/// the runtime can render an accurate diagnostic.
pub const SpawnOutcome = union(enum) {
    spawned: SpawnResult,
    failed: SpawnFailure,
};

pub const SpawnFailure = union(enum) {
    command_not_found,
    access_denied,
    invalid_executable,
    resource_unavailable,
    sandbox_unavailable,
    unsupported,
    file_action: FileActionFailure,
};

pub const FileActionFailure = struct {
    action_index: u32,
    reason: Reason,

    pub const Reason = enum {
        not_found,
        access_denied,
        invalid_path,
        path_already_exists,
        resource_unavailable,
        unsupported,
    };
};

pub const WorkingDirectoryRequest = struct {
    current: ?[]const u8,
    path: []const u8,
};

pub const Termination = union(enum) {
    /// Portable shell exit status. System hosts normalize native process
    /// results to the range 0...255.
    exited: runtime_types.ExitStatus,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub fn spawn(host: Host, plan: CommandPlan) SpawnError!SpawnOutcome {
    plan.validate() catch return error.InvalidArguments;
    return host.vtable.spawn(host.userdata, plan);
}

pub fn wait(host: Host, process: Process) Error!Termination {
    return host.vtable.wait(host.userdata, process);
}

/// Opens a file once for a shell redirection scope. The returned resource may
/// be inherited by child processes through `FileAction.use_resource`.
pub fn openFile(
    host: Host,
    cwd: CommandPlan.WorkingDirectory,
    open: CommandPlan.FileAction.Open,
) SpawnError!OpenFileOutcome {
    return host.vtable.open_file(host.userdata, cwd, open);
}

pub fn closeResource(host: Host, resource: CommandPlan.Resource) void {
    host.vtable.close_resource(host.userdata, resource);
}

/// Creates a connected pair of host-owned resources. The caller owns both
/// endpoints and must close them after every child has inherited its endpoint.
pub fn createPipe(host: Host) Error!Pipe {
    return host.vtable.create_pipe(host.userdata);
}

/// Creates a seekable, host-owned input resource containing `bytes`.
/// Here-documents use this instead of exposing platform pipe or temporary-file
/// details to the executor.
pub fn createInput(host: Host, bytes: []const u8) Error!CommandPlan.Resource {
    return host.vtable.create_input(host.userdata, bytes);
}

/// Returns the writer used by an in-process command for an opened resource.
/// Read-only and unknown resources do not provide a writer.
pub fn resourceWriter(host: Host, resource: CommandPlan.Resource) ?*std.Io.Writer {
    return host.vtable.resource_writer(host.userdata, resource);
}

/// Resolves and validates a directory using the host platform's path rules.
/// The returned path is owned by `allocator`.
pub fn resolveWorkingDirectory(
    host: Host,
    allocator: std.mem.Allocator,
    request: WorkingDirectoryRequest,
) Error![]u8 {
    if (request.path.len == 0) return error.InvalidArguments;
    const resolve = host.vtable.resolve_working_directory orelse return error.Unsupported;
    return resolve(host.userdata, allocator, request);
}

test {
    _ = @import("host_test.zig");
    std.testing.refAllDecls(@This());
}
