//! One input's editing state. The caller owns terminal I/O and submitted input.
const std = @import("std");
const Buffer = @import("Buffer.zig");
const History = @import("History.zig");
const Completion = @import("Completion.zig");
const Keybind = @import("Keybind.zig");
const Diagnostic = @import("Diagnostic.zig");
const Editor = @This();

buffer: Buffer,
history: ?*const History = null,
completion: ?Completion = null,
inspector: ?Inspector = null,
max_bytes: usize = 64 * 1024,
menu: ?Menu = null,
navigation: History.Navigation = .{},
diagnostics: ?Diagnostic.Result = null,

pub const Menu = struct { result: Completion.Result, selected: usize = 0 };
pub const Effect = enum { redraw, show_candidates, submit, interrupt, eof, clear_screen, bell };
pub const Inspector = struct {
    userdata: ?*anyopaque = null,
    inspect: *const fn (?*anyopaque, []const u8) Completion.Error!Status,
    pub const Status = enum { complete, incomplete, invalid };
};

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

pub fn setDiagnostics(editor: *Editor, result: Diagnostic.Result) bool {
    if (!result.valid(.{ .source = editor.buffer.text(), .revision = editor.buffer.revision })) return false;
    editor.diagnostics = result;
    return true;
}

pub fn currentDiagnostics(editor: Editor) []const Diagnostic {
    const result = editor.diagnostics orelse return &.{};
    return if (result.revision == editor.buffer.revision) result.items else &.{};
}

pub fn perform(editor: *Editor, action: Keybind.Action) Completion.Error!Effect {
    const buffer = &editor.buffer;
    switch (action) {
        .accept_line,
        .complete,
        .complete_previous,
        .cursor_up,
        .cursor_down,
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
            const selection = editor.menu orelse {
                if (editor.inspector) |inspector| {
                    if (try inspector.inspect(inspector.userdata, buffer.text()) == .incomplete)
                        return if (try editor.insert("\n")) .redraw else .bell;
                }
                return .submit;
            };
            editor.menu = null;
            return if (try editor.accept(selection.selected)) .redraw else .bell;
        },
        .interrupt => return .interrupt,
        .eof_or_delete => if (buffer.text().len == 0) return .eof else try buffer.delete(),
        .cursor_start => buffer.cursor = buffer.lineStart(),
        .cursor_end => buffer.cursor = buffer.lineEnd(),
        .cursor_left => buffer.left(),
        .cursor_right => buffer.right(),
        .backspace => try buffer.backspace(),
        .delete => try buffer.delete(),
        .kill_to_end => {
            const end = buffer.lineEnd();
            try buffer.replace(buffer.cursor, if (end == buffer.cursor and end < buffer.text().len) end + 1 else end, "");
        },
        .kill_to_start => try buffer.replace(buffer.lineStart(), buffer.cursor, ""),
        .insert_newline => return if (try editor.insert("\n")) .redraw else .bell,
        .undo => {
            _ = buffer.undo();
        },
        .complete, .complete_previous => return editor.complete(action == .complete_previous),
        .clear_screen => return .clear_screen,
        .cursor_up, .cursor_down, .history_previous, .history_next, .history_search_previous, .history_search_next => {
            const previous = action == .cursor_up or action == .history_previous or action == .history_search_previous;
            if (editor.menu) |*selection| {
                const count = selection.result.labels.len;
                selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
                return .show_candidates;
            }
            if ((action == .cursor_up or action == .cursor_down) and std.mem.indexOfScalar(u8, buffer.text(), '\n') != null)
                return if (buffer.vertical(previous)) .redraw else .bell;
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

test "multiline actions move between scalar boundaries and insert a continuation" {
    const Inspect = struct {
        fn inspect(_: ?*anyopaque, source: []const u8) Completion.Error!Inspector.Status {
            return if (std.mem.endsWith(u8, source, "done")) .complete else .incomplete;
        }
    };
    var editor: Editor = .{ .buffer = .{ .gpa = std.testing.allocator }, .inspector = .{ .inspect = Inspect.inspect } };
    defer editor.deinit();
    try std.testing.expect(try editor.insert("日本"));
    try std.testing.expectEqual(Effect.redraw, try editor.perform(.accept_line));
    try std.testing.expect(try editor.insert("x"));
    _ = try editor.perform(.cursor_up);
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor);
    _ = try editor.perform(.cursor_end);
    _ = try editor.perform(.backspace);
    try std.testing.expectEqualStrings("日\nx", editor.buffer.text());
    _ = try editor.perform(.cursor_down);
    _ = try editor.perform(.kill_to_start);
    try std.testing.expect(try editor.insert("done"));
    try std.testing.expectEqual(Effect.submit, try editor.perform(.accept_line));
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
    try std.testing.expect(editor.setDiagnostics(.{ .revision = editor.buffer.revision, .items = &.{.{ .start = 0, .end = 1, .message = "warning" }} }));
    try std.testing.expectEqual(@as(usize, 1), editor.currentDiagnostics().len);
    _ = try editor.perform(.backspace);
    try std.testing.expectEqual(@as(usize, 0), editor.currentDiagnostics().len);
    editor.max_bytes = editor.buffer.text().len;
    try std.testing.expect(!try editor.insert("!"));
}
