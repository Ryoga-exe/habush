//! Revision-bound diagnostics. Text is presentation data, not terminal output.
const std = @import("std");
const Diagnostic = @This();

start: usize,
end: usize,
severity: Severity = .warning,
message: []const u8,

pub const Severity = enum { note, warning, @"error" };
pub const Request = struct {
    source: []const u8,
    revision: u64,
    /// Trusted host context; adapters do not serialize this into guest requests.
    cwd: ?[]const u8 = null,
};
pub const Error = std.mem.Allocator.Error || error{ Canceled, Unavailable };
/// Result items and messages live in the caller's arena until the next query.
pub const Provider = struct {
    userdata: ?*anyopaque = null,
    query: *const fn (?*anyopaque, std.mem.Allocator, Request) Error!Result,
};
pub const max_items = 32;
pub const max_bytes = 4096;
pub const Result = struct {
    revision: u64,
    items: []const Diagnostic = &.{},

    pub fn valid(result: Result, request: Request) bool {
        if (result.revision != request.revision or result.items.len > max_items) return false;
        var bytes: usize = 0;
        for (result.items) |item| {
            if (item.start > item.end or item.end > request.source.len or
                item.message.len > max_bytes - bytes or std.mem.indexOfScalar(u8, item.message, 0) != null) return false;
            bytes += item.message.len;
        }
        return true;
    }
};

test "diagnostics reject stale input and invalid ranges before presentation" {
    const request: Request = .{ .source = "日本", .revision = 3 };
    var result: Result = .{ .revision = 3, .items = &.{.{ .start = 0, .end = 3, .message = "literal\x1b" }} };
    try std.testing.expect(result.valid(request));
    result.revision = 2;
    try std.testing.expect(!result.valid(request));
    result.revision = 3;
    for ([_]Diagnostic{
        .{ .start = 4, .end = 3, .message = "x" },
        .{ .start = 0, .end = 7, .message = "x" },
        .{ .start = 0, .end = 0, .message = "\x00" },
    }) |item| {
        result.items = &.{item};
        try std.testing.expect(!result.valid(request));
    }
}
