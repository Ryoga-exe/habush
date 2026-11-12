//! Display data only. Providers allocate retained data in the caller's arena.
const std = @import("std");
const Prompt = @This();

spans: []const Span,

pub const Color = enum(u8) { default, black, red, green, yellow, blue, magenta, cyan, white };
pub const Style = struct { foreground: Color = .default, background: Color = .default, bold: bool = false };
pub const Span = struct { text: []const u8, style: Style = .{} };
pub const Context = struct {
    cwd: ?[]const u8,
    status: u8,
    duration_ns: ?u64 = null,
    jobs: usize = 0,
    git: ?Git = null,
};
pub const Git = struct { root: []const u8, branch: ?[]const u8 = null, commit: ?[]const u8 = null };
pub const Error = std.mem.Allocator.Error || error{ Canceled, Unavailable };
pub const Provider = struct {
    userdata: ?*anyopaque = null,
    render: *const fn (?*anyopaque, std.mem.Allocator, Context) Error!Prompt,
};
pub const primary: Prompt = .{ .spans = &.{.{ .text = "habush> " }} };
pub const secondary: Prompt = .{ .spans = &.{.{ .text = "> " }} };
pub const max_spans = 16;
pub const max_bytes = 1024;

pub fn valid(prompt: Prompt) bool {
    if (prompt.spans.len > max_spans) return false;
    var bytes: usize = 0;
    for (prompt.spans) |span| {
        if (span.text.len > max_bytes - bytes or std.mem.indexOfScalar(u8, span.text, 0) != null) return false;
        bytes += span.text.len;
    }
    return true;
}

test "prompt data is bounded before display" {
    try std.testing.expect(primary.valid());
    try std.testing.expect(!(Prompt{ .spans = &.{.{ .text = "bad\x00" }} }).valid());
    const oversized: [max_bytes + 1]u8 = @splat('x');
    try std.testing.expect(!(Prompt{ .spans = &.{.{ .text = &oversized }} }).valid());
}
