//! Small interactive adapter connecting language completion and byte editing.
//! It reads through the shell's existing one-byte stdin Reader and restores
//! cooked terminal modes before returning, so builtin/child stdin stays shared.
const std = @import("std");
const habush = @import("habush");
const platform = @import("../platform.zig");
const render = @import("render.zig");
const LineEditor = @This();

gpa: std.mem.Allocator,
io: std.Io,
input: *std.Io.Reader,
output: *std.Io.Writer,
session: *habush.Session,
prompt: []const u8,
prefix: []const u8,
allow_completion: bool = true,

const max_input_bytes = 64 * 1024;

pub fn read(editor: LineEditor) !?[:0]u8 {
    var terminal = try platform.LineInput.init() orelse return error.EditorUnavailable;
    defer terminal.deinit();
    // Pasted newlines stay in the buffer and execute only after explicit Enter.
    try editor.output.writeAll("\x1b[?2004h");
    try editor.output.flush();
    defer {
        editor.output.writeAll("\x1b[?2004l") catch {};
        editor.output.flush() catch {};
    }
    var buffer: habush.edit.Buffer = .{ .gpa = editor.gpa };
    defer buffer.deinit();
    var pending: [4]u8 = undefined;
    var pending_len: usize = 0;
    var expected_len: usize = 0;
    while (true) {
        const byte = try takeByte(editor.input) orelse {
            try terminal.restore();
            return null;
        };
        if (pending_len != 0) {
            if (byte & 0xc0 == 0x80) {
                pending[pending_len] = byte;
                pending_len += 1;
                if (pending_len != expected_len) continue;
                try editor.insertTyped(&buffer, pending[0..pending_len]);
                pending_len = 0;
                try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
                continue;
            }
            // Preserve an invalid or incomplete prefix, then process this key
            // normally. In particular, Enter and editing keys are never lost.
            try editor.insertTyped(&buffer, pending[0..pending_len]);
            pending_len = 0;
        }
        switch (byte) {
            '\r', '\n' => {
                try editor.output.writeAll("\r\n");
                const line = try editor.gpa.dupeZ(u8, buffer.text());
                errdefer editor.gpa.free(line);
                try terminal.restore();
                return line;
            },
            3 => {
                try editor.output.writeAll("^C\r\n");
                try terminal.restore();
                return error.InputInterrupted;
            },
            4 => if (buffer.text().len == 0) {
                try terminal.restore();
                return null;
            } else try buffer.delete(),
            1 => buffer.cursor = 0,
            5 => buffer.cursor = buffer.text().len,
            2 => buffer.left(),
            6 => buffer.right(),
            8, 127 => try buffer.backspace(),
            11 => try buffer.replace(buffer.cursor, buffer.text().len, ""),
            21 => try buffer.replace(0, buffer.cursor, ""),
            31 => {
                _ = buffer.undo();
            },
            '\t' => if (!editor.allow_completion or !try editor.complete(&buffer)) try editor.output.writeByte(7),
            27 => {
                if (editor.input.bufferedLen() == 0 and !terminal.ready(80)) continue;
                var sequence: [16]u8 = undefined;
                var length: usize = 0;
                while (length < sequence.len) {
                    const next = try takeByte(editor.input) orelse break;
                    sequence[length] = next;
                    length += 1;
                    if (length == 1 and next != '[' and next != 'O') break;
                    if (length >= 2 and (std.ascii.isAlphabetic(next) or next == '~')) break;
                    if (editor.input.bufferedLen() == 0 and !terminal.ready(80)) break;
                }
                const key = sequence[0..length];
                if (std.mem.eql(u8, key, "[D") or std.mem.eql(u8, key, "OD")) buffer.left() else if (std.mem.eql(u8, key, "[C") or std.mem.eql(u8, key, "OC")) buffer.right() else if (std.mem.eql(u8, key, "[H") or std.mem.eql(u8, key, "OH") or std.mem.eql(u8, key, "[1~")) buffer.cursor = 0 else if (std.mem.eql(u8, key, "[F") or std.mem.eql(u8, key, "OF") or std.mem.eql(u8, key, "[4~")) buffer.cursor = buffer.text().len else if (std.mem.eql(u8, key, "[3~")) try buffer.delete() else if (std.mem.eql(u8, key, "[200~")) try editor.paste(&buffer) else try editor.output.writeByte(7);
            },
            else => {
                if (byte >= 0x20) {
                    expected_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                    if (expected_len > 1) {
                        pending[0] = byte;
                        pending_len = 1;
                        continue;
                    }
                    try editor.insertTyped(&buffer, &.{byte});
                } else {
                    try editor.output.writeByte(7);
                }
            },
        }
        try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
    }
}

/// A typed Unicode scalar is one edit and therefore one Undo operation. Invalid
/// input stays byte-preserving; the size limit never leaves half a valid scalar.
fn insertTyped(editor: LineEditor, buffer: *habush.edit.Buffer, bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        for (bytes) |byte| {
            if (buffer.text().len < max_input_bytes)
                try buffer.insert(&.{byte})
            else
                try editor.output.writeByte(7);
        }
        return;
    }
    if (bytes.len <= max_input_bytes -| buffer.text().len)
        try buffer.insert(bytes)
    else
        try editor.output.writeByte(7);
}

fn paste(editor: LineEditor, buffer: *habush.edit.Buffer) !void {
    const end = "\x1b[201~";
    var pasted: std.ArrayList(u8) = .empty;
    defer pasted.deinit(editor.gpa);
    var discarded = false;
    var tail: [end.len]u8 = @splat(0);
    var seen: usize = 0;
    while (try takeByte(editor.input)) |byte| {
        std.mem.copyForwards(u8, tail[0 .. tail.len - 1], tail[1..]);
        tail[tail.len - 1] = byte;
        seen += 1;
        if (!discarded) {
            if (byte == 0 or pasted.items.len + buffer.text().len >= max_input_bytes + end.len) {
                discarded = true;
            } else try pasted.append(editor.gpa, byte);
        }
        if (seen >= end.len and std.mem.eql(u8, &tail, end)) {
            if (discarded) {
                try editor.output.writeByte(7);
            } else try buffer.insert(pasted.items[0 .. pasted.items.len - end.len]);
            return;
        }
    }
    // An unterminated paste is never submitted as a command on EOF.
    return error.EndOfStream;
}

fn complete(editor: LineEditor, buffer: *habush.edit.Buffer) !bool {
    const source = try std.mem.concat(editor.gpa, u8, &.{ editor.prefix, buffer.text() });
    defer editor.gpa.free(source);
    const context = habush.Completion.inspect(source, editor.prefix.len + buffer.cursor, buffer.revision) catch return false;
    if (context.replace.start < editor.prefix.len) return false;
    const prefix = context.literalPrefix(editor.gpa) catch |err| switch (err) {
        error.UnsupportedContext => return false,
        else => return err,
    };
    defer editor.gpa.free(prefix);
    var candidates: Candidates = .{ .gpa = editor.gpa };
    defer candidates.deinit();
    if (context.kind == .command and std.mem.indexOfScalar(u8, prefix, '/') == null) {
        inline for (std.meta.fields(habush.Builtin.Tag)) |field| {
            if (std.mem.startsWith(u8, field.name, prefix)) try candidates.add(field.name);
        }
    } else if (context.kind == .command or context.kind == .argument or context.kind == .redirection) {
        const cwd = editor.session.workingDirectory() orelse return false;
        var directory = std.Io.Dir.openDirAbsolute(editor.io, cwd, .{ .iterate = true }) catch return false;
        defer directory.close(editor.io);
        const slash = std.mem.lastIndexOfScalar(u8, prefix, '/');
        const dirname = if (slash) |index| prefix[0 .. index + 1] else "";
        const basename = if (slash) |index| prefix[index + 1 ..] else prefix;
        var child_directory: ?std.Io.Dir = if (dirname.len != 0)
            directory.openDir(editor.io, dirname, .{ .iterate = true }) catch return false
        else
            null;
        defer if (child_directory) |dir| dir.close(editor.io);
        var iterator = (child_directory orelse directory).iterate();
        var scanned: usize = 0;
        while (scanned < 512) : (scanned += 1) {
            const entry = (iterator.next(editor.io) catch return false) orelse break;
            if (!std.mem.startsWith(u8, entry.name, basename)) continue;
            if (basename.len == 0 and std.mem.startsWith(u8, entry.name, ".")) continue;
            const value = try std.mem.concat(editor.gpa, u8, &.{ dirname, entry.name, if (entry.kind == .directory) "/" else "" });
            defer editor.gpa.free(value);
            try candidates.add(value);
        }
        if (scanned == 512) return false;
    }
    const value = candidates.value orelse return false;
    if (candidates.ambiguous) return false;
    var edit = habush.Completion.makeEdit(editor.gpa, context, source, buffer.revision, value) catch |err| switch (err) {
        error.StaleContext, error.UnsupportedContext, error.InvalidCandidate => return false,
        else => return err,
    };
    defer edit.deinit(editor.gpa);
    try buffer.replace(edit.range.start - editor.prefix.len, edit.range.end - editor.prefix.len, edit.text);
    return true;
}

const Candidates = struct {
    gpa: std.mem.Allocator,
    value: ?[]u8 = null,
    ambiguous: bool = false,

    fn add(candidates: *Candidates, value: []const u8) !void {
        if (candidates.value) |existing| {
            if (!std.mem.eql(u8, existing, value)) candidates.ambiguous = true;
        } else candidates.value = try candidates.gpa.dupe(u8, value);
    }

    fn deinit(candidates: *Candidates) void {
        if (candidates.value) |value| candidates.gpa.free(value);
    }
};

fn takeByte(input: *std.Io.Reader) std.Io.Reader.Error!?u8 {
    return input.takeByte() catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
}
