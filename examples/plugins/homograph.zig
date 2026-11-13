//! Advisory URL diagnostics; no host imports, I/O, or command execution.
const std = @import("std");
const lookalikes = @import("confusables.zig").ascii_lookalikes;

var request_buffer: [64 * 1024]u8 = undefined;
var reply_buffer: [8192]u8 = undefined;
const message = "URL homograph: hostname contains Greek/Cyrillic ASCII lookalikes; verify the destination";
const max_items = 32;

export fn habush_version() u32 {
    return 0;
}

export fn habush_alloc(length: u32) u32 {
    if (length > request_buffer.len) @trap();
    return @intCast(@intFromPtr(&request_buffer));
}

fn take(reader: *std.Io.Reader) []const u8 {
    return reader.take(reader.takeInt(u32, .little) catch @trap()) catch @trap();
}

fn field(writer: *std.Io.Writer, value: []const u8) void {
    writer.writeInt(u32, @intCast(value.len), .little) catch @trap();
    writer.writeAll(value) catch @trap();
}

export fn diagnose(pointer: u32, length: u32) u64 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    if ((reader.takeInt(u32, .little) catch @trap()) != 2) @trap();
    const revision = take(&reader);
    const source = take(&reader);
    if (reader.bufferedLen() != 0) @trap();
    const result = diagnostics(source, revision, &reply_buffer);
    return @as(u64, result.len) << 32 | @as(u64, @intFromPtr(result.ptr));
}

fn diagnostics(source: []const u8, revision: []const u8, output: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(output);
    writer.writeInt(u32, 1, .little) catch @trap();
    field(&writer, revision);
    var count: u32 = 0;
    var index: usize = 0;
    while (index < source.len and count < max_items) {
        const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(source[index..], "https://")) 8 else if (std.ascii.startsWithIgnoreCase(source[index..], "http://")) 7 else {
            index += 1;
            continue;
        };
        const start = index;
        index += scheme_len;
        while (index < source.len and source[index] > ' ' and std.mem.indexOfScalar(u8, "\"'`\\|;&<>()$", source[index]) == null) index += 1;
        const uri = std.Uri.parse(source[start..index]) catch continue;
        const host = uri.host orelse continue;
        const raw = switch (host) {
            .raw, .percent_encoded => |value| value,
        };
        var decoded: [1024]u8 = undefined;
        if (!suspiciousHost(host.toRaw(&decoded) catch continue)) continue;
        const host_start = @intFromPtr(raw.ptr) - @intFromPtr(source.ptr);
        var number: [20]u8 = undefined;
        field(&writer, std.fmt.bufPrint(&number, "{d}", .{host_start}) catch @trap());
        field(&writer, std.fmt.bufPrint(&number, "{d}", .{host_start + raw.len}) catch @trap());
        field(&writer, "warning");
        field(&writer, message);
        count += 1;
    }
    std.mem.writeInt(u32, output[0..4], 1 + count * 4, .little);
    return output[0..writer.end];
}

fn suspiciousHost(host: []const u8) bool {
    var iterator = (std.unicode.Utf8View.init(host) catch return false).iterator();
    var start: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        // IDNA recognizes these three Unicode dots as label separators too.
        if (codepoint == '.' or codepoint == 0x3002 or codepoint == 0xff0e or codepoint == 0xff61) {
            const len = std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            if (suspiciousLabel(host[start .. iterator.i - len])) return true;
            start = iterator.i;
        }
    }
    return suspiciousLabel(host[start..]);
}

fn suspiciousLabel(label: []const u8) bool {
    var buffer: [63]u21 = undefined;
    const points = if (std.ascii.startsWithIgnoreCase(label, "xn--"))
        decodePunycode(label[4..], &buffer) catch return false
    else points: {
        var iterator = (std.unicode.Utf8View.init(label) catch return false).iterator();
        var len: usize = 0;
        while (iterator.nextCodepoint()) |codepoint| {
            if (len == buffer.len) return false;
            buffer[len] = codepoint;
            len += 1;
        }
        break :points buffer[0..len];
    };
    var latin = false;
    var confusable = false;
    var all_ascii_lookalikes = true;
    for (points) |codepoint| {
        if (codepoint < 128) {
            const byte: u8 = @intCast(codepoint);
            latin = latin or std.ascii.isAlphabetic(byte);
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') all_ascii_lookalikes = false;
        } else if (std.mem.indexOfScalar(u21, &lookalikes, codepoint) != null) {
            confusable = true;
        } else all_ascii_lookalikes = false;
    }
    // shortcut: Greek/Cyrillic-to-ASCII heuristics, use full UTS #39 skeletons for broader script coverage.
    return confusable and (latin or all_ascii_lookalikes);
}

/// RFC 3492 section 6.2; bounded DNS labels and checked arithmetic on untrusted input.
fn decodePunycode(input: []const u8, output: []u21) error{ InvalidLabel, Overflow }![]const u21 {
    if (input.len == 0 or input.len > 59) return error.InvalidLabel;
    var len: usize = 0;
    var position: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, input, '-')) |delimiter| {
        for (input[0..delimiter]) |byte| {
            if (len == output.len or (!std.ascii.isAlphanumeric(byte) and byte != '-')) return error.InvalidLabel;
            output[len] = byte;
            len += 1;
        }
        position = delimiter + 1;
    }
    var n: u32 = 128;
    var i: u32 = 0;
    var bias: u32 = 72;
    while (position < input.len) {
        const old_i = i;
        var weight: u32 = 1;
        var k: u32 = 36;
        while (true) : (k += 36) {
            if (position == input.len) return error.InvalidLabel;
            const digit: u32 = switch (input[position]) {
                'a'...'z' => input[position] - 'a',
                'A'...'Z' => input[position] - 'A',
                '0'...'9' => input[position] - '0' + 26,
                else => return error.InvalidLabel,
            };
            position += 1;
            i = try std.math.add(u32, i, try std.math.mul(u32, digit, weight));
            const threshold: u32 = if (k <= bias) 1 else @min(26, k - bias);
            if (digit < threshold) break;
            weight = try std.math.mul(u32, weight, 36 - threshold);
        }
        const count: u32 = @intCast(len + 1);
        var delta = (i - old_i) / @as(u32, if (old_i == 0) 700 else 2);
        delta = try std.math.add(u32, delta, delta / count);
        bias = 0;
        while (delta > 455) : (bias += 36) delta /= 35;
        bias += 36 * delta / (delta + 38);
        n = try std.math.add(u32, n, i / count);
        if (n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) or len == output.len) return error.InvalidLabel;
        i %= count;
        std.mem.copyBackwards(u21, output[i + 1 .. len + 1], output[i..len]);
        output[i] = @intCast(n);
        len += 1;
        i += 1;
    }
    return output[0..len];
}

test "URL warnings preserve raw byte ranges and distinguish ordinary international domains" {
    var output: [8192]u8 = undefined;
    for ([_]struct { source: []const u8, host: ?[]const u8 = null }{
        .{ .source = "日本 curl 'https://exаmple.test/path'", .host = "exаmple.test" },
        .{ .source = "curl HTTPS://user:pass@раураl.test:443/", .host = "раураl.test" },
        .{ .source = "echo https://αρρle.test", .host = "αρρle.test" },
        .{ .source = "curl https://аррӏе.test", .host = "аррӏе.test" },
        .{ .source = "curl https://xn--80ak6aa92e.test", .host = "xn--80ak6aa92e.test" },
        .{ .source = "curl https://XN--EXMPLE-4NF.test", .host = "XN--EXMPLE-4NF.test" },
        .{ .source = "curl https://ex%D0%B0mple.test/", .host = "ex%D0%B0mple.test" },
        .{ .source = "curl https://аррӏе。test", .host = "аррӏе。test" },
        .{ .source = "curl https://example.test/раураl?q=https://раураl.test" },
        .{ .source = "curl https://раураl@example.test/" },
        .{ .source = "curl https://例え.テスト/" },
        .{ .source = "curl https://xn--r8jz45g.xn--zckzah" },
        .{ .source = "curl https://пример.test https://παράδειγμα.test https://bücher.test" },
        .{ .source = "curl https://[::1]:443/" },
        .{ .source = "curl https://\xff.test/ https://xn--999999999999999999999.test/ https://" },
        .{ .source = "curl \"$url\"" },
    }) |case| {
        var reader: std.Io.Reader = .fixed(diagnostics(case.source, "7", &output));
        try std.testing.expectEqual(@as(u32, if (case.host != null) 5 else 1), try reader.takeInt(u32, .little));
        try std.testing.expectEqualStrings("7", take(&reader));
        if (case.host) |host| {
            const start = try std.fmt.parseInt(usize, take(&reader), 10);
            const end = try std.fmt.parseInt(usize, take(&reader), 10);
            try std.testing.expectEqualStrings(host, case.source[start..end]);
            try std.testing.expectEqualStrings("warning", take(&reader));
            try std.testing.expectEqualStrings(message, take(&reader));
        }
        try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
    }
}

test "Punycode decoding handles reference strings and refuses malformed or overflowing input" {
    var output: [63]u21 = undefined;
    try std.testing.expectEqualSlices(u21, &.{ 'b', 'ü', 'c', 'h', 'e', 'r' }, try decodePunycode("bcher-kva", &output));
    try std.testing.expectEqualSlices(u21, &.{ 'テ', 'ス', 'ト' }, try decodePunycode("zckzah", &output));
    try std.testing.expectEqualSlices(u21, &.{ 'а', 'р', 'р', 'ӏ', 'е' }, try decodePunycode("80ak6aa92e", &output));
    for ([_][]const u8{ "", "a!", "z", "9999999999999999999999999999" }) |invalid| {
        if (decodePunycode(invalid, &output)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "multiple URL warnings respect the diagnostic count and message budgets" {
    var source: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);
    for (0..40) |_| try writer.writeAll("https://exаmple.test ");
    var output: [8192]u8 = undefined;
    var reader: std.Io.Reader = .fixed(diagnostics(source[0..writer.end], "8", &output));
    try std.testing.expectEqual(@as(u32, 1 + max_items * 4), try reader.takeInt(u32, .little));
    try std.testing.expectEqualStrings("8", take(&reader));
    var bytes: usize = 0;
    for (0..max_items) |_| {
        _ = take(&reader);
        _ = take(&reader);
        try std.testing.expectEqualStrings("warning", take(&reader));
        bytes += take(&reader).len;
    }
    try std.testing.expect(bytes <= 4096);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}
