const std = @import("std");
const windows = std.os.windows;

pub const Error = error{Unexpected};

pub fn ignoreInteractiveInterrupt() Error!void {
    if (!SetConsoleCtrlHandler(consoleCtrlHandler, windows.BOOL.TRUE).toBool())
        return error.Unexpected;
}

fn consoleCtrlHandler(control_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    return windows.BOOL.fromBool(control_type == ctrl_c_event);
}

const ctrl_c_event = 0;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;
