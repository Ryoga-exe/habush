//! Completion supplied by an embedding application, not a language.
//! Query results are borrowed until the next query or service destruction.
const std = @import("std");
const Buffer = @import("Buffer.zig");
const Completion = @This();

userdata: *anyopaque,
query: *const fn (*anyopaque, Request) Error!?Result,
/// Optional nonblocking collection. Pending results have no usable labels.
poll: ?*const fn (*anyopaque, Request) Error!?Result = null,
/// Invalidates the request promptly; the service joins work before destruction.
cancel: ?*const fn (*anyopaque) void = null,
/// Returns an edit owned by the supplied allocator. The service must reject
/// selections whose source, revision, or cursor no longer matches its query.
choose: *const fn (*anyopaque, std.mem.Allocator, Request, usize) Error!?Edit,

pub const Error = std.mem.Allocator.Error || error{Canceled};

pub const Request = struct {
    /// Borrowed only for this call; services retaining it must copy it.
    source: []const u8,
    cursor: usize,
    revision: u64,
    input_id: u64 = 0,
    id: u64 = 0,
};

pub const Result = struct {
    /// Presentation text only. Selection indices refer to this exact result.
    labels: []const []const u8 = &.{},
    pending: bool = false,
    truncated: bool = false,
    incomplete: bool = false,

    pub fn unique(result: Result) bool {
        return !result.pending and !result.truncated and !result.incomplete and result.labels.len == 1;
    }
};

pub const Edit = struct {
    revision: u64,
    cursor: usize,
    start: usize,
    end: usize,
    text: []u8,

    pub fn deinit(edit: *Edit, gpa: std.mem.Allocator) void {
        gpa.free(edit.text);
        edit.* = undefined;
    }

    /// A rejected edit leaves both the buffer and its Undo snapshot intact.
    pub fn apply(edit: Edit, buffer: *Buffer, max_bytes: usize) std.mem.Allocator.Error!bool {
        if (edit.revision != buffer.revision or edit.cursor != buffer.cursor or
            edit.start > edit.end or edit.end > buffer.text().len) return false;
        const retained = buffer.text().len - (edit.end - edit.start);
        if (retained > max_bytes or edit.text.len > max_bytes - retained) return false;
        try buffer.replace(edit.start, edit.end, edit.text);
        return true;
    }
};

test "completion edits reject stale cursors and invalid ranges without changing Undo" {
    const gpa = std.testing.allocator;
    var buffer: Buffer = .{ .gpa = gpa };
    defer buffer.deinit();
    try buffer.insert("ab");
    var edit: Edit = .{
        .revision = buffer.revision,
        .cursor = buffer.cursor,
        .start = 0,
        .end = 2,
        .text = try gpa.dupe(u8, "complete"),
    };
    defer edit.deinit(gpa);
    buffer.left();
    try std.testing.expect(!try edit.apply(&buffer, 64));
    buffer.right();
    edit.end = 3;
    try std.testing.expect(!try edit.apply(&buffer, 64));
    edit.end = 2;
    try std.testing.expect(!try edit.apply(&buffer, 1));
    try std.testing.expectEqualStrings("ab", buffer.text());
    try std.testing.expect(buffer.undo());
    try std.testing.expectEqualStrings("", buffer.text());
    try std.testing.expect(!try edit.apply(&buffer, 64));
    try std.testing.expect(buffer.undo());
    edit.revision = buffer.revision;
    try std.testing.expect(try edit.apply(&buffer, 64));
    try std.testing.expectEqualStrings("complete", buffer.text());
    try std.testing.expect(buffer.undo());
    try std.testing.expectEqualStrings("ab", buffer.text());
}
