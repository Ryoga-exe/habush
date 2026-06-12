const std = @import("std");
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const sigint_ignore = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sigint_ignore, null);

    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try std.Io.sleep(init.io, .fromSeconds(10), .awake);
}
