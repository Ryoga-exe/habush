const std = @import("std");
const posix = std.posix;

pub fn processId() u32 {
    return @intCast(posix.system.getpid());
}

pub fn installInteractiveInterruptHandler() error{}!void {
    // Caught dispositions reset to SIG_DFL on exec; SIG_IGN would instead be
    // inherited by external commands and make them ignore terminal Ctrl-C.
    const action: posix.Sigaction = .{
        .handler = .{ .handler = suppressInteractiveInterrupt },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.INT, &action, null);
}

fn suppressInteractiveInterrupt(_: posix.SIG) callconv(.c) void {
    @import("../interrupt.zig").notify();
}

/// One input operation owns terminal modes. It restores cooked input before
/// a builtin or external child can read the shared stdin descriptor.
pub const LineInput = struct {
    original: posix.termios,
    restored: bool = false,

    pub fn init() !?LineInput {
        const original = posix.tcgetattr(0) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        var modes = original;
        modes.lflag.ICANON = false;
        modes.lflag.ECHO = false;
        modes.lflag.IEXTEN = false;
        modes.lflag.ISIG = false;
        modes.iflag.IXON = false;
        modes.iflag.ICRNL = false;
        modes.iflag.INLCR = false;
        modes.iflag.IGNCR = false;
        modes.oflag.OPOST = false;
        modes.cc[@intFromEnum(posix.V.MIN)] = 1;
        modes.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(0, .NOW, modes);
        return .{ .original = original };
    }

    pub fn restore(input: *LineInput) !void {
        if (input.restored) return;
        try posix.tcsetattr(0, .NOW, input.original);
        input.restored = true;
    }

    pub fn deinit(input: *LineInput) void {
        input.restore() catch {};
    }

    pub fn ready(_: LineInput, timeout_ms: i32) bool {
        var descriptors = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
        return (posix.poll(&descriptors, timeout_ms) catch return false) != 0;
    }

    pub fn columns(_: LineInput) usize {
        var size: posix.winsize = undefined;
        const rc = posix.system.ioctl(0, posix.T.IOCGWINSZ, @intFromPtr(&size));
        if (posix.errno(rc) != .SUCCESS or size.col < 16) return 80;
        return size.col;
    }
};
