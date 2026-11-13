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
search: ?Search = null,
input_id: u64 = 0,
request_id: u64 = 0,
completion_pending: bool = false,

pub const Search = struct {
    query: Buffer,
    index: ?usize = null,
    failed: bool = false,

    fn find(search: *Search, history: *const History, before: usize, max_bytes: usize) bool {
        var index = before;
        while (index != 0) {
            index -= 1;
            const entry = history.entries.items[index];
            if (entry.len <= max_bytes and std.mem.indexOf(u8, entry, search.query.text()) != null) {
                search.index = index;
                search.failed = false;
                return true;
            }
        }
        search.failed = true;
        return false;
    }
};

pub const Menu = struct { result: Completion.Result, selected: usize = 0 };
pub const Effect = enum { redraw, show_candidates, submit, interrupt, eof, clear_screen, bell };
pub const Inspector = struct {
    userdata: ?*anyopaque = null,
    inspect: *const fn (?*anyopaque, []const u8) Completion.Error!Status,
    pub const Status = enum { complete, incomplete, invalid };
};

pub fn deinit(editor: *Editor) void {
    editor.cancelCompletion();
    editor.endSearch();
    editor.navigation.deinit(editor.buffer.gpa);
    editor.buffer.deinit();
    editor.* = undefined;
}

pub fn insert(editor: *Editor, bytes: []const u8) std.mem.Allocator.Error!bool {
    editor.cancelCompletion();
    if (editor.search) |*search| {
        if (bytes.len > editor.max_bytes -| search.query.text().len or std.mem.indexOfScalar(u8, bytes, 0) != null) return false;
        try search.query.insert(bytes);
        search.index = null;
        _ = search.find(editor.history.?, editor.history.?.entries.items.len, editor.max_bytes);
        return true;
    }
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
    if (editor.search != null) return &.{};
    const result = editor.diagnostics orelse return &.{};
    return if (result.revision == editor.buffer.revision) result.items else &.{};
}

pub fn perform(editor: *Editor, action: Keybind.Action) Completion.Error!Effect {
    if (editor.search != null) return editor.searchAction(action);
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
        else => editor.cancelCompletion(),
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
        .cursor_word_left => buffer.cursor = buffer.wordStart(),
        .cursor_word_right => buffer.cursor = buffer.wordEnd(),
        .backspace => try buffer.backspace(),
        .delete => try buffer.delete(),
        .kill_to_end => {
            const end = buffer.lineEnd();
            try buffer.replace(buffer.cursor, if (end == buffer.cursor and end < buffer.text().len) end + 1 else end, "");
        },
        .kill_to_start => try buffer.replace(buffer.lineStart(), buffer.cursor, ""),
        .kill_word_backward => {
            const start = buffer.wordStart();
            if (start != buffer.cursor) try buffer.replace(start, buffer.cursor, "");
        },
        .kill_word_forward => {
            const end = buffer.wordEnd();
            if (end != buffer.cursor) try buffer.replace(buffer.cursor, end, "");
        },
        .insert_newline => return if (try editor.insert("\n")) .redraw else .bell,
        .undo => {
            _ = buffer.undo();
        },
        .complete, .complete_previous => return editor.complete(action == .complete_previous),
        .history_search => {
            const history = editor.history orelse return .bell;
            editor.search = .{ .query = .{ .gpa = buffer.gpa } };
            _ = editor.search.?.find(history, history.entries.items.len, editor.max_bytes);
        },
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

pub fn searchMatch(editor: *const Editor) ?[]const u8 {
    const search = editor.search orelse return null;
    return editor.history.?.entries.items[search.index orelse return null];
}

fn endSearch(editor: *Editor) void {
    if (editor.search) |*search| search.query.deinit();
    editor.search = null;
}

fn searchAction(editor: *Editor, action: Keybind.Action) Completion.Error!Effect {
    const search = &editor.search.?;
    const history = editor.history.?;
    switch (action) {
        .history_search => return if (search.find(history, search.index orelse history.entries.items.len, editor.max_bytes)) .redraw else .bell,
        .backspace, .kill_word_backward => {
            if (action == .backspace) {
                try search.query.backspace();
            } else {
                const start = search.query.wordStart();
                if (start != search.query.cursor) try search.query.replace(start, search.query.cursor, "");
            }
            search.index = null;
            _ = search.find(history, history.entries.items.len, editor.max_bytes);
        },
        .accept_line => {
            const match = editor.searchMatch() orelse return .bell;
            try editor.buffer.replace(0, editor.buffer.text().len, match);
            editor.navigation.deinit(editor.buffer.gpa);
            editor.navigation = .{};
            editor.endSearch();
        },
        .dismiss_completion, .eof_or_delete => editor.endSearch(),
        .interrupt => return .interrupt,
        .clear_screen => return .clear_screen,
        .ignore, .unbind => {},
        else => return .bell,
    }
    return .redraw;
}

fn complete(editor: *Editor, previous: bool) Completion.Error!Effect {
    if (editor.completion_pending) return .redraw;
    if (editor.menu) |*selection| {
        const count = selection.result.labels.len;
        selection.selected = if (previous) (selection.selected + count - 1) % count else (selection.selected + 1) % count;
        return .show_candidates;
    }
    const service = editor.completion orelse return .bell;
    editor.request_id +%= 1;
    const result = (try service.query(service.userdata, editor.request())) orelse return .bell;
    return editor.receiveCompletion(result, previous);
}

pub fn pollCompletion(editor: *Editor) Completion.Error!?Effect {
    if (!editor.completion_pending) return null;
    const service = editor.completion.?;
    const poll = service.poll orelse return null;
    const result = (try poll(service.userdata, editor.request())) orelse return null;
    return try editor.receiveCompletion(result, false);
}

fn receiveCompletion(editor: *Editor, result: Completion.Result, previous: bool) Completion.Error!Effect {
    editor.completion_pending = result.pending;
    if (result.pending) return .redraw;
    if (!result.unique()) {
        if (result.labels.len == 0) return .bell;
        editor.menu = .{ .result = result, .selected = if (previous) result.labels.len - 1 else 0 };
        return .show_candidates;
    }
    return if (try editor.accept(0)) .redraw else .bell;
}

fn cancelCompletion(editor: *Editor) void {
    if (editor.completion_pending or editor.menu != null) {
        if (editor.completion) |service| if (service.cancel) |cancel| cancel(service.userdata);
    }
    editor.completion_pending = false;
    editor.menu = null;
}

fn accept(editor: *Editor, index: usize) Completion.Error!bool {
    const service = editor.completion orelse return false;
    var replacement = (try service.choose(service.userdata, editor.buffer.gpa, editor.request(), index)) orelse return false;
    defer replacement.deinit(editor.buffer.gpa);
    return replacement.apply(&editor.buffer, editor.max_bytes);
}

fn request(editor: *const Editor) Completion.Request {
    return .{ .source = editor.buffer.text(), .cursor = editor.buffer.cursor, .revision = editor.buffer.revision, .input_id = editor.input_id, .id = editor.request_id };
}

test "reverse history search previews without execution, restores drafts, and accepts one undoable edit" {
    const gpa = std.testing.allocator;
    var history: History = .{ .gpa = gpa };
    defer history.deinit();
    try history.append("echo 日本 one");
    try history.append("cat <<EOF\n日本 two\nEOF");
    var editor: Editor = .{ .buffer = .{ .gpa = gpa }, .history = &history };
    defer editor.deinit();
    try std.testing.expect(try editor.insert("draft"));
    editor.buffer.cursor = 2;
    _ = try editor.perform(.history_search);
    try std.testing.expect(try editor.insert("日本"));
    try std.testing.expectEqualStrings("cat <<EOF\n日本 two\nEOF", editor.searchMatch().?);
    _ = try editor.perform(.history_search);
    try std.testing.expectEqualStrings("echo 日本 one", editor.searchMatch().?);
    _ = try editor.perform(.dismiss_completion);
    try std.testing.expectEqualStrings("draft", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), editor.buffer.cursor);
    _ = try editor.perform(.history_search);
    try std.testing.expect(try editor.insert("absent"));
    try std.testing.expectEqual(Effect.bell, try editor.perform(.accept_line));
    _ = try editor.perform(.dismiss_completion);
    _ = try editor.perform(.history_search);
    try std.testing.expect(try editor.insert("日本x"));
    _ = try editor.perform(.backspace);
    try std.testing.expect(try editor.insert(" missing"));
    _ = try editor.perform(.kill_word_backward);
    try std.testing.expectEqualStrings("日本 ", editor.search.?.query.text());
    _ = try editor.perform(.backspace);
    try std.testing.expectEqual(Effect.redraw, try editor.perform(.accept_line));
    try std.testing.expectEqualStrings("cat <<EOF\n日本 two\nEOF", editor.buffer.text());
    try std.testing.expectEqual(Effect.submit, try editor.perform(.accept_line));
    _ = try editor.perform(.undo);
    try std.testing.expectEqualStrings("draft", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), editor.buffer.cursor);
}

test "word actions preserve cursor-only revisions and delete in one undoable edit" {
    var editor: Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer editor.deinit();
    try std.testing.expect(try editor.insert("echo 日\u{3000}本"));
    const revision = editor.buffer.revision;
    _ = try editor.perform(.cursor_word_left);
    try std.testing.expectEqual("echo 日\u{3000}".len, editor.buffer.cursor);
    _ = try editor.perform(.cursor_word_right);
    try std.testing.expectEqual(editor.buffer.text().len, editor.buffer.cursor);
    try std.testing.expectEqual(revision, editor.buffer.revision);
    _ = try editor.perform(.kill_word_backward);
    try std.testing.expectEqualStrings("echo 日\u{3000}", editor.buffer.text());
    const deleted_revision = editor.buffer.revision;
    _ = try editor.perform(.kill_word_forward);
    try std.testing.expectEqual(deleted_revision, editor.buffer.revision);
    _ = try editor.perform(.undo);
    try std.testing.expectEqualStrings("echo 日\u{3000}本", editor.buffer.text());
    _ = try editor.perform(.cursor_word_left);
    _ = try editor.perform(.cursor_word_left);
    _ = try editor.perform(.kill_word_forward);
    try std.testing.expectEqualStrings("echo \u{3000}本", editor.buffer.text());
    editor.buffer.cursor = 0;
    const forward_revision = editor.buffer.revision;
    _ = try editor.perform(.kill_word_backward);
    try std.testing.expectEqual(forward_revision, editor.buffer.revision);
    _ = try editor.perform(.undo);
    try std.testing.expectEqualStrings("echo 日\u{3000}本", editor.buffer.text());
    try std.testing.expectEqual("echo ".len, editor.buffer.cursor);
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
