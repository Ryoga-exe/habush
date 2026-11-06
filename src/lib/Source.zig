//! Owned parser-input text and its origin. Offsets refer to this text; an
//! adapter can retain a name, revision, and physical line/byte base separately.

const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Source = @This();

text: [:0]u8,
name: ?[]u8,
id: ?u64,
revision: ?u64,
line_offset: usize,
base_offset: u32,

pub const View = struct {
    text: [:0]const u8,
    name: ?[]const u8 = null,
    /// Scoped to the Session that submitted this input, when available.
    id: ?u64 = null,
    revision: ?u64 = null,
    line_offset: usize = 0,
    base_offset: u32 = 0,

    pub fn tokenLocation(source: View, start: u32) Location {
        if (start >= source.text.len) return .{ .start = start, .origin = source };
        var tokenizer = Tokenizer.init(source.text[start.. :0]);
        const token = tokenizer.next();
        return .{
            .start = start,
            .end = std.math.cast(u32, @as(usize, start) + token.loc.end),
            .origin = source,
        };
    }
};

pub const Location = struct {
    start: u32,
    /// Exclusive; absent when only a point is available.
    end: ?u32 = null,
    /// Borrowed for the receiving callback/operation. Copy to retain it.
    origin: ?View = null,

    pub fn slice(location: Location) ?[]const u8 {
        const origin = location.origin orelse return null;
        const end = location.end orelse return null;
        if (location.start > end or end > origin.text.len) return null;
        return origin.text[location.start..end];
    }
};

pub fn init(gpa: std.mem.Allocator, source: View) std.mem.Allocator.Error!Source {
    const text = try gpa.dupeZ(u8, source.text);
    errdefer gpa.free(text);
    return .{
        .text = text,
        .name = if (source.name) |name| try gpa.dupe(u8, name) else null,
        .id = source.id,
        .revision = source.revision,
        .line_offset = source.line_offset,
        .base_offset = source.base_offset,
    };
}

pub fn deinit(source: *Source, gpa: std.mem.Allocator) void {
    gpa.free(source.text);
    if (source.name) |name| gpa.free(name);
    source.* = undefined;
}

pub fn view(source: Source) View {
    return .{
        .text = source.text,
        .name = source.name,
        .id = source.id,
        .revision = source.revision,
        .line_offset = source.line_offset,
        .base_offset = source.base_offset,
    };
}

pub fn clone(source: Source, gpa: std.mem.Allocator) std.mem.Allocator.Error!Source {
    return init(gpa, source.view());
}

/// Updates metadata without replacing the parser-input bytes. Allocation is
/// completed before modifying the previous origin.
pub fn setOrigin(source: *Source, gpa: std.mem.Allocator, origin: View) std.mem.Allocator.Error!void {
    const name = if (origin.name) |value| try gpa.dupe(u8, value) else null;
    if (source.name) |previous| gpa.free(previous);
    source.name = name;
    source.id = origin.id;
    source.revision = origin.revision;
    source.line_offset = origin.line_offset;
    source.base_offset = origin.base_offset;
}
