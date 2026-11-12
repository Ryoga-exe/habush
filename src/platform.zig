//! Platform operations used by the `habush` executable.

const builtin = @import("builtin");
const ProcessId = @import("habush").runtime.ProcessId;

const implementation = switch (builtin.target.os.tag) {
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

pub const installInteractiveInterruptHandler = implementation.installInteractiveInterruptHandler;
pub const LineInput = implementation.LineInput;
pub const terminalColumns = implementation.terminalColumns;
pub fn processId() ProcessId {
    return @fromBackingInt(implementation.processId());
}
