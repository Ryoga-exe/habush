//! Encoders for the small set of OSC messages emitted by the interactive shell.
//! Paths remain bytes. Payloads are validated before writing a sequence.

const std = @import("std");

pub const PathStyle = enum { posix, windows };
pub const Mark = enum { prompt_start, prompt_end, command_start };
pub const WorkingDirectoryError = std.Io.Writer.Error || error{
    InvalidWorkingDirectory,
    InvalidHost,
    PayloadTooLong,
};

const max_sequence_bytes = 16 * 1024;

pub fn writeMark(writer: *std.Io.Writer, mark: Mark) std.Io.Writer.Error!void {
    try writer.writeAll(switch (mark) {
        .prompt_start => "\x1b]133;A\x1b\\",
        .prompt_end => "\x1b]133;B\x1b\\",
        .command_start => "\x1b]133;C\x1b\\",
    });
}

/// A null status closes an interrupted evaluation whose exit status is unknown.
pub fn writeCommandEnd(writer: *std.Io.Writer, status: ?u8) std.Io.Writer.Error!void {
    var buffer: [32]u8 = undefined;
    var sequence: std.Io.Writer = .fixed(&buffer);
    try sequence.writeAll("\x1b]133;D");
    if (status) |value| try sequence.print(";{d}", .{value});
    try sequence.writeAll("\x1b\\");
    try writer.writeAll(sequence.buffered());
}

pub fn writeWorkingDirectory(
    writer: *std.Io.Writer,
    hostname: []const u8,
    path: []const u8,
    style: PathStyle,
) WorkingDirectoryError!void {
    var host = hostname;
    var tail = path;
    var drive = false;
    switch (style) {
        .posix => {
            if (path.len == 0 or path[0] != '/') return error.InvalidWorkingDirectory;
        },
        .windows => {
            if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and
                path[1] == ':' and isSeparator(path[2]))
            {
                drive = true;
            } else if (path.len >= 3 and isSeparator(path[0]) and isSeparator(path[1])) {
                const host_end = std.mem.indexOfAnyPos(u8, path, 2, "\\/") orelse
                    return error.InvalidWorkingDirectory;
                host = path[2..host_end];
                tail = path[host_end..];
                if (tail.len <= 1) return error.InvalidWorkingDirectory;
            } else return error.InvalidWorkingDirectory;
        },
    }
    if (!validHostname(host)) return error.InvalidHost;
    if (std.mem.indexOfScalar(u8, tail, 0) != null) return error.InvalidWorkingDirectory;
    // Every byte can expand to three bytes. Check before putting any output on
    // the terminal; an unsupported path must not leave an unterminated OSC.
    if (tail.len > (max_sequence_bytes - host.len - 32) / 3) return error.PayloadTooLong;

    var buffer: [max_sequence_bytes]u8 = undefined;
    var sequence: std.Io.Writer = .fixed(&buffer);
    try sequence.writeAll("\x1b]7;file://");
    try sequence.writeAll(host);
    if (drive) {
        try sequence.writeByte('/');
        try sequence.writeAll(tail[0..2]);
        tail = tail[2..];
    }
    var segments = std.mem.splitAny(u8, tail, if (style == .windows) "\\/" else "/");
    try (std.Uri.Component{ .raw = segments.first() }).formatEscaped(&sequence);
    while (segments.next()) |segment| {
        try sequence.writeByte('/');
        try (std.Uri.Component{ .raw = segment }).formatEscaped(&sequence);
    }
    try sequence.writeAll("\x1b\\");
    try writer.writeAll(sequence.buffered());
}

fn validHostname(host: []const u8) bool {
    if (host.len == 0 or host.len > 255) return false;
    for (host) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_')
            return false;
    }
    return true;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "cwd messages encode raw bytes and Windows drive and UNC paths" {
    const Case = struct { style: PathStyle, path: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .style = .posix, .path = "/a b/%#\n\x1b\x07/日本/\xff", .expected = "file://host/a%20b/%25%23%0A%1B%07/%E6%97%A5%E6%9C%AC/%FF" },
        .{ .style = .windows, .path = "C:\\a b\\file", .expected = "file://host/C:/a%20b/file" },
        .{ .style = .windows, .path = "\\\\server\\share\\file", .expected = "file://server/share/file" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try writeWorkingDirectory(&output.writer, "host", case.path, case.style);
        try std.testing.expectEqualStrings("\x1b]7;", output.written()[0..4]);
        try std.testing.expectEqualStrings(case.expected, output.written()[4 .. output.written().len - 2]);
        try std.testing.expectEqualStrings("\x1b\\", output.written()[output.written().len - 2 ..]);
    }
}

test "invalid cwd payloads leave the writer untouched" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidHost, writeWorkingDirectory(&output.writer, "host\x1b", "/ok", .posix));
    try std.testing.expectError(error.InvalidWorkingDirectory, writeWorkingDirectory(&output.writer, "host", "relative", .posix));
    try std.testing.expectError(error.InvalidWorkingDirectory, writeWorkingDirectory(&output.writer, "host", "/has\x00nul", .posix));
    try std.testing.expectError(error.InvalidHost, writeWorkingDirectory(&output.writer, "host", "\\\\?\\C:\\path", .windows));
    const large: [max_sequence_bytes]u8 = @splat('/');
    try std.testing.expectError(error.PayloadTooLong, writeWorkingDirectory(&output.writer, "host", &large, .posix));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
