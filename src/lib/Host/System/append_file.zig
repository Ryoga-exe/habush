//! Platform implementation for opening a file with append-only write semantics.
//!
//! `std.Io.Dir.CreateFileOptions` does not currently expose append mode.  The
//! distinction matters because seeking to the end once races with other open
//! file descriptions.  POSIX `O_APPEND` and Windows `FILE_APPEND_DATA` both
//! arrange for every write to target the then-current end of the file.

const std = @import("std");
const builtin = @import("builtin");

pub fn open(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    absolute: bool,
    read: bool,
) !std.Io.File {
    return switch (builtin.os.tag) {
        .windows => openWindows(directory, path, absolute, read),
        .wasi => error.OperationUnsupported,
        else => openPosix(io, directory, path, absolute, read),
    };
}

fn openPosix(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    absolute: bool,
    read: bool,
) !std.Io.File {
    const file = if (absolute)
        try std.Io.Dir.createFileAbsolute(io, path, .{ .read = read, .truncate = false })
    else
        try directory.createFile(io, path, .{ .read = read, .truncate = false });
    errdefer file.close(io);

    try enablePosixAppend(file.handle);
    return file;
}

fn enablePosixAppend(fd: std.posix.fd_t) !void {
    var flags: usize = while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    };

    flags |= @as(usize, 1) << @bitOffsetOf(std.posix.O, "APPEND");
    while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.SETFL, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn openWindows(
    directory: std.Io.Dir,
    path: []const u8,
    absolute: bool,
    read: bool,
) !std.Io.File {
    const windows = std.os.windows;

    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, ".."))
        return error.IsDir;

    const path_w = try std.Io.Threaded.sliceToPrefixedFileW(directory.handle, path, .{});
    const attributes: windows.OBJECT.ATTRIBUTES = .{
        .RootDirectory = if (absolute) null else directory.handle,
        .ObjectName = @constCast(&path_w.string()),
    };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{
            .READ_DATA = read,
            .APPEND_DATA = true,
        } },
    };

    var io_status: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateFile(
        &handle,
        access,
        &attributes,
        &io_status,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN_IF,
        .{
            .NON_DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
        },
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE, .PIPE_NOT_AVAILABLE => return error.NoDevice,
        .ACCESS_DENIED, .USER_MAPPED_FILE => return error.AccessDenied,
        .PIPE_BUSY => return error.PipeBusy,
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
        .DISK_FULL => return error.NoSpaceLeft,
        else => |status| return windows.unexpectedStatus(status),
    }

    return .{
        .handle = handle,
        .flags = .{ .nonblocking = false },
    };
}

test "POSIX files are opened with append status" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const file = try open(io, temporary.dir, "append", false, false);
    defer file.close(io);

    const rc = std.posix.system.fcntl(file.handle, std.posix.F.GETFL, @as(usize, 0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    const flags: usize = @intCast(rc);
    const append_mask = @as(usize, 1) << @bitOffsetOf(std.posix.O, "APPEND");
    try std.testing.expect(flags & append_mask != 0);
}

test "separate append handles do not retain stale end offsets" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    // Both handles are deliberately opened while the file is empty.  A
    // seek-once implementation leaves both offsets at zero, so the second
    // write overwrites the first instead of appending after it.
    const first = try open(io, temporary.dir, "append", false, false);
    defer first.close(io);
    const second = try open(io, temporary.dir, "append", false, false);
    defer second.close(io);

    try first.writeStreamingAll(io, "first");
    try second.writeStreamingAll(io, "second");

    const contents = try temporary.dir.readFileAlloc(
        io,
        "append",
        std.testing.allocator,
        .limited(32),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("firstsecond", contents);
}
