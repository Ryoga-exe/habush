//! One input's editing state. The caller owns terminal I/O and submitted input.
const std = @import("std");
const Buffer = @import("Buffer.zig");
const History = @import("History.zig");
const Completion = @import("Completion.zig");
const Keybind = @import("Keybind.zig");
const Editor = @This();

buffer: Buffer,
history: ?*const History = null,
completion: ?Completion = null,
max_bytes: usize = 64 * 1024,
menu: ?Menu = null,
navigation: History.Navigation = .{},

pub const Menu = struct { result: Completion.Result, selected: usize = 0 };
pub const Effect = enum { redraw, show_candidates, submit, interrupt, eof, clear_screen, bell };

pub fn deinit(editor: *Editor) void {
    editor.navigation.deinit(editor.buffer.gpa);
    editor.buffer.deinit();
    editor.* = undefined;
}

pub fn insert(editor: *Editor, bytes: []const u8) std.mem.Allocator.Error!bool {
    editor.menu = null;
    if (bytes.len > editor.max_bytes -| editor.buffer.text().len or std.mem.indexOfScalar(u8, bytes, 0) != null) return false;
    try editor.buffer.insert(bytes);
    return true;
}

pub fn perform(editor: *Editor, action: Keybind.Action) Completion.Error!Effect {
    const buffer = &editor.buffer;
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
        else => editor.menu = null,
    }
    switch (action) {
        .accept_line => {
            const selection = editor.menu orelse return .submit;
            editor.menu = null;
            return if (try editor.accept(selection.selected)) .redraw else .bell;
        },
        .interrupt => return .interrupt,
        .eof_or_delete => if (buffer.text().len == 0) return .eof else try buffer.delete(),
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
        .complete, .complete_previous => return editor.complete(action == .complete_previous),
        .clear_screen => return .clear_screen,
        .history_previous, .history_next, .history_search_previous, .history_search_next => {
            const previous = action == .history_previous or action == .history_search_previous;
            if (editor.menu) |*selection| {
                const count = selection.result.labels.len;
                selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
                return .show_candidates;
            }
            const history = editor.history orelse return .bell;
            return if (try editor.navigation.move(history, buffer, previous, action == .history_search_previous or action == .history_search_next)) .redraw else .bell;
        },
        .dismiss_completion, .ignore, .unbind => {},
    }
    return .redraw;
}

fn complete(editor: *Editor, previous: bool) Completion.Error!Effect {
    if (editor.menu) |*selection| {
        const count = selection.result.labels.len;
        selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
        return .show_candidates;
    }
    const service = editor.completion orelse return .bell;
    const result = (try service.query(service.userdata, editor.request())) orelse return .bell;
    if (!result.unique()) {
        if (result.labels.len == 0) return .bell;
        editor.menu = .{ .result = result, .selected = if (previous) result.labels.len - 1 else 0 };
        return .show_candidates;
    }
    return if (try editor.accept(0)) .redraw else .bell;
}

fn accept(editor: *Editor, index: usize) Completion.Error!bool {
    const service = editor.completion orelse return false;
    var replacement = (try service.choose(service.userdata, editor.buffer.gpa, editor.request(), index)) orelse return false;
    defer replacement.deinit(editor.buffer.gpa);
    return replacement.apply(&editor.buffer, editor.max_bytes);
}

fn request(editor: *const Editor) Completion.Request {
    return .{ .source = editor.buffer.text(), .cursor = editor.buffer.cursor, .revision = editor.buffer.revision };
}

test "actions work without a terminal and completion selection is one reversible edit" {
    const Service = struct {
        fn query(_: *anyopaque, _: Completion.Request) Completion.Error!?Completion.Result {
            return .{ .labels = &.{ "one", "two" } };
        }
        fn choose(_: *anyopaque, gpa: std.mem.Allocator, req: Completion.Request, index: usize) Completion.Error!?Completion.Edit {
            return .{ .revision = req.revision, .cursor = req.cursor, .start = 0, .end = req.source.len, .text = try gpa.dupe(u8, if (index == 0) "one" else "two") };
        }
    };
    var userdata: u8 = 0;
    var editor: Editor = .{
        .buffer = .{ .gpa = std.testing.allocator },
        .completion = .{ .userdata = &userdata, .query = Service.query, .choose = Service.choose },
    };
    defer editor.deinit();
    try std.testing.expect(try editor.insert("draft"));
    try std.testing.expectEqual(Effect.show_candidates, try editor.perform(.complete));
    try std.testing.expectEqual(Effect.show_candidates, try editor.perform(.history_next));
    try std.testing.expectEqual(Effect.redraw, try editor.perform(.accept_line));
    try std.testing.expectEqualStrings("two", editor.buffer.text());
    _ = try editor.perform(.undo);
    try std.testing.expectEqualStrings("draft", editor.buffer.text());
    const revision = editor.buffer.revision;
    try std.testing.expectEqual(Effect.clear_screen, try editor.perform(.clear_screen));
    try std.testing.expectEqual(revision, editor.buffer.revision);
    try std.testing.expectEqual(Effect.submit, try editor.perform(.accept_line));
    try std.testing.expectEqual(Effect.interrupt, try editor.perform(.interrupt));
    editor.max_bytes = editor.buffer.text().len;
    try std.testing.expect(!try editor.insert("!"));
}
