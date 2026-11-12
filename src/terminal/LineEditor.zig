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
prompt: []const u8,
completion: ?edit.Completion = null,
history: ?*const edit.History = null,
keybinds: []const edit.Keybind = &.{},

pub const max_input_bytes = 64 * 1024;
const Menu = struct { result: edit.Completion.Result, selected: usize = 0 };

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
    var buffer: edit.Buffer = .{ .gpa = editor.gpa };
    defer buffer.deinit();
    var menu: ?Menu = null;
    var navigation: edit.History.Navigation = .{};
    defer navigation.deinit(editor.gpa);
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
                menu = null;
                try editor.paste(&buffer);
                try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
                continue;
            }
            key = edit.Keybind.Key.fromEscape(sequence[0..length]) orelse {
                menu = null;
                try editor.output.writeByte(7);
                try editor.output.flush();
                continue;
            };
        }
        if (edit.Keybind.lookup(editor.keybinds, key)) |action| {
            switch (action) {
                .accept_line,
                .complete,
                .complete_previous,
                .history_previous,
                .history_next,
                .history_search_previous,
                .history_search_next,
                .ignore,
                => {},
                else => menu = null,
            }
            switch (action) {
                .accept_line => {
                    if (menu) |selection| {
                        menu = null;
                        if (!try editor.accept(&buffer, selection.selected)) try editor.output.writeByte(7);
                        try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
                        continue;
                    }
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
                .eof_or_delete => if (buffer.text().len == 0) {
                    try terminal.restore();
                    return null;
                } else try buffer.delete(),
                .cursor_start => buffer.cursor = 0,
                .cursor_end => buffer.cursor = buffer.text().len,
                .cursor_left => buffer.left(),
                .cursor_right => buffer.right(),
                .backspace => try buffer.backspace(),
                .delete => try buffer.delete(),
                .kill_to_end => try buffer.replace(buffer.cursor, buffer.text().len, ""),
                .kill_to_start => try buffer.replace(0, buffer.cursor, ""),
                .undo => {
                    _ = buffer.undo();
                },
                .complete, .complete_previous => if (!try editor.complete(&buffer, &menu, action == .complete_previous)) try editor.output.writeByte(7),
                .clear_screen => try editor.output.writeAll("\x1b[2J\x1b[H"),
                .history_previous, .history_next, .history_search_previous, .history_search_next => {
                    const previous = action == .history_previous or action == .history_search_previous;
                    if (menu) |*selection| {
                        const count = selection.result.labels.len;
                        selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
                        try editor.showCandidates(selection.*);
                    } else {
                        const moved = if (editor.history) |history|
                            try navigation.move(history, &buffer, previous, action == .history_search_previous or action == .history_search_next)
                        else
                            false;
                        if (!moved) try editor.output.writeByte(7);
                    }
                },
                .dismiss_completion, .ignore => {},
                .unbind => unreachable,
            }
        } else {
            menu = null;
            if (byte >= 0x20 and byte != 127) {
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
        }
        try render.redraw(editor.output, editor.prompt, buffer.text(), buffer.cursor, terminal.columns());
    }
}

/// A typed Unicode scalar is one edit and therefore one Undo operation. Invalid
/// input stays byte-preserving; the size limit never leaves half a valid scalar.
fn insertTyped(editor: LineEditor, buffer: *edit.Buffer, bytes: []const u8) !void {
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

fn paste(editor: LineEditor, buffer: *edit.Buffer) !void {
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

fn complete(editor: LineEditor, buffer: *edit.Buffer, menu: *?Menu, previous: bool) !bool {
    if (menu.*) |*selection| {
        const count = selection.result.labels.len;
        selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
        try editor.showCandidates(selection.*);
        return true;
    }
    const service = editor.completion orelse return false;
    const request: edit.Completion.Request = .{
        .source = buffer.text(),
        .cursor = buffer.cursor,
        .revision = buffer.revision,
    };
    const result = (try service.query(service.userdata, request)) orelse return false;
    if (!result.unique()) {
        if (result.labels.len == 0) return false;
        menu.* = .{ .result = result, .selected = if (previous) result.labels.len - 1 else 0 };
        try editor.showCandidates(menu.*.?);
        return true;
    }
    return editor.accept(buffer, 0);
}

fn accept(editor: LineEditor, buffer: *edit.Buffer, index: usize) !bool {
    const service = editor.completion orelse return false;
    const request: edit.Completion.Request = .{ .source = buffer.text(), .cursor = buffer.cursor, .revision = buffer.revision };
    var replacement = (try service.choose(service.userdata, editor.gpa, request, index)) orelse return false;
    defer replacement.deinit(editor.gpa);
    return replacement.apply(buffer, max_input_bytes);
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
