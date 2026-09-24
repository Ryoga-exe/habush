//! Platform implementation for creating an anonymous byte-stream pipe.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    OperationUnsupported,
    ResourceUnavailable,
};

pub fn create() Error![2]std.Io.File {
    return switch (builtin.os.tag) {
        .windows => createWindows(),
        .wasi => error.OperationUnsupported,
        else => createPosix(),
    };
}

fn createPosix() Error![2]std.Io.File {
    const descriptors = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch
        return error.ResourceUnavailable;
    return .{
        .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } },
        .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } },
    };
}

fn createWindows() Error![2]std.Io.File {
    const windows = std.os.windows;
    const kernel32 = struct {
        extern "kernel32" fn CreatePipe(
            read_pipe: *windows.HANDLE,
            write_pipe: *windows.HANDLE,
            attributes: ?*windows.SECURITY_ATTRIBUTES,
            size: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    };
    var read_handle: windows.HANDLE = undefined;
    var write_handle: windows.HANDLE = undefined;
    if (kernel32.CreatePipe(&read_handle, &write_handle, null, 0) == .FALSE)
        return error.ResourceUnavailable;
    return .{
        .{ .handle = read_handle, .flags = .{ .nonblocking = false } },
        .{ .handle = write_handle, .flags = .{ .nonblocking = false } },
    };
}
