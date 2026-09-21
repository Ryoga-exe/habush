const std = @import("std");
const posix = std.posix;

pub fn processId() u64 {
    return @intCast(posix.system.getpid());
}

pub fn ignoreInteractiveInterrupt() error{}!void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &action, null);
}
