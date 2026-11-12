//! One-row terminal presentation. Control bytes are visible text; OSC belongs
//! to ShellIntegration and never enters the editing buffer or width count.
const std = @import("std");
const Prompt = @import("habush-edit").Prompt;

pub fn redraw(writer: *std.Io.Writer, prompt: Prompt, source: []const u8, cursor: usize, columns: usize) std.Io.Writer.Error!void {
    const prompt_width = try writePrompt(null, prompt, columns -| 2);
    const available = columns -| (prompt_width + 1);
    const width = @max(available, 1);
    const before_cursor = displayWidth(source[0..cursor]);
    const desired_start = before_cursor -| (width - 1);
    var start: usize = 0;
    var skipped: usize = 0;
    while (start < cursor and skipped < desired_start) {
        const unit = decode(source[start..]);
        skipped += unit.width;
        start += unit.len;
    }
    try writer.writeAll("\r\x1b[2K");
    _ = try writePrompt(writer, prompt, columns -| 2);
    var index = start;
    var used: usize = 0;
    while (index < source.len) {
        const unit = decode(source[index..]);
        if (used + unit.width > width) break;
        try writeUnit(writer, source[index..][0..unit.len], unit);
        used += unit.width;
        index += unit.len;
    }
    try writer.writeByte('\r');
    const column = prompt_width + before_cursor -| skipped;
    if (column != 0) try writer.print("\x1b[{d}C", .{column});
    try writer.flush();
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

const Unit = struct { len: usize, width: u8, codepoint: ?u21 };

fn decode(source: []const u8) Unit {
    const byte = source[0];
    if (byte < 0x20 or byte == 0x7f) return .{ .len = 1, .width = 2, .codepoint = byte };
    const length = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .len = 1, .width = 4, .codepoint = null };
    if (length > source.len) return .{ .len = 1, .width = 4, .codepoint = null };
    const cp = std.unicode.utf8Decode(source[0..length]) catch return .{ .len = 1, .width = 4, .codepoint = null };
    if ((cp >= 0x80 and cp <= 0x9f) or visibleFormat(cp)) return .{ .len = length, .width = 8, .codepoint = cp };
    return .{ .len = length, .width = codepointWidth(cp), .codepoint = cp };
}

fn writeUnit(writer: *std.Io.Writer, bytes: []const u8, unit: Unit) std.Io.Writer.Error!void {
    const cp = unit.codepoint orelse {
        try writer.print("\\x{X:0>2}", .{bytes[0]});
        return;
    };
    if (cp < 0x20 or cp == 0x7f) {
        try writer.writeAll(&.{ '^', if (cp == 0x7f) '?' else @as(u8, @intCast(cp)) + 0x40 });
    } else if ((cp >= 0x80 and cp <= 0x9f) or visibleFormat(cp)) {
        try writer.print("\\u{{{X:0>4}}}", .{cp});
    } else try writer.writeAll(bytes);
}

fn visibleFormat(cp: u21) bool {
    return cp == 0xad or cp == 0x61c or cp == 0x200b or
        (cp >= 0x200e and cp <= 0x200f) or (cp >= 0x202a and cp <= 0x202e) or
        (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff;
}

/// Initial terminal policy: common combining marks/variation selectors occupy
/// no cells, CJK and wide emoji occupy two. Ambiguous width is one. Grapheme
/// clusters and terminal-specific emoji presentation need a richer provider.
fn codepointWidth(cp: u21) u8 {
    if ((cp >= 0x0300 and cp <= 0x036f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0xe0100 and cp <= 0xe01ef) or cp == 0x200c or cp == 0x200d) return 0;
    if (cp >= 0x1100 and (cp <= 0x115f or cp == 0x2329 or cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff01 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or (cp >= 0x20000 and cp <= 0x3fffd))) return 2;
    return 1;
}

test "display width and visible controls preserve terminal boundaries" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a日本e\xcc\x81"));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeVisible(&output.writer, "a\x1b\n\xff日本\xe2\x80\xae");
    try std.testing.expectEqualStrings("a^[^J\\xFF日本\\u{202E}", output.written());
    output.clearRetainingCapacity();
    try redraw(&output.writer, Prompt.secondary, "0123456789", 10, 8);
    try std.testing.expectEqualStrings("\r\x1b[2K> 6789\r\x1b[6C", output.written());
}

test "styled prompts measure Unicode cells and escape provider controls" {
    const prompt: Prompt = .{ .spans = &.{.{ .text = "日\x1b]7;bad\n", .style = .{ .foreground = .green } }} };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 4), try writePrompt(&output.writer, prompt, 4));
    try std.testing.expectEqualStrings("\x1b[0;32;49m日^[\x1b[0m", output.written());
    try std.testing.expectEqual(@as(usize, 4), try writePrompt(null, prompt, 4));
}
