const std = @import("std");

pub fn exit(argv_ptr: [*:null]const ?[*:0]const u8) !void {
    const argc = std.mem.len(argv_ptr);
    if (argc == 1) {
        std.posix.exit(0);
    } else if (argc == 2) {
        const buf = std.mem.span(argv_ptr[1].?);
        const code = std.fmt.parseInt(u8, buf, 10) catch |err| {
            return err;
        };
        std.posix.exit(code);
    } else {
        return error.TooManyArguments;
    }
}
