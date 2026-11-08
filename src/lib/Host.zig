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
    capabilities: Capabilities = .{},
    spawn: *const fn (?*anyopaque, CommandPlan) SpawnError!SpawnOutcome,
    wait: *const fn (?*anyopaque, Process) Error!Termination,
    wait_event: ?*const fn (?*anyopaque, Process) Error!Termination = null,
    wait_any: ?*const fn (?*anyopaque, []const Process) Error!ProcessEvent = null,
    try_wait: ?*const fn (?*anyopaque, Process) Error!?Termination = null,
    signal: ?*const fn (?*anyopaque, Process, Signal) Error!void = null,
    signal_group: ?*const fn (?*anyopaque, CommandPlan.ProcessGroup, Signal) Error!void = null,
    acquire_terminal: ?*const fn (?*anyopaque, CommandPlan.ProcessGroup) Error!TerminalLease = null,
    release_terminal: ?*const fn (?*anyopaque, TerminalLease) Error!void = null,
    open_file: *const fn (
        ?*anyopaque,
        CommandPlan.WorkingDirectory,
        CommandPlan.FileAction.Open,
    ) SpawnError!OpenFileOutcome,
    create_pipe: *const fn (?*anyopaque) Error!Pipe,
    create_input: *const fn (?*anyopaque, []const u8) Error!CommandPlan.Resource,
    create_capture: ?*const fn (?*anyopaque) Error!CommandPlan.Resource = null,
    close_resource: *const fn (?*anyopaque, CommandPlan.Resource) void,
    resource_writer: *const fn (?*anyopaque, CommandPlan.Resource) ?*std.Io.Writer,
    resource_reader: ?*const fn (?*anyopaque, CommandPlan.Resource) ?*std.Io.Reader = null,
    resolve_working_directory: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        WorkingDirectoryRequest,
    ) Error![]u8 = null,
    read_directory: ?*const fn (?*anyopaque, std.mem.Allocator, CommandPlan.WorkingDirectory, []const u8) Error!?Directory = null,
};

/// An allocator-owned snapshot of native entry names, without shell matching
/// or sorting. Null from readDirectory means a missing/non-directory path.
pub const Directory = struct {
    names: []const []const u8,

    pub fn deinit(directory: Directory, gpa: std.mem.Allocator) void {
        for (directory.names) |name| gpa.free(name);
        gpa.free(directory.names);
    }
};

pub fn readDirectory(host: Host, gpa: std.mem.Allocator, cwd: CommandPlan.WorkingDirectory, path: []const u8) Error!?Directory {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    if (cwd == .path and std.mem.indexOfScalar(u8, cwd.path, 0) != null) return error.InvalidArguments;
    const read = host.vtable.read_directory orelse return error.Unsupported;
    return read(host.userdata, gpa, cwd, path);
}

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
    Canceled,
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

/// Opaque claim on the host's controlling terminal. Release exactly once.
pub const TerminalLease = enum(u32) {
    _,
};

pub const Signal = enum {
    interrupt,
    terminate,
    kill,
    stop,
    cont,
};

/// Features available from a host implementation. Individual signal kinds
/// may still return `Unsupported` (for example, stop on Windows).
pub const Capabilities = struct {
    process_groups: bool = false,
    terminal_control: bool = false,
    /// A fresh worker can stop before target execution and terminal IO.
    suspend_before_execute: bool = false,
    poll: bool = false,
    signals: bool = false,
    /// openFile may run concurrently with other Host operations. The host
    /// synchronizes resource registration without holding its lock across a
    /// potentially blocking filesystem open.
    parallel_open_file: bool = false,
};

pub fn capabilities(host: Host) Capabilities {
    return host.vtable.capabilities;
}

pub const SpawnResult = struct {
    process: Process,
    /// Numeric OS PID for shell variables and wait-by-PID. Unlike `process`,
    /// this identifier is observable and must not be used as an ownership key.
    process_id: ?runtime_types.ProcessId = null,
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
        bad_file_descriptor,
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
    /// Terminal result that could not be interpreted, including a malformed
    /// private worker report after native process reaping. The handle is consumed.
    unknown: u32,
    /// A fresh worker reported a failure before replacing itself with the
    /// requested executable. This is distinct from a target exiting with 126.
    /// File action indices refer to the original submitted plan.
    spawn_failed: SpawnFailure,
};

pub const ProcessEvent = struct {
    process: Process,
    termination: Termination,
};

pub fn spawn(host: Host, plan: CommandPlan) SpawnError!SpawnOutcome {
    plan.validate() catch return error.InvalidArguments;
    if (plan.suspend_before_execute and !host.capabilities().suspend_before_execute)
        return .{ .failed = .unsupported };
    return host.vtable.spawn(host.userdata, plan);
}

pub fn wait(host: Host, process: Process) Error!Termination {
    return host.vtable.wait(host.userdata, process);
}

/// Blocks until the process exits, is signaled, or stops. Hosts without a
/// separate stop-aware implementation retain the terminal-only wait behavior.
pub fn waitEvent(host: Host, process: Process) Error!Termination {
    const callback = host.vtable.wait_event orelse host.vtable.wait;
    return callback(host.userdata, process);
}

/// Blocks until any specified process exits or stops. Each handle must be
/// owned by this host; an empty set is invalid. A backend with no wait-any
/// callback can still serve a single process through waitEvent.
pub fn waitAny(host: Host, processes: []const Process) Error!ProcessEvent {
    if (processes.len == 0) return error.InvalidArguments;
    if (host.vtable.wait_any) |callback| return callback(host.userdata, processes);
    if (processes.len == 1) return .{
        .process = processes[0],
        .termination = try host.waitEvent(processes[0]),
    };
    return error.Unsupported;
}

/// Polls one host-owned process without blocking. A stopped notification does
/// not consume its process handle; only terminal results do.
pub fn tryWait(host: Host, process: Process) Error!?Termination {
    const callback = host.vtable.try_wait orelse return error.Unsupported;
    return callback(host.userdata, process);
}

/// Sends a request to one host-owned process. This does not wait for it.
pub fn signal(host: Host, process: Process, requested: Signal) Error!void {
    const callback = host.vtable.signal orelse return error.Unsupported;
    return callback(host.userdata, process, requested);
}

/// Sends a signal to an owned process group, including every current member.
pub fn signalGroup(host: Host, group: CommandPlan.ProcessGroup, requested: Signal) Error!void {
    const callback = host.vtable.signal_group orelse return error.Unsupported;
    return callback(host.userdata, group, requested);
}

/// Explicitly transfers the controlling terminal to an owned process group.
/// The caller must release the returned lease, including on command failure.
pub fn acquireTerminal(host: Host, group: CommandPlan.ProcessGroup) Error!TerminalLease {
    const callback = host.vtable.acquire_terminal orelse return error.Unsupported;
    return callback(host.userdata, group);
}

/// Restores the terminal's previous foreground process group. A failed
/// release leaves the lease active so the caller can retry or deinit the host.
pub fn releaseTerminal(host: Host, lease: TerminalLease) Error!void {
    const callback = host.vtable.release_terminal orelse return error.Unsupported;
    return callback(host.userdata, lease);
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

/// Returns a borrowed reader for a host-owned readable resource, when the
/// backend supports in-process reading. It is invalid after closeResource.
/// Reader methods may buffer past the requested bytes; callers sharing the
/// resource with a child must avoid read-ahead until input ownership is unified.
pub fn resourceReader(host: Host, resource: CommandPlan.Resource) ?*std.Io.Reader {
    const callback = host.vtable.resource_reader orelse return null;
    return callback(host.userdata, resource);
}

/// Creates a host-owned output capture. Write through resourceWriter or an
/// inherited child stdout, then flush and finish all writers before requesting
/// resourceReader. Its reader starts at offset zero independently of the write
/// position. The host may spool to storage instead of a bounded pipe; callers
/// decide how much data to retain while reading. Close with closeResource.
pub fn createCapture(host: Host) Error!CommandPlan.Resource {
    const callback = host.vtable.create_capture orelse return error.Unsupported;
    return callback(host.userdata);
}

/// Resolves and validates a directory using the host platform's path rules.
/// The returned path is absolute in the host's namespace and owned by
/// `allocator`. A null current directory captures the host's current base at
/// this call; callers that need a stable session base must retain the result.
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
