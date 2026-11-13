//! Terminal presentation helpers. Control bytes are visible text; OSC belongs
//! to ShellIntegration and never enters the editing buffer or width count.
//! Widths follow uucode's grapheme policy; ambiguous characters stay narrow.
const std = @import("std");
const Prompt = @import("habush-edit").Prompt;
const Diagnostic = @import("habush-edit").Diagnostic;
const unicode = @import("habush-edit").unicode;
const uucode = @import("uucode");

pub const InputRow = struct {
    visible_source: []const u8,
    prompt_width: usize,
    width: usize,
    cursor_column: usize,
    literal: bool,
};

pub fn inputRow(writer: *std.Io.Writer, prompt: Prompt, source: []const u8, cursor: usize, columns: usize, diagnostics: []const Diagnostic, source_offset: usize) std.Io.Writer.Error!InputRow {
    const prompt_width = try writePrompt(null, prompt, columns -| 2);
    const available = columns -| (prompt_width + 1);
    const width = @max(available, 1);
    const before_cursor = displayWidth(source[0..cursor]);
    const desired_start = before_cursor -| (width - 1);
    var start: usize = 0;
    var skipped: usize = 0;
    while (start < cursor and skipped < desired_start) {
        const unit = decode(source[start..]);
        if (start + unit.len > cursor) break;
        skipped += unit.width;
        start += unit.len;
    }
    _ = try writePrompt(writer, prompt, columns -| 2);
    var index = start;
    var used: usize = 0;
    var literal = true;
    var active: ?Diagnostic.Severity = null;
    while (index < source.len) {
        const unit = decode(source[index..]);
        if (used + unit.width > width) break;
        literal = literal and unit.kind == .literal and unit.width != 0;
        var severity: ?Diagnostic.Severity = null;
        for (diagnostics) |diagnostic| {
            if (diagnostic.start < source_offset + index + unit.len and diagnostic.end > source_offset + index)
                if (severity == null or @backingInt(diagnostic.severity) > @backingInt(severity.?)) {
                    severity = diagnostic.severity;
                };
        }
        if (severity != active) {
            if (active != null) try writer.writeAll("\x1b[0m");
            if (severity) |value| try writer.print("\x1b[4;{d}m", .{@as(u8, switch (value) {
                .note => 36,
                .warning => 33,
                .@"error" => 31,
            })});
            active = severity;
        }
        try writeUnit(writer, source[index..][0..unit.len], unit);
        used += unit.width;
        index += unit.len;
    }
    if (active != null) try writer.writeAll("\x1b[0m");
    return .{
        .visible_source = source[start..index],
        .prompt_width = prompt_width,
        .width = prompt_width + used,
        .cursor_column = @min(prompt_width + before_cursor -| skipped, columns -| 1),
        .literal = literal,
    };
}

/// Width and output share the same clipping and escaping rules. ANSI is emitted
/// from validated style values only; provider text is always literal data.
pub fn writePrompt(writer: ?*std.Io.Writer, prompt: Prompt, max_width: usize) std.Io.Writer.Error!usize {
    var width: usize = 0;
    for (prompt.spans) |span| {
        const styled = !std.meta.eql(span.style, Prompt.Style{});
        if (writer) |output| {
            if (styled) try output.print("\x1b[0;{d};{d}{s}m", .{
                if (span.style.foreground == .default) @as(u8, 39) else 29 + @backingInt(span.style.foreground),
                if (span.style.background == .default) @as(u8, 49) else 39 + @backingInt(span.style.background),
                if (span.style.bold) ";1" else "",
            });
        }
        var index: usize = 0;
        while (index < span.text.len) {
            const unit = decode(span.text[index..]);
            if (unit.width > max_width - width) break;
            if (writer) |output| try writeUnit(output, span.text[index..][0..unit.len], unit);
            width += unit.width;
            index += unit.len;
        }
        if (writer) |output| if (styled) {
            try output.writeAll("\x1b[0m");
        };
        if (index != span.text.len) break;
    }
    return width;
}

pub fn writeVisible(writer: *std.Io.Writer, source: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < source.len) {
        const unit = decode(source[index..]);
        try writeUnit(writer, source[index..][0..unit.len], unit);
        index += unit.len;
    }
}

pub fn displayWidth(source: []const u8) usize {
    var index: usize = 0;
    var width: usize = 0;
    while (index < source.len) {
        const unit = decode(source[index..]);
        width += unit.width;
        index += unit.len;
    }
    return width;
}

const Unit = struct {
    len: usize,
    width: usize,
    kind: enum { literal, control, invalid, escaped },
    codepoint: u21 = 0,
};

fn decode(source: []const u8) Unit {
    const scalar = unicode.decode(source);
    const cp = scalar.codepoint orelse return .{ .len = 1, .width = 4, .kind = .invalid };
    if (cp < 0x20 or cp == 0x7f) return .{ .len = scalar.len, .width = 2, .kind = .control, .codepoint = cp };
    const orphan_mark = switch (uucode.get(.general_category, cp)) {
        .mark_nonspacing, .mark_spacing_combining, .mark_enclosing => true,
        else => false,
    };
    // Orphan marks/joiners must not combine with the prompt or a preceding span.
    if ((cp >= 0x80 and cp <= 0x9f) or visibleFormat(cp) or orphan_mark or uucode.get(.wcwidth_standalone, cp) == 0)
        return .{ .len = scalar.len, .width = if (cp > 0xfffff) 10 else if (cp > 0xffff) 9 else 8, .kind = .escaped, .codepoint = cp };
    const length = unicode.nextGraphemeBoundary(source, 0);
    return .{ .len = length, .width = uucode.grapheme.utf8Wcwidth(source[0..length]), .kind = .literal };
}

fn writeUnit(writer: *std.Io.Writer, bytes: []const u8, unit: Unit) std.Io.Writer.Error!void {
    switch (unit.kind) {
        .literal => try writer.writeAll(bytes),
        .invalid => try writer.print("\\x{X:0>2}", .{bytes[0]}),
        .control => try writer.writeAll(&.{ '^', if (unit.codepoint == 0x7f) '?' else @as(u8, @intCast(unit.codepoint)) + 0x40 }),
        .escaped => try writer.print("\\u{{{X:0>4}}}", .{unit.codepoint}),
    }
}

fn visibleFormat(cp: u21) bool {
    return cp == 0xad or cp == 0x61c or cp == 0x200b or
        (cp >= 0x200e and cp <= 0x200f) or (cp >= 0x202a and cp <= 0x202e) or
        (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff;
}

test "display width and visible controls preserve terminal boundaries" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a日本e\xcc\x81"));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeVisible(&output.writer, "a\x1b\n\xff日本\xe2\x80\xae");
    try std.testing.expectEqualStrings("a^[^J\\xFF日本\\u{202E}", output.written());
    output.clearRetainingCapacity();
    const row = try inputRow(&output.writer, Prompt.secondary, "0123456789", 10, 8, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 6), row.cursor_column);
    try std.testing.expectEqualStrings("6789", row.visible_source);
    try std.testing.expectEqualStrings("> 6789", output.written());
}

test "styled prompts measure Unicode cells and escape provider controls" {
    const prompt: Prompt = .{ .spans = &.{.{ .text = "日\x1b]7;bad\n", .style = .{ .foreground = .green } }} };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 4), try writePrompt(&output.writer, prompt, 4));
    try std.testing.expectEqualStrings("\x1b[0;32;49m日^[\x1b[0m", output.written());
    try std.testing.expectEqual(@as(usize, 4), try writePrompt(null, prompt, 4));
}

test "width and clipping share grapheme boundaries while orphan marks stay visible" {
    const cases = [_]struct { text: []const u8, width: usize }{
        .{ .text = "日本", .width = 4 },
        .{ .text = "か\u{3099}", .width = 2 },
        .{ .text = "e\u{301}", .width = 1 },
        .{ .text = "👩🏽‍🚀", .width = 2 },
        .{ .text = "🇯🇵", .width = 2 },
        .{ .text = "☁\u{fe0f}", .width = 2 },
        .{ .text = "☁\u{fe0e}", .width = 1 },
        .{ .text = "\u{301}", .width = 8 },
        .{ .text = "\u{e0100}", .width = 9 },
    };
    for (cases) |case| try std.testing.expectEqual(case.width, displayWidth(case.text));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 3), try writePrompt(&output.writer, .{ .spans = &.{.{ .text = "x👩🏽‍🚀y" }} }, 3));
    try std.testing.expectEqualStrings("x👩🏽‍🚀", output.written());
    output.clearRetainingCapacity();
    const source = "aか\u{3099}b";
    const row = try inputRow(&output.writer, Prompt.secondary, source, source.len, 6, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 3), row.cursor_column);
    try std.testing.expectEqualStrings("b", row.visible_source);
    try std.testing.expectEqualStrings("> b", output.written());
    output.clearRetainingCapacity();
    try writeVisible(&output.writer, "\u{301}\u{e0100}\u{200d}");
    try std.testing.expectEqualStrings("\\u{0301}\\u{E0100}\\u{200D}", output.written());
}
