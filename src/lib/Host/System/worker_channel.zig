//! Private POSIX bootstrap and startup-failure channel for command workers.
//! No inherited descriptor has its CLOEXEC flag temporarily cleared. The
//! child's stdio slot carries the socket only until bootstrap restores stdin.
const std = @import("std");
const builtin = @import("builtin");
const Host = @import("../../Host.zig");
const posix = std.posix;
const fd_t = posix.fd_t;
const Cmsghdr = posix.system.cmsghdr;
const cmsg_alignment = if (builtin.target.os.tag.isDarwin()) 4 else @sizeOf(usize);
const data_offset = alignControl(@sizeOf(Cmsghdr));
const packet_len = 12;

pub const Error = error{ ResourceUnavailable, Unexpected };

pub const Parent = struct {
    socket: fd_t,
    child_socket: fd_t,
    input: ?fd_t,

    pub fn init(input: ?std.Io.File) Error!Parent {
        // Capture stdin before socketpair can reuse a closed standard fd.
        const saved = if (input) |file| try duplicateOptional(file.handle) else null;
        errdefer if (saved) |fd| close(fd);
        var pair: [2]fd_t = undefined;
        const flags = if (builtin.target.os.tag.isDarwin()) 0 else posix.SOCK.CLOEXEC;
        while (true) switch (posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | flags, 0, &pair))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.ResourceUnavailable,
        };
        errdefer close(pair[0]);
        errdefer close(pair[1]);
        pair[0] = try moveAboveStdio(pair[0]);
        pair[1] = try moveAboveStdio(pair[1]);
        try setCloseOnExec(pair[0]);
        try setCloseOnExec(pair[1]);
        if (comptime @hasDecl(posix.SO, "NOSIGPIPE")) {
            const one: c_int = 1;
            posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&one)) catch return error.ResourceUnavailable;
            posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&one)) catch return error.ResourceUnavailable;
        }
        return .{ .socket = pair[0], .child_socket = pair[1], .input = saved };
    }

    pub fn childInput(parent: Parent) std.Io.File {
        return .{ .handle = parent.child_socket, .flags = .{ .nonblocking = false } };
    }

    /// Sends one fixed-size setup message; it never waits for worker readiness.
    pub fn sendInput(parent: *Parent) Error!void {
        close(parent.child_socket);
        parent.child_socket = -1;
        defer {
            if (parent.input) |fd| close(fd);
            parent.input = null;
        }
        const marker = [_]u8{if (parent.input != null) 1 else 0};
        var iov = [_]posix.iovec_const{.{ .base = &marker, .len = marker.len }};
        var control: [controlSpace(@sizeOf(fd_t))]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        if (parent.input) |fd| {
            const header: *Cmsghdr = @ptrCast(&control);
            header.* = .{ .len = @intCast(data_offset + @sizeOf(fd_t)), .level = posix.SOL.SOCKET, .type = posix.SCM.RIGHTS };
            @memcpy(control[data_offset..][0..@sizeOf(fd_t)], std.mem.asBytes(&fd));
        }
        const message: posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = if (parent.input != null) &control else null,
            .controllen = if (parent.input != null) control.len else 0,
            .flags = 0,
        };
        while (true) {
            const rc = posix.system.sendmsg(parent.socket, &message, noSignal());
            switch (posix.errno(rc)) {
                .SUCCESS => if (rc == marker.len) return else return error.Unexpected,
                .INTR => continue,
                else => return error.ResourceUnavailable,
            }
        }
    }

    pub fn takeReport(parent: *Parent, action_offset: u32) Report {
        const report: Report = .{ .socket = parent.socket, .action_offset = action_offset };
        parent.socket = -1;
        return report;
    }

    pub fn deinit(parent: *Parent) void {
        close(parent.socket);
        close(parent.child_socket);
        if (parent.input) |fd| close(fd);
        parent.* = undefined;
    }
};

pub const Report = struct {
    socket: fd_t,
    action_offset: u32,

    pub fn deinit(report: Report) void {
        close(report.socket);
    }

    /// Called only after terminal process completion. Missing data preserves
    /// the launcher's native result; EOF alone does not prove target execution.
    pub fn read(report: Report) Error!?Host.SpawnFailure {
        defer report.deinit();
        var packet: [packet_len + 1]u8 = undefined;
        var used: usize = 0;
        while (used < packet.len) {
            var iov = [_]posix.iovec{.{ .base = packet[used..].ptr, .len = packet.len - used }};
            var message: posix.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            const rc = posix.system.recvmsg(report.socket, &message, posix.MSG.DONTWAIT);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    used += @intCast(rc);
                },
                .INTR => continue,
                .AGAIN => break,
                else => return error.Unexpected,
            }
        }
        if (used == 0) return null;
        if (used != packet_len) return error.Unexpected;
        var failure = try decode(packet[0..packet_len]);
        if (failure == .file_action) failure.file_action.action_index = std.math.add(
            u32,
            failure.file_action.action_index,
            report.action_offset,
        ) catch return error.Unexpected;
        return failure;
    }
};

pub const Reporter = struct {
    socket: fd_t,

    /// Runs in a fresh worker before any user file actions. The reporting fd is
    /// above stdio and CLOEXEC, so target execution cannot retain it.
    pub fn receive() Error!Reporter {
        const socket = (try duplicateOptional(0)) orelse return error.Unexpected;
        errdefer close(socket);
        const input = try receiveInput(socket);
        defer if (input) |fd| close(fd);
        if (input) |fd| {
            while (true) switch (posix.errno(posix.system.dup2(fd, 0))) {
                .SUCCESS => break,
                .INTR, .BUSY => continue,
                else => return error.Unexpected,
            };
        } else close(0);
        return .{ .socket = socket };
    }

    pub fn deinit(reporter: Reporter) void {
        close(reporter.socket);
    }

    pub fn send(reporter: Reporter, failure: Host.SpawnFailure) void {
        const packet = encode(failure);
        var written: usize = 0;
        while (written < packet.len) {
            var iov = [_]posix.iovec_const{.{ .base = packet[written..].ptr, .len = packet.len - written }};
            const message: posix.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            const rc = posix.system.sendmsg(reporter.socket, &message, noSignal());
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return;
                    written += @intCast(rc);
                },
                .INTR => continue,
                else => return,
            }
        }
    }
};

fn receiveInput(socket: fd_t) Error!?fd_t {
    var marker: [1]u8 = undefined;
    var iov = [_]posix.iovec{.{ .base = &marker, .len = marker.len }};
    var control: [controlSpace(4 * @sizeOf(fd_t))]u8 align(@alignOf(Cmsghdr)) = @splat(0);
    var message: posix.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    const received = while (true) {
        const flags = if (builtin.target.os.tag == .linux) posix.MSG.CMSG_CLOEXEC else 0;
        const rc = posix.system.recvmsg(socket, &message, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.Unexpected,
        }
    };
    var fds: [4]fd_t = undefined;
    var count: usize = 0;
    errdefer for (fds[0..count]) |fd| close(fd);
    var offset: usize = 0;
    var malformed = message.flags & posix.MSG.CTRUNC != 0;
    while (offset + @sizeOf(Cmsghdr) <= message.controllen) {
        const header: *const Cmsghdr = @ptrCast(@alignCast(control[offset..].ptr));
        const length: usize = @intCast(header.len);
        if (length < data_offset or length > message.controllen - offset) {
            malformed = true;
            break;
        }
        if (header.level == posix.SOL.SOCKET and header.type == posix.SCM.RIGHTS) {
            const payload = control[offset + data_offset .. offset + length];
            if (payload.len % @sizeOf(fd_t) != 0) malformed = true;
            var index: usize = 0;
            while (index + @sizeOf(fd_t) <= payload.len) : (index += @sizeOf(fd_t)) {
                const fd = std.mem.bytesToValue(fd_t, payload[index..][0..@sizeOf(fd_t)]);
                if (count < fds.len) {
                    fds[count] = fd;
                    count += 1;
                } else {
                    close(fd);
                    malformed = true;
                }
            }
        } else malformed = true;
        offset += alignControl(length);
    }
    if (received != marker.len or malformed) return error.Unexpected;
    if (marker[0] == 0 and count == 0) return null;
    if (marker[0] != 1 or count != 1) return error.Unexpected;
    try setCloseOnExec(fds[0]);
    return fds[0];
}

fn encode(failure: Host.SpawnFailure) [packet_len]u8 {
    var packet: [packet_len]u8 = @splat(0);
    @memcpy(packet[0..4], "HBW1");
    packet[4] = switch (failure) {
        .command_not_found => 1,
        .access_denied => 2,
        .invalid_executable => 3,
        .resource_unavailable => 4,
        .sandbox_unavailable => 5,
        .unsupported => 6,
        .file_action => 7,
    };
    if (failure == .file_action) {
        packet[5] = switch (failure.file_action.reason) {
            .not_found => 1,
            .access_denied => 2,
            .invalid_path => 3,
            .path_already_exists => 4,
            .resource_unavailable => 5,
            .unsupported => 6,
            .bad_file_descriptor => 7,
        };
        std.mem.writeInt(u32, packet[8..12], failure.file_action.action_index, .little);
    }
    return packet;
}

fn decode(packet: *const [packet_len]u8) Error!Host.SpawnFailure {
    if (!std.mem.eql(u8, packet[0..4], "HBW1") or packet[6] != 0 or packet[7] != 0) return error.Unexpected;
    const index = std.mem.readInt(u32, packet[8..12], .little);
    if (packet[4] != 7 and (packet[5] != 0 or index != 0)) return error.Unexpected;
    return switch (packet[4]) {
        1 => .command_not_found,
        2 => .access_denied,
        3 => .invalid_executable,
        4 => .resource_unavailable,
        5 => .sandbox_unavailable,
        6 => .unsupported,
        7 => .{ .file_action = .{ .action_index = index, .reason = switch (packet[5]) {
            1 => .not_found,
            2 => .access_denied,
            3 => .invalid_path,
            4 => .path_already_exists,
            5 => .resource_unavailable,
            6 => .unsupported,
            7 => .bad_file_descriptor,
            else => return error.Unexpected,
        } } },
        else => error.Unexpected,
    };
}

fn duplicateOptional(fd: fd_t) Error!?fd_t {
    while (true) {
        const rc = posix.system.fcntl(fd, posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return null,
            else => return error.ResourceUnavailable,
        }
    }
}

fn moveAboveStdio(fd: fd_t) Error!fd_t {
    if (fd >= 3) return fd;
    const copy = (try duplicateOptional(fd)) orelse return error.Unexpected;
    close(fd);
    return copy;
}

fn setCloseOnExec(fd: fd_t) Error!void {
    // Only newly created sockets or newly received descriptors reach here.
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}

fn noSignal() u32 {
    return if (builtin.target.os.tag.isDarwin()) 0 else posix.MSG.NOSIGNAL;
}

fn close(fd: fd_t) void {
    if (fd >= 0) _ = posix.system.close(fd);
}

fn alignControl(length: usize) usize {
    return std.mem.alignForward(usize, length, cmsg_alignment);
}

fn controlSpace(length: usize) usize {
    return data_offset + alignControl(length);
}

test "worker channel transfers input and preserves file action indexes" {
    var parent = try Parent.init(.stdin());
    defer parent.deinit();
    const child = (try duplicateOptional(parent.child_socket)).?;
    defer close(child);
    try parent.sendInput();
    const input = try receiveInput(child);
    if (input) |fd| close(fd);
    const reporter: Reporter = .{ .socket = child };
    reporter.send(.{ .file_action = .{ .action_index = 2, .reason = .bad_file_descriptor } });
    const report = parent.takeReport(3);
    try std.testing.expectEqualDeep(@as(?Host.SpawnFailure, .{ .file_action = .{ .action_index = 5, .reason = .bad_file_descriptor } }), try report.read());
}

test "closed input and an empty report preserve native termination" {
    var parent = try Parent.init(null);
    defer parent.deinit();
    const child = (try duplicateOptional(parent.child_socket)).?;
    defer close(child);
    try parent.sendInput();
    try std.testing.expectEqual(@as(?fd_t, null), try receiveInput(child));
    try std.testing.expectEqual(@as(?Host.SpawnFailure, null), try parent.takeReport(0).read());
}
