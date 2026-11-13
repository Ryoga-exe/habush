//! Repaints the editor-owned rows, keeping the cursor's logical line visible.
const std = @import("std");
const edit = @import("habush-edit");
const unicode = edit.unicode;
const render = @import("render.zig");
const View = @This();

frame: std.Io.Writer.Allocating,
previous: std.ArrayList(u8) = .empty,
current_rows: std.ArrayList(Row) = .empty,
previous_rows: std.ArrayList(Row) = .empty,
updates: std.ArrayList(u8) = .empty,
cursor_row: usize = 0,
cursor_column: usize = 0,
rows: usize = 1,
columns: usize = 0,
terminal_rows: usize = 0,

const Row = struct { start: usize, end: usize, source_len: usize, prompt_width: usize, width: usize };
const Position = struct { row: usize, column: usize };

pub fn deinit(view: *View) void {
    view.previous.deinit(view.frame.allocator);
    view.current_rows.deinit(view.frame.allocator);
    view.previous_rows.deinit(view.frame.allocator);
    view.updates.deinit(view.frame.allocator);
    view.frame.deinit();
    view.* = undefined;
}

pub fn reset(view: *View) void {
    view.cursor_row = 0;
    view.cursor_column = 0;
    view.rows = 1;
    view.previous_rows.clearRetainingCapacity();
}

pub fn redraw(view: *View, output: *std.Io.Writer, prompt: edit.Prompt, state: *const edit.Editor, columns: usize, terminal_rows: usize) !void {
    errdefer view.previous_rows.clearRetainingCapacity();
    view.frame.clearRetainingCapacity();
    view.current_rows.clearRetainingCapacity();
    const writer = &view.frame.writer;
    const height = @max(terminal_rows, 3);
    const diagnostics = state.currentDiagnostics();
    var cacheable = columns > 1 and terminal_rows >= 3 and
        state.menu == null and state.search == null and !state.completion_pending and diagnostics.len == 0;
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
        const row_start = writer.end;
        const layout = try render.inputRow(writer, if (line_index == 0) prompt else edit.Prompt.secondary, line, if (line_index == cursor_line) cursor - source_offset else 0, columns, diagnostics, source_offset);
        if (line_index == cursor_line) cursor_column = layout.cursor_column;
        cacheable = cacheable and layout.literal;
        try view.current_rows.append(view.frame.allocator, .{
            .start = row_start,
            .end = writer.end,
            .source_len = layout.visible_source.len,
            .prompt_width = layout.prompt_width,
            .width = layout.width,
        });
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
    const cursor_row = cursor_line - first_line;
    if (row - 1 > cursor_row) try writer.print("\x1b[{d}A", .{row - 1 - cursor_row});
    try writer.writeByte('\r');
    if (cursor_column != 0) try writer.print("\x1b[{d}C", .{cursor_column});
    if (cacheable and view.previous_rows.items.len != 0 and columns == view.columns and terminal_rows == view.terminal_rows) {
        try view.redrawRows(output, .{ .row = cursor_row, .column = cursor_column });
    } else {
        try output.writeAll(view.frame.written());
    }
    try output.flush();
    view.previous_rows.clearRetainingCapacity();
    if (cacheable) {
        view.previous.clearRetainingCapacity();
        try view.previous.appendSlice(view.frame.allocator, view.frame.written());
        try view.previous_rows.appendSlice(view.frame.allocator, view.current_rows.items);
    }
    view.rows = row;
    view.cursor_row = cursor_row;
    view.cursor_column = cursor_column;
    view.columns = columns;
    view.terminal_rows = terminal_rows;
}

fn redrawRows(view: *View, output: *std.Io.Writer, target: Position) !void {
    var updates: std.Io.Writer.Allocating = .fromArrayList(view.frame.allocator, &view.updates);
    defer view.updates = updates.toArrayList();
    updates.clearRetainingCapacity();
    const writer = &updates.writer;
    var position: Position = .{ .row = view.cursor_row, .column = view.cursor_column };
    var known_rows = view.previous_rows.items.len;
    for (view.current_rows.items, 0..) |row, index| {
        const line = view.frame.written()[row.start..row.end];
        if (index >= view.previous_rows.items.len) {
            try moveCursor(writer, &position, .{ .row = known_rows - 1, .column = position.column });
            // A newline allocates a row even when the editor reaches the screen bottom.
            try writer.writeAll("\r\n");
            position = .{ .row = index, .column = 0 };
            known_rows += 1;
            try writer.writeAll(line);
        } else {
            const previous_row = view.previous_rows.items[index];
            const previous_line = view.previous.items[previous_row.start..previous_row.end];
            if (std.mem.eql(u8, line, previous_line)) continue;
            const prompt_len = line.len - row.source_len;
            const previous_prompt_len = previous_line.len - previous_row.source_len;
            if (std.mem.eql(u8, line[0..prompt_len], previous_line[0..previous_prompt_len])) {
                const source = line[prompt_len..];
                const previous_source = previous_line[previous_prompt_len..];
                const prefix = unicode.sharedGraphemePrefix(previous_source, source);
                try moveCursor(writer, &position, .{ .row = index, .column = row.prompt_width + render.displayWidth(source[0..prefix]) });
                if (prefix < previous_source.len) try writer.writeAll("\x1b[K");
                try writer.writeAll(source[prefix..]);
            } else {
                try moveCursor(writer, &position, .{ .row = index, .column = 0 });
                try writer.writeAll("\x1b[K");
                try writer.writeAll(line);
            }
        }
        position.column = row.width;
    }
    if (view.current_rows.items.len < view.previous_rows.items.len) {
        try moveCursor(writer, &position, .{ .row = view.current_rows.items.len, .column = 0 });
        try writer.writeAll("\x1b[J");
    }
    try moveCursor(writer, &position, target);
    try output.writeAll(updates.written());
}

fn moveCursor(writer: *std.Io.Writer, position: *Position, target: Position) std.Io.Writer.Error!void {
    if (position.row > target.row) try writer.print("\x1b[{d}A", .{position.row - target.row});
    if (position.row < target.row) try writer.print("\x1b[{d}B", .{target.row - position.row});
    if (position.column > target.column) try writer.print("\x1b[{d}D", .{position.column - target.column});
    if (position.column < target.column) try writer.print("\x1b[{d}C", .{target.column - position.column});
    position.* = target;
}

pub fn finish(view: View, writer: *std.Io.Writer) !void {
    if (view.rows - 1 > view.cursor_row) try writer.print("\x1b[{d}B", .{view.rows - 1 - view.cursor_row});
    try writer.writeAll("\r\n");
    try writer.flush();
}

test "single-line edits and cursor movement reach an unbuffered sink together" {
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
    const cases = [_]struct { source: []const u8, cursor: ?usize = null, delta: ?[]const u8 }{
        .{ .source = "ab", .delta = null },
        .{ .source = "abcd", .delta = "cd" },
        .{ .source = "abc", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "a", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "", .delta = "" },
        .{ .source = "\x1b", .delta = null },
        .{ .source = "", .delta = null },
        .{ .source = "日", .delta = "日" },
        .{ .source = "日x", .delta = "x" },
        .{ .source = "日", .delta = "\x1b[1D\x1b[K" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "e", .delta = "e" },
        .{ .source = "e\xcc\x81", .delta = "\x1b[1D\x1b[Ke\xcc\x81" },
        .{ .source = "e", .delta = "\x1b[1D\x1b[Ke" },
        .{ .source = "ex", .delta = "x" },
        .{ .source = "by", .delta = "\x1b[2D\x1b[Kby" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "abcd", .delta = "abcd" },
        .{ .source = "abcd", .cursor = 2, .delta = "\x1b[2D" },
        .{ .source = "abcd", .cursor = 2, .delta = "" },
        .{ .source = "abcd", .cursor = 0, .delta = "\x1b[2D" },
        .{ .source = "abcd", .cursor = 1, .delta = "\x1b[1C" },
        .{ .source = "abcd", .cursor = 3, .delta = "\x1b[2C" },
        .{ .source = "abcd", .cursor = 2, .delta = "\x1b[1D" },
        .{ .source = "abXcd", .cursor = 3, .delta = "\x1b[KXcd\x1b[2D" },
        .{ .source = "abcd", .cursor = 2, .delta = "\x1b[1D\x1b[Kcd\x1b[2D" },
        .{ .source = "abd", .cursor = 2, .delta = "\x1b[Kd\x1b[1D" },
        .{ .source = "abd", .delta = "\x1b[1C" },
        .{ .source = "abd", .cursor = 0, .delta = "\x1b[3D" },
        .{ .source = "Zabd", .cursor = 1, .delta = "\x1b[KZabd\x1b[3D" },
        .{ .source = "abd", .cursor = 0, .delta = "\x1b[1D\x1b[Kabd\x1b[3D" },
        .{ .source = "abd", .delta = "\x1b[3C" },
        .{ .source = "", .delta = "\x1b[3D\x1b[K" },
        .{ .source = "か", .delta = "か" },
        .{ .source = "か\u{3099}", .delta = "\x1b[2D\x1b[Kか\u{3099}" },
        .{ .source = "か", .delta = "\x1b[2D\x1b[Kか" },
        .{ .source = "か漢", .delta = "漢" },
        .{ .source = "か", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "👩", .delta = "👩" },
        .{ .source = "👩🏽", .delta = "\x1b[2D\x1b[K👩🏽" },
        .{ .source = "👩🏽‍", .delta = "\x1b[2D\x1b[K👩🏽‍" },
        .{ .source = "👩🏽‍🚀", .delta = "\x1b[2D\x1b[K👩🏽‍🚀" },
        .{ .source = "👩🏽", .delta = "\x1b[2D\x1b[K👩🏽" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "🇯", .delta = "🇯" },
        .{ .source = "🇯🇵", .delta = "\x1b[2D\x1b[K🇯🇵" },
        .{ .source = "🇯", .delta = "\x1b[2D\x1b[K🇯" },
        .{ .source = "", .delta = "\x1b[2D\x1b[K" },
        .{ .source = "☁", .delta = "☁" },
        .{ .source = "☁\u{fe0f}", .delta = "\x1b[1D\x1b[K☁\u{fe0f}" },
        .{ .source = "☁", .delta = "\x1b[2D\x1b[K☁" },
        .{ .source = "☁\u{fe0e}", .delta = "\x1b[1D\x1b[K☁\u{fe0e}" },
        .{ .source = "かe\u{301}本", .delta = "\x1b[1D\x1b[Kかe\u{301}本" },
        .{ .source = "かe\u{301}本", .cursor = 6, .delta = "\x1b[2D" },
        .{ .source = "かe\u{301}本", .cursor = 4, .delta = "" },
        .{ .source = "かe\u{301}本", .cursor = 3, .delta = "\x1b[1D" },
        .{ .source = "かZe\u{301}本", .cursor = 4, .delta = "\x1b[KZe\u{301}本\x1b[3D" },
        .{ .source = "かZ\u{301}e\u{301}本", .cursor = 6, .delta = "\x1b[1D\x1b[KZ\u{301}e\u{301}本\x1b[3D" },
        .{ .source = "かZe\u{301}本", .cursor = 4, .delta = "\x1b[1D\x1b[KZe\u{301}本\x1b[3D" },
        .{ .source = "かe\u{301}本", .cursor = 3, .delta = "\x1b[1D\x1b[Ke\u{301}本\x1b[3D" },
        .{ .source = "かe\u{301}", .delta = "\x1b[1C\x1b[K" },
        .{ .source = "かe\u{301}", .cursor = 0, .delta = "\x1b[3D" },
        .{ .source = "かe\u{301}", .delta = "\x1b[3C" },
        .{ .source = "👩🏽‍🚀x", .delta = "\x1b[3D\x1b[K👩🏽‍🚀x" },
        .{ .source = "👩🏽‍🚀x", .cursor = 15, .delta = "\x1b[1D" },
        .{ .source = "👩🏽‍🚀x", .cursor = 11, .delta = "" },
        .{ .source = "👩🏽‍🚀x", .cursor = 8, .delta = "" },
        .{ .source = "👩🏽x", .cursor = 8, .delta = "\x1b[2D\x1b[K👩🏽x\x1b[1D" },
        .{ .source = "\u{301}", .delta = null },
        .{ .source = "\xff", .delta = null },
    };
    for (cases) |case| {
        output.clearRetainingCapacity();
        sink.writes = 0;
        try state.buffer.replace(0, state.buffer.text().len, case.source);
        state.buffer.cursor = case.cursor orelse case.source.len;
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

test "row cache is invalidated by overlays, resizing and screen clearing" {
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view: View = .{ .frame = .init(std.testing.allocator) };
    defer view.deinit();
    const Change = enum { menu, diagnostics, pending, columns, height, clear };
    for (std.enums.values(Change)) |change| {
        state.menu = null;
        state.diagnostics = null;
        state.completion_pending = false;
        try state.buffer.replace(0, state.buffer.text().len, "abc");
        try view.redraw(&output.writer, edit.Prompt.primary, &state, 20, 8);
        output.clearRetainingCapacity();
        var columns: usize = 20;
        var height: usize = 8;
        const prompt = edit.Prompt.primary;
        switch (change) {
            .menu => state.menu = .{ .result = .{ .labels = &.{"candidate"} } },
            .diagnostics => try std.testing.expect(state.setDiagnostics(.{ .revision = state.buffer.revision, .items = &.{.{ .start = 0, .end = 1, .severity = .warning, .message = "warning" }} })),
            .pending => state.completion_pending = true,
            .columns => columns += 1,
            .height => height += 1,
            .clear => view.reset(),
        }
        try view.redraw(&output.writer, prompt, &state, columns, height);
        try std.testing.expect(std.mem.startsWith(u8, output.written(), "\r\x1b[J"));
    }
}

test "visible rows update independently across line edits and viewport scrolling" {
    var state: edit.Editor = .{ .buffer = .{ .gpa = std.testing.allocator } };
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view: View = .{ .frame = .init(std.testing.allocator) };
    defer view.deinit();
    const prompt: edit.Prompt = .{ .spans = &.{.{ .text = "P> " }} };
    const cases = [_]struct { source: []const u8, cursor: ?usize = null, columns: usize = 24, delta: ?[]const u8 }{
        .{ .source = "a\n日b\nc", .delta = null },
        .{ .source = "a\n日b\nc", .cursor = 5, .delta = "\x1b[1A\x1b[1C" },
        .{ .source = "a\n日Xb\nc", .cursor = 6, .delta = "\x1b[KXb\x1b[1D" },
        .{ .source = "a\n日b\nc", .cursor = 5, .delta = "\x1b[1D\x1b[Kb\x1b[1D" },
        .{ .source = "a\n日\nb\nc", .cursor = 6, .delta = "\x1b[K\x1b[1B\x1b[2D\x1b[Kb\r\n> c\x1b[1A\x1b[1D" },
        .{ .source = "a\n日b\nc", .cursor = 5, .delta = "\x1b[1A\x1b[2Cb\x1b[1B\x1b[3D\x1b[Kc\x1b[1B\x1b[3D\x1b[J\x1b[2A\x1b[4C" },
        .{ .source = "a\n日b\nc\nd", .delta = "\x1b[1B\r\n> d" },
        .{ .source = "a\n日b\nc\nd\ne", .delta = "\x1b[3A\x1b[3D\x1b[K> 日b\x1b[1B\x1b[3D\x1b[Kc\x1b[1B\x1b[1D\x1b[Kd\x1b[1B\x1b[1D\x1b[Ke" },
        .{ .source = "a\n日b\nc\nd\ne", .cursor = 0, .delta = "\x1b[3A\x1b[3D\x1b[KP> a\x1b[1B\x1b[2D\x1b[K日b\x1b[1B\x1b[3D\x1b[Kc\x1b[1B\x1b[1D\x1b[Kd\x1b[3A" },
        .{ .source = "", .delta = "\x1b[K\x1b[1B\x1b[3D\x1b[J\x1b[1A\x1b[3C" },
        .{ .source = "first\n", .delta = "first\r\n> " },
        .{ .source = "first", .delta = "\x1b[2D\x1b[J\x1b[1A\x1b[8C" },
        .{ .source = "0123456789", .columns = 10, .delta = null },
        .{ .source = "0123456789a", .columns = 10, .delta = "\x1b[5D\x1b[K6789a" },
        .{ .source = "0123456789a", .cursor = 10, .columns = 10, .delta = "\x1b[5D\x1b[K56789a\x1b[1D" },
        .{ .source = "0123456789a", .cursor = 9, .columns = 10, .delta = "\x1b[5D\x1b[K456789\x1b[1D" },
        .{ .source = "0123456789a", .cursor = 0, .columns = 10, .delta = "\x1b[5D\x1b[K012345\x1b[6D" },
        .{ .source = "0123456789a", .cursor = 1, .columns = 10, .delta = "\x1b[1C" },
        .{ .source = "0123456789aZZ", .cursor = 1, .columns = 10, .delta = "" },
        .{ .source = "0123456789aZZ", .columns = 10, .delta = "\x1b[1D\x1b[K89aZZ" },
        .{ .source = "012345か\u{3099}👩🏽‍🚀X", .columns = 10, .delta = "\x1b[5D\x1b[Kか\u{3099}👩🏽‍🚀X" },
        .{ .source = "012345か\u{3099}👩🏽‍🚀X", .cursor = 27, .columns = 10, .delta = "\x1b[5D\x1b[K5か\u{3099}👩🏽‍🚀X\x1b[1D" },
        .{ .source = "012345か\u{3099}👩🏽‍🚀X", .cursor = 12, .columns = 10, .delta = "\x1b[5D\x1b[K345か\u{3099}" },
        .{ .source = "012345か\u{3099}👩🏽‍🚀X", .cursor = 9, .columns = 10, .delta = "" },
        .{ .source = "012345か👩🏽‍🚀X", .cursor = 9, .columns = 10, .delta = "\x1b[2D\x1b[Kか" },
        .{ .source = "a⏰\u{fe0e}", .columns = 7, .delta = null },
        .{ .source = "a⏰\u{fe0e}", .cursor = 4, .columns = 7, .delta = "\x1b[2D\x1b[K⏰\u{fe0e}\x1b[1C" },
        .{ .source = "👩🏽‍🚀", .cursor = 4, .columns = 5, .delta = null },
        .{ .source = "👩🏽‍🚀", .columns = 5, .delta = "\x1b[1D" },
    };
    for (cases) |case| {
        output.clearRetainingCapacity();
        try state.buffer.replace(0, state.buffer.text().len, case.source);
        state.buffer.cursor = case.cursor orelse case.source.len;
        try view.redraw(&output.writer, prompt, &state, case.columns, 5);
        if (case.delta) |delta| {
            try std.testing.expectEqualStrings(delta, output.written());
        } else {
            try std.testing.expect(std.mem.startsWith(u8, output.written(), "\r\x1b[J"));
        }
        try std.testing.expect(view.rows <= 4 and view.cursor_row < view.rows);
        try std.testing.expectEqual(view.rows, view.previous_rows.items.len);
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
