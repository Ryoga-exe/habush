const std = @import("std");
const windows = std.os.windows;

pub const Error = error{Unexpected};
pub fn terminalColumns() usize {
    return 80;
}

pub fn processId() u32 {
    return windows.GetCurrentProcessId();
}

pub fn installInteractiveInterruptHandler() Error!void {
    if (!SetConsoleCtrlHandler(consoleCtrlHandler, windows.BOOL.TRUE).toBool())
        return error.Unexpected;
}

fn consoleCtrlHandler(control_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    if (control_type == ctrl_c_event) @import("../interrupt.zig").notify();
    return windows.BOOL.fromBool(control_type == ctrl_c_event);
}

const ctrl_c_event = 0;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

/// The initial editor uses POSIX terminal modes. Windows keeps cooked input.
pub const LineInput = struct {
    pub fn init() error{}!?LineInput {
        return null;
    }
    pub fn restore(_: *LineInput) error{}!void {}
    pub fn deinit(_: *LineInput) void {}
    pub fn ready(_: LineInput, _: i32) bool {
        return false;
    }
    pub fn columns(_: LineInput) usize {
        return 80;
    }
    pub fn rows(_: LineInput) usize {
        return 24;
    }
};
