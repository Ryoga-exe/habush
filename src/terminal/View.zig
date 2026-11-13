//! Repaints the editor-owned rows, keeping the cursor's logical line visible.
const std = @import("std");
const edit = @import("habush-edit");
const render = @import("render.zig");
const View = @This();

frame: std.Io.Writer.Allocating,
previous: std.ArrayList(u8) = .empty,
cursor_row: usize = 0,
rows: usize = 1,
tail_column: ?usize = null,
columns: usize = 0,
terminal_rows: usize = 0,

pub fn deinit(view: *View) void {
    view.previous.deinit(view.frame.allocator);
    view.frame.deinit();
    view.* = undefined;
}

pub fn reset(view: *View) void {
    view.cursor_row = 0;
    view.rows = 1;
    view.tail_column = null;
}

pub fn redraw(view: *View, output: *std.Io.Writer, prompt: edit.Prompt, state: *const edit.Editor, columns: usize, terminal_rows: usize) !void {
    errdefer view.tail_column = null;
    view.frame.clearRetainingCapacity();
    const writer = &view.frame.writer;
    const height = @max(terminal_rows, 3);
    const diagnostics = state.currentDiagnostics();
    const diagnostic_rows = if (height >= 5) @min(@min(diagnostics.len, 3), height / 3) else 0;
    const menu_height = height - diagnostic_rows;
    const menu_limit = @max(@as(usize, 1), @min(@as(usize, 8), menu_height / 2 -| 1));
    const menu_status = if (state.menu) |menu| menu_height > 3 and (menu.result.labels.len > menu_limit or menu.result.incomplete or menu.result.truncated) else false;
    const menu_rows = if (state.menu) |menu| @min(menu.result.labels.len, menu_limit) + @intFromBool(menu_status) else 0;
    const input_rows = @max(@as(usize, 1), height -| (menu_rows + diagnostic_rows + 1 + @intFromBool(state.search != null or state.completion_pending)));
    const source = state.searchMatch() orelse state.buffer.text();
    const cursor = if (state.searchMatch() != null) source.len else state.buffer.cursor;
    const cursor_line = std.mem.count(u8, source[0..cursor], "\n");
    const first_line = cursor_line -| (input_rows - 1);
    if (view.cursor_row != 0) try writer.print("\x1b[{d}A", .{@min(view.cursor_row, height - 1)});
    try writer.writeAll("\r\x1b[J");
    const line_start = writer.end;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_index: usize = 0;
    var source_offset: usize = 0;
    var row: usize = 0;
    var cursor_column: usize = 0;
    while (lines.next()) |line| : (line_index += 1) {
        defer source_offset += line.len + 1;
        if (line_index < first_line) continue;
        if (row == input_rows) break;
        if (row != 0) try writer.writeAll("\r\n");
        const column = try render.inputRow(writer, if (line_index == 0) prompt else edit.Prompt.secondary, line, if (line_index == cursor_line) cursor - source_offset else 0, columns, diagnostics, source_offset);
        if (line_index == cursor_line) cursor_column = column;
        row += 1;
    }
    const line_end = writer.end;
    if (state.menu) |menu| {
        const start = menu.selected / @max(menu_limit, 1) * @max(menu_limit, 1);
        for (menu.result.labels[start..@min(start + menu_limit, menu.result.labels.len)], start..) |label, index| {
            try writer.writeAll("\r\n");
            try writer.writeAll(if (index == menu.selected) "> " else "  ");
            _ = try render.writePrompt(writer, .{ .spans = &.{.{ .text = label[0..@min(label.len, 256)] }} }, columns -| 3);
            row += 1;
        }
        if (menu_status) {
            try writer.writeAll("\r\n");
            const message = if (menu.result.incomplete or menu.result.truncated) "... partial results" else "... more matches";
            _ = try render.writePrompt(writer, .{ .spans = &.{.{ .text = message }} }, columns -| 1);
            row += 1;
        }
    }
    if (state.completion_pending) {
        try writer.writeAll("\r\n");
        _ = try render.writePrompt(writer, .{ .spans = &.{.{ .text = "completing..." }} }, columns -| 1);
        row += 1;
    }
    if (state.search) |search| {
        try writer.writeAll("\r\n");
        _ = try render.writePrompt(writer, .{ .spans = &.{
            .{ .text = if (search.failed) "history (no match): " else "history (Enter selects, Esc cancels): " },
            .{ .text = search.query.text() },
        } }, columns -| 1);
        row += 1;
    }
    for (diagnostics[0..diagnostic_rows]) |diagnostic| {
        try writer.writeAll("\r\n");
        const severity = @tagName(diagnostic.severity);
        try writer.print("{s}: ", .{severity});
        _ = try render.writePrompt(writer, .{ .spans = &.{.{ .text = diagnostic.message }} }, columns -| (severity.len + 3));
        row += 1;
    }
    view.rows = row;
    view.cursor_row = cursor_line - first_line;
    if (row - 1 > view.cursor_row) try writer.print("\x1b[{d}A", .{row - 1 - view.cursor_row});
    try writer.writeByte('\r');
    if (cursor_column != 0) try writer.print("\x1b[{d}C", .{cursor_column});
    const single_line = state.menu == null and state.search == null and !state.completion_pending and diagnostics.len == 0 and
        cursor == source.len and std.mem.indexOfScalar(u8, source, '\n') == null and
        (try render.writePrompt(null, prompt, columns -| 2)) + render.displayWidth(source) < columns -| 1;
    const line = view.frame.written()[line_start..line_end];
    if (!(single_line and columns == view.columns and terminal_rows == view.terminal_rows and
        try view.redrawTail(output, line, cursor_column)))
        try output.writeAll(view.frame.written());
    try output.flush();
    view.tail_column = null;
    if (single_line) {
        view.previous.clearRetainingCapacity();
        try view.previous.appendSlice(view.frame.allocator, line);
        view.tail_column = cursor_column;
    }
    view.columns = columns;
    view.terminal_rows = terminal_rows;
}

fn redrawTail(view: *const View, output: *std.Io.Writer, line: []const u8, column: usize) !bool {
    const previous_column = view.tail_column orelse return false;
    const previous = view.previous.items;
    const appending = line.len >= previous.len;
    const shorter = if (appending) previous else line;
    const longer = if (appending) line else previous;
    if (!std.mem.startsWith(u8, longer, shorter)) return false;
    const suffix = longer[shorter.len..];
    // shortcut: only ASCII suffixes, extend with grapheme-aware widths before optimizing Unicode edits.
    for (suffix) |byte| if (!std.ascii.isPrint(byte)) return false;
    if (appending) {
        try output.writeAll(suffix);
    } else {
        var sequence: [32]u8 = undefined;
        try output.writeAll(try std.fmt.bufPrint(&sequence, "\x1b[{d}D\x1b[K", .{previous_column - column}));
    }
    return true;
}

pub fn finish(view: View, writer: *std.Io.Writer) !void {
    if (view.rows - 1 > view.cursor_row) try writer.print("\x1b[{d}B", .{view.rows - 1 - view.cursor_row});
    try writer.writeAll("\r\n");
    try writer.flush();
}

test "tail edits emit only changed cells and full redraws reach an unbuffered sink together" {
    const Sink = struct {
        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        target: *std.Io.Writer,
        writes: usize = 0,

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const sink: *@This() = @fieldParentPtr("writer", writer);
            sink.writes += 1;
            return sink.target.writeSplat(data, splat);
        }
    };
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var sink: Sink = .{ .target = &output.writer };
    var view: View = .{ .frame = .init(std.testing.allocator) };
    defer view.deinit();
    const prompt: edit.Prompt = .{ .spans = &.{.{ .text = "日> ", .style = .{ .foreground = .green } }} };
    const cases = [_]struct { source: []const u8, delta: ?[]const u8 }{
        .{ .source = "ab", .delta = null },
        .{ .source = "abcd", .delta = "cd" },
        .{ .source = "abc", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "a", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "", .delta = "" },
        .{ .source = "\x1b", .delta = "^[" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "日", .delta = null },
        .{ .source = "日x", .delta = "x" },
        .{ .source = "日", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "", .delta = null },
        .{ .source = "e\xcc\x81", .delta = null },
        .{ .source = "e", .delta = null },
        .{ .source = "ex", .delta = "x" },
        .{ .source = "by", .delta = null },
    };
    for (cases) |case| {
        output.clearRetainingCapacity();
        sink.writes = 0;
        try state.buffer.replace(0, state.buffer.text().len, case.source);
        try view.redraw(&sink.writer, prompt, &state, 40, 8);
        if (case.delta) |delta| {
            try std.testing.expectEqualStrings(delta, output.written());
        } else {
            try std.testing.expect(std.mem.startsWith(u8, output.written(), "\r\x1b[J\x1b[0;32;49m日> \x1b[0m"));
        }
        try std.testing.expectEqual(@as(usize, @intFromBool(output.written().len != 0)), sink.writes);
        try std.testing.expectEqual(@as(usize, 1), view.rows);
        try std.testing.expectEqual(@as(usize, 0), view.cursor_row);
    }
}

test "tail cache is invalidated by overlays, cursor movement, resizing, scrolling and screen clearing" {
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view: View = .{ .frame = .init(std.testing.allocator) };
    defer view.deinit();
    const Change = enum { menu, diagnostics, pending, cursor, columns, height, scroll, multiline, prompt, clear };
    for (std.enums.values(Change)) |change| {
        state.menu = null;
        state.diagnostics = null;
        state.completion_pending = false;
        try state.buffer.replace(0, state.buffer.text().len, "abc");
        try view.redraw(&output.writer, edit.Prompt.primary, &state, 20, 8);
        output.clearRetainingCapacity();
        var columns: usize = 20;
        var height: usize = 8;
        var prompt = edit.Prompt.primary;
        switch (change) {
            .menu => state.menu = .{ .result = .{ .labels = &.{"candidate"} } },
            .diagnostics => try std.testing.expect(state.setDiagnostics(.{ .revision = state.buffer.revision, .items = &.{.{ .start = 0, .end = 1, .severity = .warning, .message = "warning" }} })),
            .pending => state.completion_pending = true,
            .cursor => state.buffer.left(),
            .columns => columns += 1,
            .height => height += 1,
            .scroll => try state.buffer.insert("01234567"),
            .multiline => try state.buffer.insert("\nnext"),
            .prompt => prompt = edit.Prompt.secondary,
            .clear => view.reset(),
        }
        try view.redraw(&output.writer, prompt, &state, columns, height);
        try std.testing.expect(std.mem.startsWith(u8, output.written(), "\r\x1b[J"));
    }
}

test "viewport bounds multiline input and menu while retaining the cursor line" {
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    try std.testing.expect(try state.insert("one\n日本\nthree\nfour\nfive"));
    state.menu = .{ .result = .{ .labels = &.{ "a\x1b", "b" }, .incomplete = true } };
    try std.testing.expect(state.setDiagnostics(.{ .revision = state.buffer.revision, .items = &.{.{ .start = 4, .end = 10, .severity = .@"error", .message = "literal\x1b" }} }));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view: View = .{ .frame = .init(std.testing.allocator) };
    defer view.deinit();
    try view.redraw(&output.writer, edit.Prompt.primary, &state, 20, 6);
    try std.testing.expect(view.rows <= 5);
    try std.testing.expect(view.cursor_row < view.rows);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "five") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "a^[") != null);
    output.clearRetainingCapacity();
    state.menu = null;
    state.buffer.cursor = 7;
    try view.redraw(&output.writer, edit.Prompt.primary, &state, 20, 6);
    try std.testing.expectEqual(@as(usize, 1), view.cursor_row);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "日本") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[4;31m日本") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "literal^[") != null);
}
