//! Spawn an executable with Windows anonymous pipe handles as standard streams.
//!
//! Zig 0.16's `std.process.spawn` reopens `.file` standard streams with
//! `OpenFile` on Windows. Anonymous pipe handles cannot be reopened that way.

const std = @import("std");
const windows = std.os.windows;
const Host = @import("../../Host.zig");

pub const Outcome = union(enum) {
    spawned: std.process.Child,
    failed: Host.SpawnFailure,
};

pub fn spawn(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
    stdio: [3]?std.Io.File,
) Host.SpawnError!Outcome {
    std.debug.assert(argv.len != 0);
    const executable = argv[0];
    // Batch files need cmd.exe-specific argument escaping. The regular spawn
    // path still handles them when no anonymous pipe is involved.
    if (std.ascii.endsWithIgnoreCase(executable, ".bat") or
        std.ascii.endsWithIgnoreCase(executable, ".cmd"))
        return .{ .failed = .unsupported };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const executable_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, executable) catch |err|
        return conversionError(err);
    const command_line_w = try commandLine(arena, argv);
    const cwd_w = if (cwd) |path|
        std.unicode.wtf8ToWtf16LeAllocZ(arena, path) catch |err|
            return conversionError(err)
    else
        null;
    const environment_block = if (environment) |map|
        map.createWindowsBlock(arena, .{}) catch |err| return conversionError(err)
    else
        null;

    var inherited: [3]?windows.HANDLE = .{ null, null, null };
    defer for (inherited) |handle| if (handle) |value| windows.CloseHandle(value);
    for (stdio, &inherited) |file, *destination| {
        const source = file orelse continue;
        const process = windows.GetCurrentProcess();
        if (DuplicateHandle(
            process,
            source.handle,
            process,
            destination,
            0,
            .TRUE,
            windows.DUPLICATE_SAME_ACCESS,
        ) == .FALSE) return .{ .failed = try duplicateFailure(windows.GetLastError()) };
    }

    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.hStdInput = inherited[0];
    startup.hStdOutput = inherited[1];
    startup.hStdError = inherited[2];
    var process_info: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        executable_w.ptr,
        command_line_w.ptr,
        null,
        null,
        .TRUE,
        .{ .create_unicode_environment = true },
        if (environment_block) |block| block.slice.ptr else null,
        if (cwd_w) |path| path.ptr else null,
        &startup,
        &process_info,
    ) == .FALSE) return .{ .failed = try createProcessFailure(windows.GetLastError()) };

    return .{ .spawned = .{
        .id = process_info.hProcess,
        .thread_handle = process_info.hThread,
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    } };
}

fn conversionError(err: anyerror) Host.SpawnError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
}

fn duplicateFailure(err: windows.Win32Error) Host.SpawnError!Host.SpawnFailure {
    return switch (err) {
        .ACCESS_DENIED => .access_denied,
        .NOT_ENOUGH_MEMORY,
        .OUTOFMEMORY,
        .TOO_MANY_OPEN_FILES,
        .NO_SYSTEM_RESOURCES,
        .NOT_ENOUGH_QUOTA,
        .COMMITMENT_LIMIT,
        => .resource_unavailable,
        else => error.Unexpected,
    };
}

fn createProcessFailure(err: windows.Win32Error) Host.SpawnError!Host.SpawnFailure {
    return switch (err) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .DIRECTORY => .command_not_found,
        .ACCESS_DENIED => .access_denied,
        .BAD_FORMAT, .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH => .invalid_executable,
        .NOT_ENOUGH_MEMORY,
        .OUTOFMEMORY,
        .TOO_MANY_OPEN_FILES,
        .NO_SYSTEM_RESOURCES,
        .NOT_ENOUGH_QUOTA,
        .COMMITMENT_LIMIT,
        => .resource_unavailable,
        else => error.Unexpected,
    };
}

fn commandLine(gpa: std.mem.Allocator, argv: []const []const u8) Host.SpawnError![:0]u16 {
    // Match Zig's Windows argv serialization, while keeping the resolved
    // executable as argv[0]. CreateProcessW does not parse argv for us.
    var bytes: std.ArrayList(u8) = .empty;
    const first = argv[0];
    if (std.mem.indexOfScalar(u8, first, '"') != null or
        std.mem.indexOfScalar(u8, first, 0) != null)
        return error.InvalidArguments;
    const quote_first = first.len == 0 or for (first) |byte| {
        if (byte <= ' ') break true;
    } else false;
    if (quote_first) try bytes.append(gpa, '"');
    try bytes.appendSlice(gpa, first);
    if (quote_first) try bytes.append(gpa, '"');

    for (argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArguments;
        try bytes.append(gpa, ' ');
        const needs_quotes = arg.len == 0 or for (arg) |byte| {
            if (byte <= ' ' or byte == '"') break true;
        } else false;
        if (!needs_quotes) {
            try bytes.appendSlice(gpa, arg);
            continue;
        }
        try bytes.append(gpa, '"');
        var backslashes: usize = 0;
        for (arg) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try bytes.appendNTimes(gpa, '\\', backslashes * 2 + 1);
                try bytes.append(gpa, '"');
                backslashes = 0;
            },
            else => {
                try bytes.appendNTimes(gpa, '\\', backslashes);
                try bytes.append(gpa, byte);
                backslashes = 0;
            },
        };
        try bytes.appendNTimes(gpa, '\\', backslashes * 2);
        try bytes.append(gpa, '"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, bytes.items) catch |err|
        return conversionError(err);
}

extern "kernel32" fn DuplicateHandle(
    source_process: windows.HANDLE,
    source_handle: windows.HANDLE,
    target_process: windows.HANDLE,
    target_handle: *?windows.HANDLE,
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    options: windows.DWORD,
) callconv(.winapi) windows.BOOL;

test "command line preserves spaces, quotes, and trailing backslashes" {
    const gpa = std.testing.allocator;
    const actual = try commandLine(gpa, &.{
        "C:\\Program Files\\tool.exe",
        "plain",
        "two words",
        "quoted\"word",
        "path with space\\",
        "",
    });
    defer gpa.free(actual);
    const expected = try std.unicode.wtf8ToWtf16LeAllocZ(
        gpa,
        "\"C:\\Program Files\\tool.exe\" plain \"two words\" \"quoted\\\"word\" \"path with space\\\\\" \"\"",
    );
    defer gpa.free(expected);
    try std.testing.expectEqualSlices(u16, expected, actual);
}
