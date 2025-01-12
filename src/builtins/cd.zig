const std = @import("std");

pub fn cd(argv_ptr: [*:null]const ?[*:0]const u8, _: u8) !void {
    const argc = std.mem.len(argv_ptr);
    if (argc == 1) {
        const HOME = std.posix.getenvZ("HOME") orelse {
            return error.HOMENotDefined;
        };
        return std.posix.chdirZ(HOME);
    } else if (argc == 2) {
        const target = std.mem.span(argv_ptr[1].?);
        return std.posix.chdirZ(target);
    } else {
        std.debug.print("cd: too many arguments\n", .{});
        return error.TooManyArguments;
    }
}
