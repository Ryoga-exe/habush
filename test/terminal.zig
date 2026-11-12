//! One bounded PTY scenario for the real CLI; no external test runtime.
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

// Zig has no public PTY allocation/session wrapper.
extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*const posix.termios, ?*const posix.winsize) c_int;
extern "c" fn login_tty(c_int) c_int;
extern "c" fn tcgetpgrp(c_int) posix.pid_t;

const ready = "\x1b[?2004h";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "--session")) {
        // A fresh process can acquire the controlling TTY without forking
        // Zig's multithreaded I/O runtime.
        if (login_tty(0) != 0) return error.TerminalSessionFailed;
        return std.process.replace(io, .{ .argv = &.{ args[2], "--no-config" }, .environ_map = init.environ_map });
    }
    if (args.len != 2) return error.InvalidArguments;
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    const size: posix.winsize = .{ .row = 24, .col = 100, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master_fd, &slave_fd, null, null, &size) != 0) return error.OpenPtyFailed;
    const master: Io.File = .{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave: Io.File = .{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    var terminal_open = true;
    defer if (terminal_open) {
        master.close(io);
        slave.close(io);
    };
    for ([_]c_int{ master_fd, slave_fd }) |fd| {
        if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
            return error.CloseOnExecFailed;
    }
    const original = try posix.tcgetattr(slave_fd);
    const self = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self);
    var environment = try init.environ_map.clone(gpa);
    defer environment.deinit();
    try environment.put("TERM", "xterm");
    try environment.put("HABUSH_LINE_EDIT", "on");
    try environment.put("HABUSH_SHELL_INTEGRATION", "off");
    var child = try std.process.spawn(io, .{
        .argv = &.{ self, "--session", args[1] },
        .environ_map = &environment,
        .stdin = .{ .file = slave },
        .stdout = .{ .file = slave },
        .stderr = .{ .file = slave },
    });
    defer {
        const foreground = if (child.id != null) tcgetpgrp(slave_fd) else 0;
        // Closing the PTY first also unblocks terminal draining during exit.
        master.close(io);
        slave.close(io);
        terminal_open = false;
        if (child.id != null) {
            if (foreground > 0) posix.kill(-foreground, .KILL) catch {};
            child.kill(io);
        }
    }
    var terminal: Terminal = .{
        .io = io,
        .master = master,
        .deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(15)),
    };
    errdefer std.debug.print("PTY output:\n{s}\n", .{terminal.output[0..terminal.len]});
    _ = try terminal.expect(ready);
    try std.testing.expect(!(try posix.tcgetattr(slave_fd)).lflag.ICANON);

    try master.writeStreamingAll(io, "pwd; while true; do :; done\r");
    _ = try terminal.expect("\x1b[?2004l");
    try master.writeStreamingAll(io, "\x03");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo INTERRUPT:$?\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "INTERRUPT:130\r\n") != null);

    try master.writeStreamingAll(io, ")\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "expected command") != null);

    for ([_]bool{ false, true }) |foreground_wait| {
        try master.writeStreamingAll(io, "/bin/sh -c '/bin/sleep 0.2; exit 23' & job=$!; /bin/echo BACKGROUND:$job\r");
        const output = try terminal.expect(ready);
        const marker = std.mem.lastIndexOf(u8, output, "BACKGROUND:") orelse return error.MissingProcessId;
        const end = std.mem.indexOfScalarPos(u8, output, marker, '\r') orelse return error.MissingProcessId;
        const background = try std.fmt.parseInt(posix.pid_t, output[marker + "BACKGROUND:".len .. end], 10);
        if (foreground_wait) {
            try master.writeStreamingAll(io, "/bin/sleep 1\r");
            _ = try terminal.expect("\x1b[?2004l");
        }
        while (true) {
            posix.kill(background, @fromBackingInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => break,
                else => return err,
            };
            try terminal.pause();
        }
        if (foreground_wait) _ = try terminal.expect(ready);
        try master.writeStreamingAll(io, "wait \"$job\"; /bin/echo WAIT:$?\r");
        try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "WAIT:23\r\n") != null);
    }

    try master.writeStreamingAll(io, "/bin/cat\r");
    _ = try terminal.expect("\x1b[?2004l");
    while (tcgetpgrp(slave_fd) == child.id.?) try terminal.pause();
    const cooked = try posix.tcgetattr(slave_fd);
    try std.testing.expect(cooked.lflag.ICANON and cooked.lflag.ECHO and cooked.lflag.ISIG);
    // macOS revokes a PTY when its session leader exits; inspect it beforehand.
    var restored_flags = cooked.lflag;
    // PENDIN is kernel input state, not an editor setting.
    if (@hasField(@TypeOf(restored_flags), "PENDIN")) restored_flags.PENDIN = original.lflag.PENDIN;
    try std.testing.expectEqual(original.lflag, restored_flags);
    try std.testing.expectEqual(original.iflag, cooked.iflag);
    try std.testing.expectEqual(original.oflag, cooked.oflag);
    try std.testing.expectEqualSlices(u8, &original.cc, &cooked.cc);
    try master.writeStreamingAll(io, "child-stdin\n");
    _ = try terminal.expect("child-stdin\r\nchild-stdin\r\n");
    try master.writeStreamingAll(io, "\x04");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "exit 0\r");
    var status: c_int = undefined;
    while (true) {
        const rc = posix.system.waitpid(child.id.?, &status, posix.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) break,
            .INTR => {},
            else => return error.WaitFailed,
        }
        terminal.drain() catch |err| switch (err) {
            error.EndOfStream => try terminal.pause(),
            else => return err,
        };
    }
    child.id = null;
    const bits: u32 = @bitCast(status);
    try std.testing.expect(posix.W.IFEXITED(bits) and posix.W.EXITSTATUS(bits) == 0);
}

const Terminal = struct {
    io: Io,
    master: Io.File,
    deadline: Io.Timestamp,
    output: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn checkDeadline(terminal: *Terminal) !void {
        if (Io.Timestamp.now(terminal.io, .awake).nanoseconds >= terminal.deadline.nanoseconds)
            return error.TerminalTestTimedOut;
    }

    fn pause(terminal: *Terminal) !void {
        try terminal.checkDeadline();
        try terminal.io.sleep(.fromMilliseconds(5), .awake);
    }

    fn expect(terminal: *Terminal, needle: []const u8) ![]const u8 {
        terminal.len = 0;
        while (std.mem.indexOf(u8, terminal.output[0..terminal.len], needle) == null) {
            try terminal.drain();
        }
        return terminal.output[0..terminal.len];
    }

    fn drain(terminal: *Terminal) !void {
        try terminal.checkDeadline();
        var fds = [_]posix.pollfd{.{ .fd = terminal.master.handle, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 50) == 0) return;
        if (terminal.len == terminal.output.len) return error.TerminalOutputLimitExceeded;
        const count = try terminal.master.readStreaming(terminal.io, &.{terminal.output[terminal.len..]});
        if (count == 0) return error.EndOfStream;
        terminal.len += count;
    }
};
