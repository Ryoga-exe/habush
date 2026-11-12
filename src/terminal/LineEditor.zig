//! Interactive byte editing with application-supplied completion.
//! It reads through the shell's existing one-byte stdin Reader and restores
//! cooked terminal modes before returning, so builtin/child stdin stays shared.
const std = @import("std");
const edit = @import("habush-edit");
const platform = @import("../platform.zig");
const render = @import("render.zig");
const LineEditor = @This();

gpa: std.mem.Allocator,
input: *std.Io.Reader,
output: *std.Io.Writer,
prompt: edit.Prompt,
completion: ?edit.Completion = null,
history: ?*const edit.History = null,
keybinds: []const edit.Keybind = &.{},

pub const max_input_bytes = 64 * 1024;
const Menu = edit.Editor.Menu;

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
    var state: edit.Editor = .{
        .buffer = .{ .gpa = editor.gpa },
        .history = editor.history,
        .completion = editor.completion,
    };
    defer state.deinit();
    const buffer = &state.buffer;
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
                try editor.insertTyped(&state, pending[0..pending_len]);
                pending_len = 0;
                try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
                continue;
            }
            // Preserve an invalid or incomplete prefix, then process this key
            // normally. In particular, Enter and editing keys are never lost.
            try editor.insertTyped(&state, pending[0..pending_len]);
            pending_len = 0;
        }
        var key = edit.Keybind.Key.fromByte(byte);
        if (byte == 27 and (editor.input.bufferedLen() != 0 or terminal.ready(80))) {
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
            if (std.mem.eql(u8, sequence[0..length], "[200~")) {
                state.menu = null;
                try editor.paste(&state);
                try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
                continue;
            }
            key = edit.Keybind.Key.fromEscape(sequence[0..length]) orelse {
                state.menu = null;
                try editor.output.writeByte(7);
                try editor.output.flush();
                continue;
            };
        }
        if (edit.Keybind.lookup(editor.keybinds, key)) |action| {
            switch (try state.perform(action)) {
                .redraw => {},
                .show_candidates => try editor.showCandidates(state.menu.?),
                .bell => try editor.output.writeByte(7),
                .clear_screen => try editor.output.writeAll("\x1b[2J\x1b[H"),
                .submit => {
                    try editor.output.writeAll("\r\n");
                    const line = try editor.gpa.dupeSentinel(u8, buffer.text(), 0);
                    errdefer editor.gpa.free(line);
                    try terminal.restore();
                    return line;
                },
                .interrupt => {
                    try editor.output.writeAll("^C\r\n");
                    try terminal.restore();
                    return error.InputInterrupted;
                },
                .eof => {
                    try terminal.restore();
                    return null;
                },
            }
        } else {
            state.menu = null;
            if (byte >= 0x20 and byte != 127) {
                expected_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                if (expected_len > 1) {
                    pending[0] = byte;
                    pending_len = 1;
                    continue;
                }
                try editor.insertTyped(&state, &.{byte});
            } else {
                try editor.output.writeByte(7);
            }
        }
        try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
    }
}

/// A typed Unicode scalar is one edit and therefore one Undo operation. Invalid
/// input stays byte-preserving; the size limit never leaves half a valid scalar.
fn insertTyped(editor: LineEditor, state: *edit.Editor, bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        for (bytes) |byte| {
            if (!try state.insert(&.{byte})) try editor.output.writeByte(7);
        }
    } else if (!try state.insert(bytes)) try editor.output.writeByte(7);
}

fn paste(editor: LineEditor, state: *edit.Editor) !void {
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
            if (byte == 0 or pasted.items.len + state.buffer.text().len >= max_input_bytes + end.len) {
                discarded = true;
            } else try pasted.append(editor.gpa, byte);
        }
        if (seen >= end.len and std.mem.eql(u8, &tail, end)) {
            if (discarded) {
                try editor.output.writeByte(7);
            } else if (!try state.insert(pasted.items[0 .. pasted.items.len - end.len])) try editor.output.writeByte(7);
            return;
        }
    }
    // An unterminated paste is never submitted as a command on EOF.
    return error.EndOfStream;
}

fn showCandidates(editor: LineEditor, menu: Menu) !void {
    const result = menu.result;
    const max_rows = 8;
    const start = menu.selected / max_rows * max_rows;
    try editor.output.writeAll("\r\n");
    for (result.labels[start..@min(start + max_rows, result.labels.len)], start..) |label, index| {
        try editor.output.writeAll(if (index == menu.selected) "> " else "  ");
        // Labels are data, never terminal sequences. Bound presentation as well
        // as provider output; insertion always uses the complete original value.
        try render.writeVisible(editor.output, label[0..@min(label.len, 256)]);
        if (label.len > 256) try editor.output.writeAll("...");
        try editor.output.writeAll("\r\n");
    }
    if (result.labels.len > max_rows) try editor.output.writeAll("... more matches\r\n");
    if (result.truncated or result.incomplete) try editor.output.writeAll("... partial results\r\n");
}

fn takeByte(input: *std.Io.Reader) std.Io.Reader.Error!?u8 {
    return input.takeByte() catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
}
