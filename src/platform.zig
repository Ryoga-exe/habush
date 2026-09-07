//! Platform operations used by the `habush` executable.

const builtin = @import("builtin");

const implementation = switch (builtin.os.tag) {
    .windows => @import("platform/windows.zig"),
    .linux,
    .dragonfly,
    .freebsd,
    .netbsd,
    .openbsd,
    .macos,
    => @import("platform/posix.zig"),
    else => @compileError("habush does not support this platform"),
};

pub const ignoreInteractiveInterrupt = implementation.ignoreInteractiveInterrupt;
