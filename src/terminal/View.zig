//! Repaints the editor-owned rows, keeping the cursor's logical line visible.
const std = @import("std");
const edit = @import("habush-edit");
const render = @import("render.zig");
const View = @This();

cursor_row: usize = 0,
rows: usize = 1,

pub fn redraw(view: *View, writer: *std.Io.Writer, prompt: edit.Prompt, state: *const edit.Editor, columns: usize, terminal_rows: usize) !void {
    const height = @max(terminal_rows, 3);
    const diagnostics = state.currentDiagnostics();
    const diagnostic_rows = if (height >= 5) @min(@min(diagnostics.len, 3), height / 3) else 0;
    const menu_height = height - diagnostic_rows;
    const menu_limit = @max(@as(usize, 1), @min(@as(usize, 8), menu_height / 2 -| 1));
    const menu_status = if (state.menu) |menu| menu_height > 3 and (menu.result.labels.len > menu_limit or menu.result.incomplete or menu.result.truncated) else false;
    const menu_rows = if (state.menu) |menu| @min(menu.result.labels.len, menu_limit) + @intFromBool(menu_status) else 0;
    const input_rows = @max(@as(usize, 1), height -| (menu_rows + diagnostic_rows + 1 + @intFromBool(state.search != null)));
    const source = state.searchMatch() orelse state.buffer.text();
    const cursor = if (state.searchMatch() != null) source.len else state.buffer.cursor;
    const cursor_line = std.mem.count(u8, source[0..cursor], "\n");
    const first_line = cursor_line -| (input_rows - 1);
    if (view.cursor_row != 0) try writer.print("\x1b[{d}A", .{@min(view.cursor_row, height - 1)});
    try writer.writeAll("\r\x1b[J");
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
    try writer.flush();
}

pub fn finish(view: View, writer: *std.Io.Writer) !void {
    if (view.rows - 1 > view.cursor_row) try writer.print("\x1b[{d}B", .{view.rows - 1 - view.cursor_row});
    try writer.writeAll("\r\n");
    try writer.flush();
}

test "viewport bounds multiline input and menu while retaining the cursor line" {
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    try std.testing.expect(try state.insert("one\n日本\nthree\nfour\nfive"));
    state.menu = .{ .result = .{ .labels = &.{ "a\x1b", "b" }, .incomplete = true } };
    try std.testing.expect(state.setDiagnostics(.{ .revision = state.buffer.revision, .items = &.{.{ .start = 4, .end = 10, .severity = .@"error", .message = "literal\x1b" }} }));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view: View = .{};
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
