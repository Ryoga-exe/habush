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

fn suppressInteractiveInterrupt(_: posix.SIG) callconv(.c) void {}
