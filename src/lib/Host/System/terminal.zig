//! POSIX controlling-terminal operations used only by an explicit lease.
//!
//! Zig 0.16's `std.posix.tcgetpgrp/tcsetpgrp` use undeclared `std.c`
//! functions when libc is linked, so the libc path declares those two calls
//! locally. Linux without libc uses the standard POSIX syscall wrappers.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    NotATerminal,
    PermissionDenied,
    InvalidGroup,
    Unexpected,
};

pub const Modes = std.posix.termios;

const Libc = struct {
    extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;
    extern "c" fn tcsetpgrp(fd: c_int, pgid: std.posix.pid_t) c_int;
    extern "c" fn getpgrp() std.posix.pid_t;
};

pub fn currentProcessGroup() Error!std.posix.pid_t {
    if (builtin.link_libc) {
        const pgid = Libc.getpgrp();
        if (pgid <= 0) return error.Unexpected;
        return pgid;
    }
    if (builtin.target.os.tag != .linux) return error.Unexpected;
    const result = std.os.linux.getpgid(0);
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.Unexpected,
    };
}

pub fn foregroundGroup(tty: std.Io.File) Error!std.posix.pid_t {
    if (builtin.link_libc) {
        while (true) {
            const result = Libc.tcgetpgrp(tty.handle);
            switch (std.posix.errno(result)) {
                .SUCCESS => return result,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                .PERM => return error.PermissionDenied,
                else => return error.Unexpected,
            }
        }
    }
    return std.posix.tcgetpgrp(tty.handle) catch |err| switch (err) {
        error.NotATerminal => error.NotATerminal,
        else => error.Unexpected,
    };
}

pub fn setForegroundGroup(tty: std.Io.File, pgid: std.posix.pid_t) Error!void {
    const guard = TtouGuard.init();
    defer guard.deinit();

    if (builtin.link_libc) {
        while (true) {
            const result = Libc.tcsetpgrp(tty.handle, pgid);
            switch (std.posix.errno(result)) {
                .SUCCESS => return,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                .PERM => return error.PermissionDenied,
                .INVAL, .SRCH => return error.InvalidGroup,
                else => return error.Unexpected,
            }
        }
    }
    std.posix.tcsetpgrp(tty.handle, pgid) catch |err| return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.NotAPgrpMember => error.InvalidGroup,
        else => error.Unexpected,
    };
}

pub fn getModes(tty: std.Io.File) Error!Modes {
    return std.posix.tcgetattr(tty.handle) catch |err| switch (err) {
        error.NotATerminal => error.NotATerminal,
        else => error.Unexpected,
    };
}

pub fn setModes(tty: std.Io.File, modes: Modes) Error!void {
    // The shell can be in the background while acquiring a job's TTY modes.
    const guard = TtouGuard.init();
    defer guard.deinit();
    std.posix.tcsetattr(tty.handle, .DRAIN, modes) catch |err| return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.ProcessOrphaned => error.PermissionDenied,
        else => error.Unexpected,
    };
}

const TtouGuard = struct {
    previous: std.posix.sigset_t,

    fn init() TtouGuard {
        // Change only this thread's mask, rather than changing the process's
        // signal disposition inherited by children.
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .TTOU);
        var result: TtouGuard = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &result.previous);
        return result;
    }

    fn deinit(guard: TtouGuard) void {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &guard.previous, null);
    }
};
