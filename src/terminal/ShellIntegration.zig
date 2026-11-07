//! Interactive presentation only. It never observes or modifies shell state.
const std = @import("std");
const osc = @import("osc.zig");
const ShellIntegration = @This();

writer: *std.Io.Writer,
hostname: []const u8,
path_style: osc.PathStyle,
executing: bool = false,

pub const Detection = struct {
    /// The caller checks that both command input and control output are TTYs.
    interactive_terminal: bool,
    setting: ?[]const u8 = null,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    kitty: bool = false,
    windows_terminal: bool = false,
};

pub fn enabled(detection: Detection) bool {
    if (!detection.interactive_terminal) return false;
    const setting = detection.setting orelse "auto";
    if (std.mem.eql(u8, setting, "off")) return false;
    if (std.mem.eql(u8, setting, "on")) return true;
    if (detection.term) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    if (detection.kitty or detection.windows_terminal) return true;
    const program = detection.term_program orelse return false;
    return std.mem.eql(u8, program, "ghostty");
}

pub fn beginPrompt(integration: *ShellIntegration, cwd: ?[]const u8) std.Io.Writer.Error!void {
    std.debug.assert(!integration.executing);
    if (cwd) |path| {
        osc.writeWorkingDirectory(integration.writer, integration.hostname, path, integration.path_style) catch |err| switch (err) {
            error.InvalidWorkingDirectory, error.InvalidHost, error.PayloadTooLong => {},
            error.WriteFailed => return error.WriteFailed,
        };
    }
    try osc.writeMark(integration.writer, .prompt_start);
}

pub fn endPrompt(integration: *ShellIntegration) std.Io.Writer.Error!void {
    try osc.writeMark(integration.writer, .prompt_end);
}

pub fn beginCommand(integration: *ShellIntegration) std.Io.Writer.Error!void {
    std.debug.assert(!integration.executing);
    try osc.writeMark(integration.writer, .command_start);
    try integration.writer.flush();
    integration.executing = true;
}

pub fn endCommand(integration: *ShellIntegration, status: ?u8) std.Io.Writer.Error!void {
    std.debug.assert(integration.executing);
    integration.executing = false;
    try osc.writeCommandEnd(integration.writer, status);
    try integration.writer.flush();
}

test "shell integration is selected explicitly for interactive terminals" {
    try std.testing.expect(enabled(.{ .interactive_terminal = true, .term_program = "ghostty" }));
    try std.testing.expect(!enabled(.{ .interactive_terminal = false, .setting = "on", .term_program = "ghostty" }));
    try std.testing.expect(!enabled(.{ .interactive_terminal = true, .setting = "off", .kitty = true }));
    try std.testing.expect(!enabled(.{ .interactive_terminal = true, .term = "dumb", .windows_terminal = true }));
    try std.testing.expect(!enabled(.{ .interactive_terminal = true, .term = "xterm" }));
    try std.testing.expect(enabled(.{ .interactive_terminal = true, .setting = "on" }));
}

test "prompt and command boundaries carry status without capturing output" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var integration: ShellIntegration = .{ .writer = &output.writer, .hostname = "host", .path_style = .posix };
    try integration.beginPrompt("/work");
    try output.writer.writeAll("habush> ");
    try integration.endPrompt();
    try integration.beginCommand();
    try integration.endCommand(2);
    try integration.beginCommand();
    try integration.endCommand(null);
    try std.testing.expectEqualStrings(
        "\x1b]7;file://host/work\x1b\\\x1b]133;A\x1b\\habush> \x1b]133;B\x1b\\" ++
            "\x1b]133;C\x1b\\\x1b]133;D;2\x1b\\\x1b]133;C\x1b\\\x1b]133;D\x1b\\",
        output.written(),
    );
}

test {
    _ = @import("osc.zig");
    _ = @import("render.zig");
}
