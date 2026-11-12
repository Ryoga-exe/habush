//! One bounded PTY scenario for the real CLI; no external test runtime.
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

// Zig has no public PTY allocation/session wrapper.
extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*const posix.termios, ?*const posix.winsize) c_int;
extern "c" fn login_tty(c_int) c_int;
extern "c" fn tcgetpgrp(c_int) posix.pid_t;

const ready = "\x1b[?2004h";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "--session")) {
        // A fresh process can acquire the controlling TTY without forking
        // Zig's multithreaded I/O runtime.
        if (login_tty(0) != 0) return error.TerminalSessionFailed;
        return std.process.replace(io, .{
            .argv = if (args.len == 4) &.{ args[2], "--config", args[3] } else &.{ args[2], "--no-config" },
            .environ_map = init.environ_map,
        });
    }
    if (args.len != 2 and args.len != 3) return error.InvalidArguments;
    var config_path: ?[]u8 = null;
    defer if (config_path) |path| {
        Io.Dir.cwd().deleteFile(io, path) catch {};
        gpa.free(path);
    };
    var random: [16]u8 = undefined;
    try Io.randomSecure(io, &random);
    const hex = std.fmt.hex(@as(u128, @bitCast(random)));
    config_path = try gpa.print("/tmp/habush-terminal-{s}.zon", .{hex[0..]});
    var config: Io.Writer.Allocating = .init(gpa);
    defer config.deinit();
    const bindings = .{
        .{ .key = "ctrl+space", .action = .complete },
        .{ .key = "ctrl+x", .action = .ignore },
    };
    if (args.len == 3) {
        const module_path = try Io.Dir.cwd().realPathFileAlloc(io, args[2], gpa);
        defer gpa.free(module_path);
        try std.zon.stringify.serialize(.{
            .load_rc = false,
            .keybinds = bindings,
            .plugins = .{
                .{
                    .path = module_path,
                    .fuel = std.math.maxInt(u64),
                    .timeout_ms = 5000,
                    .commands = .{.{ .name = "hb-demo" }},
                },
                .{
                    .path = module_path,
                    .completions = .{ .{ .command = "hb-demo" }, .{ .command = "/bin/echo" } },
                },
            },
        }, .{}, &config.writer);
    } else {
        try std.zon.stringify.serialize(.{
            .load_rc = false,
            .keybinds = bindings,
            .prompt = .{ .spans = .{.{ .text = "日> ", .style = .{ .foreground = .green } }} },
        }, .{}, &config.writer);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path.?, .data = config.written() });
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    const size: posix.winsize = .{ .row = 24, .col = 100, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master_fd, &slave_fd, null, null, &size) != 0) return error.OpenPtyFailed;
    const master: Io.File = .{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave: Io.File = .{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    var terminal_open = true;
    defer if (terminal_open) {
        master.close(io);
        slave.close(io);
    };
    for ([_]c_int{ master_fd, slave_fd }) |fd| {
        if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
            return error.CloseOnExecFailed;
    }
    const original = try posix.tcgetattr(slave_fd);
    const self = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self);
    var environment = try init.environ_map.clone(gpa);
    defer environment.deinit();
    try environment.put("TERM", "xterm");
    try environment.put("HABUSH_LINE_EDIT", "on");
    try environment.put("HABUSH_SHELL_INTEGRATION", "off");
    var child = try std.process.spawn(io, .{
        .argv = if (config_path) |path| &.{ self, "--session", args[1], path } else &.{ self, "--session", args[1] },
        .environ_map = &environment,
        .stdin = .{ .file = slave },
        .stdout = .{ .file = slave },
        .stderr = .{ .file = slave },
    });
    defer {
        const foreground = if (child.id != null) tcgetpgrp(slave_fd) else 0;
        // Closing the PTY first also unblocks terminal draining during exit.
        master.close(io);
        slave.close(io);
        terminal_open = false;
        if (child.id != null) {
            if (foreground > 0) posix.kill(-foreground, .KILL) catch {};
            child.kill(io);
        }
    }
    var terminal: Terminal = .{
        .io = io,
        .master = master,
        .deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(15)),
    };
    errdefer std.debug.print("PTY output:\n{s}\n", .{terminal.output[0..terminal.len]});
    _ = try terminal.expect(ready);
    if (args.len == 2) try std.testing.expect(std.mem.indexOf(u8, terminal.output[0..terminal.len], "\x1b[0;32;49m日> \x1b[0m") != null);
    try std.testing.expect(!(try posix.tcgetattr(slave_fd)).lflag.ICANON);

    try master.writeStreamingAll(io, "/bin/echo CLEAR\x02\x0c!\x18\r");
    const cleared = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "\x1b[2J\x1b[H") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "CLEA!R\r\n") != null);
    try master.writeStreamingAll(io, ")");
    const diagnosed = try terminal.expect("error: expected command");
    try std.testing.expect(std.mem.indexOf(u8, diagnosed, "\x1b[4;31m)") != null);
    try master.writeStreamingAll(io, "\x15/bin/echo DIAGNOSTIC:$?\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "DIAGNOSTIC:0\r\n") != null);

    if (args.len == 3) {
        try pluginScenario(io, master, &terminal);
    } else {
        try historyScenario(io, master, &terminal);
        try master.writeStreamingAll(io, "jjjjjjjjj; /bin/echo STATUS:$?\r");
        const missing = try terminal.expect(ready);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, missing, "habush: jjjjjjjjj: command not found\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, missing, "STATUS:127\r\n") != null);
        try master.writeStreamingAll(io, "jjjjjjjjj 2>&1 | /usr/bin/grep -q 'habush: jjjjjjjjj: command not found'; /bin/echo REDIRECT:$?\r");
        const redirected = try terminal.expect(ready);
        try std.testing.expect(std.mem.indexOf(u8, redirected, "REDIRECT:0\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, redirected, "habush: jjjjjjjjj: command not found\r\n") == null);
        try functionCompletionScenario(io, master, &terminal);
        try master.writeStreamingAll(io, "PATH=; habush_completion_probe() { /bin/echo COMPLETION:$1; }\r");
        _ = try terminal.expect(ready);
        try master.writeStreamingAll(io, "habush_completion_pr\t literal\r");
        try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "COMPLETION:literal\r\n") != null);

        // TODO: Remove this quarantine with https://codeberg.org/ziglang/zig/pulls/36010.
        if (@import("builtin").target.os.tag == .macos and
            std.mem.eql(u8, init.environ_map.get("HABUSH_TEST_SKIP_ZIG_36010") orelse "", "1"))
        {
            std.debug.print("SKIP: PTY Ctrl-C check (Zig PR #36010)\n", .{});
        } else {
            try master.writeStreamingAll(io, "pwd; while true; do :; done\r");
            _ = try terminal.expect("\x1b[?2004l");
            try master.writeStreamingAll(io, "\x03");
            _ = try terminal.expect(ready);
            try master.writeStreamingAll(io, "/bin/echo INTERRUPT:$?\r");
            try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "INTERRUPT:130\r\n") != null);
        }

        try master.writeStreamingAll(io, ")\r");
        try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "expected command") != null);

        for ([_]bool{ false, true }) |foreground_wait| {
            try master.writeStreamingAll(io, "/bin/sh -c '/bin/sleep 0.2; exit 23' & job=$!; /bin/echo BACKGROUND:$job\r");
            const output = try terminal.expect(ready);
            const marker = std.mem.lastIndexOf(u8, output, "BACKGROUND:") orelse return error.MissingProcessId;
            const end = std.mem.indexOfScalarPos(u8, output, marker, '\r') orelse return error.MissingProcessId;
            const background = try std.fmt.parseInt(posix.pid_t, output[marker + "BACKGROUND:".len .. end], 10);
            if (foreground_wait) {
                try master.writeStreamingAll(io, "/bin/sleep 1\r");
                _ = try terminal.expect("\x1b[?2004l");
            }
            while (true) {
                posix.kill(background, @fromBackingInt(0)) catch |err| switch (err) {
                    error.ProcessNotFound => break,
                    else => return err,
                };
                try terminal.pause();
            }
            if (foreground_wait) _ = try terminal.expect(ready);
            try master.writeStreamingAll(io, "wait \"$job\"; /bin/echo WAIT:$?\r");
            try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "WAIT:23\r\n") != null);
        }

        try master.writeStreamingAll(io, "/bin/cat\r");
        _ = try terminal.expect("\x1b[?2004l");
        while (tcgetpgrp(slave_fd) == child.id.?) try terminal.pause();
        const cooked = try posix.tcgetattr(slave_fd);
        try std.testing.expect(cooked.lflag.ICANON and cooked.lflag.ECHO and cooked.lflag.ISIG);
        // macOS revokes a PTY when its session leader exits; inspect it beforehand.
        var restored_flags = cooked.lflag;
        // PENDIN is kernel input state, not an editor setting.
        if (@hasField(@TypeOf(restored_flags), "PENDIN")) restored_flags.PENDIN = original.lflag.PENDIN;
        try std.testing.expectEqual(original.lflag, restored_flags);
        try std.testing.expectEqual(original.iflag, cooked.iflag);
        try std.testing.expectEqual(original.oflag, cooked.oflag);
        try std.testing.expectEqualSlices(u8, &original.cc, &cooked.cc);
        try master.writeStreamingAll(io, "child-stdin\n");
        _ = try terminal.expect("child-stdin\r\nchild-stdin\r\n");
        try master.writeStreamingAll(io, "\x04");
        _ = try terminal.expect(ready);
    }
    try master.writeStreamingAll(io, "exit 0\r");
    var status: c_int = undefined;
    while (true) {
        const rc = posix.system.waitpid(child.id.?, &status, posix.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) break,
            .INTR => {},
            else => return error.WaitFailed,
        }
        terminal.drain() catch |err| switch (err) {
            error.EndOfStream => try terminal.pause(),
            else => return err,
        };
    }
    child.id = null;
    const bits: u32 = @bitCast(status);
    try std.testing.expect(posix.W.IFEXITED(bits) and posix.W.EXITSTATUS(bits) == 0);
}

const Terminal = struct {
    io: Io,
    master: Io.File,
    deadline: Io.Timestamp,
    output: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn checkDeadline(terminal: *Terminal) !void {
        if (Io.Timestamp.now(terminal.io, .awake).nanoseconds >= terminal.deadline.nanoseconds)
            return error.TerminalTestTimedOut;
    }

    fn pause(terminal: *Terminal) !void {
        try terminal.checkDeadline();
        try terminal.io.sleep(.fromMilliseconds(5), .awake);
    }

    fn expect(terminal: *Terminal, needle: []const u8) ![]const u8 {
        terminal.len = 0;
        while (std.mem.indexOf(u8, terminal.output[0..terminal.len], needle) == null) {
            try terminal.drain();
        }
        return terminal.output[0..terminal.len];
    }

    fn drain(terminal: *Terminal) !void {
        try terminal.checkDeadline();
        var fds = [_]posix.pollfd{.{ .fd = terminal.master.handle, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 50) == 0) return;
        if (terminal.len == terminal.output.len) return error.TerminalOutputLimitExceeded;
        const count = try terminal.master.readStreaming(terminal.io, &.{terminal.output[terminal.len..]});
        if (count == 0) return error.EndOfStream;
        terminal.len += count;
    }
};

fn functionCompletionScenario(io: Io, master: Io.File, terminal: *Terminal) !void {
    try master.writeStreamingAll(io, "__ec() { /usr/bin/printf '%s\\0' \"$3-$1 '\\$(missing)\"; }; complete -F __ec /bin/echo; false\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo prev va\x00 STATUS:$?\r");
    var output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "prev prev-va '$(missing) STATUS:1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command not found") == null);
    // A successful empty result suppresses the otherwise unique README match.
    try master.writeStreamingAll(io, "__ec() { :; }\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo READ\t\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "READ\r\n") != null);
    try master.writeStreamingAll(io, "__ec() { /usr/bin/printf unterminated; }\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo READ\t\x15/bin/echo FALLBACK-OK\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "partial results") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "FALLBACK-OK\r\n") != null);
    try master.writeStreamingAll(io, "__ec() { /bin/sleep 5; }\r");
    _ = try terminal.expect(ready);
    const start = Io.Timestamp.now(io, .awake);
    try master.writeStreamingAll(io, "/bin/echo READ\t\x15/bin/echo TIMEOUT-OK\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "TIMEOUT-OK\r\n") != null);
    try std.testing.expect(Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds < Io.Duration.fromSeconds(2).nanoseconds);
    try master.writeStreamingAll(io, "complete -r /bin/echo\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo READ\t\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "README.md\r\n") != null);
}

fn historyScenario(io: Io, master: Io.File, terminal: *Terminal) !void {
    try master.writeStreamingAll(io, "/bin/echo HISTORY:first\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "value=second; /bin/echo HISTORY:$value\r");
    _ = try terminal.expect(ready);
    // Up traverses all history even when the draft has a different prefix.
    try master.writeStreamingAll(io, "/bin/echo draft\x1b[A\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "HISTORY:second\r\n") != null);
    try master.writeStreamingAll(io, "/bin/echo DRAFT\x02\x1b[A\x1b[B!\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "DRAF!T\r\n") != null);
    try master.writeStreamingAll(io, "/bin/cat <<'EOF'\rliteral $(missing)\rEOF\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "\x1b[A\r");
    const output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "literal $(missing)\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command not found") == null);
    // Edit an earlier continuation line before submitting the whole command.
    try master.writeStreamingAll(io, "if true; then\rresult=wrong\rfi\x1b[A\x01\x0bresult=right\x1b[B\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo EDITED:$result\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "EDITED:right\r\n") != null);
}

fn pluginScenario(io: Io, master: Io.File, terminal: *Terminal) !void {
    try master.writeStreamingAll(io, "PATH=; hb-demo 'literal arg'; /bin/echo STATUS:$?\r");
    var output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "VALUE:literal arg\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STATUS:7\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo read <<'END'\rscoped input\rEND\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "INPUT:scoped input\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo sec\x00\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "VALUE:second '$(missing)\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command not found") == null);
    try master.writeStreamingAll(io, "hb-demo \t\x1b[B\r\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "VALUE:second '$(missing)\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo \tq\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "VALUE:q\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo fail; /bin/echo RECOVER:$?\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "extension failed: trapped") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RECOVER:1\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo fail\t\x15/bin/echo INPUT-OK\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "INPUT-OK\r\n") != null);
    try master.writeStreamingAll(io, "hb-demo loop\r");
    _ = try terminal.expect("RUNNING\r\n");
    try master.writeStreamingAll(io, "\x03");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo INTERRUPT:$?; hb-demo after\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "INTERRUPT:130\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VALUE:after\r\n") != null);
    // A completion-only plugin augments an existing executable, then a shell
    // registration replaces it without changing command execution.
    try master.writeStreamingAll(io, "/bin/echo sec\t STATUS:$?\r");
    output = try terminal.expect(ready);
    try std.testing.expect(std.mem.indexOf(u8, output, "second '$(missing) STATUS:7\r\n") != null);
    try master.writeStreamingAll(io, "__override() { /usr/bin/printf '%s\\0' 'override choice'; }; complete -F __override /bin/echo\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo ov\t\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "override choice\r\n") != null);
    try master.writeStreamingAll(io, "complete -r /bin/echo\r");
    _ = try terminal.expect(ready);
    try master.writeStreamingAll(io, "/bin/echo READ\t\r");
    try std.testing.expect(std.mem.indexOf(u8, try terminal.expect(ready), "README.md\r\n") != null);
}
