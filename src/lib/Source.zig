//! Owned parser-input text and its origin. Offsets refer to this text; an
//! adapter can retain raw bytes and a mapping when parser input normalizes
//! newlines or replaces here-document bodies. Mapping is independent of lexing.

const std = @import("std");
const Source = @This();

text: [:0]u8,
name: ?[]u8,
id: ?u64,
revision: ?u64,
line_offset: usize,
base_offset: ?u32,
original_text: ?[:0]u8,
mappings: []Mapping,

pub const Mapping = struct {
    parser_start: u32,
    original_start: u32,
    len: u32,
};

pub const Range = struct { start: u32, end: u32 };

pub const View = struct {
    text: [:0]const u8,
    name: ?[]const u8 = null,
    /// Scoped to the Session that submitted this input, when available.
    id: ?u64 = null,
    revision: ?u64 = null,
    line_offset: usize = 0,
    /// Absolute byte base of original_text (or text for identity input).
    /// Null means the containing source's byte base is unknown.
    base_offset: ?u32 = 0,
    original_text: ?[:0]const u8 = null,
    /// Sorted, non-overlapping parser intervals copied from original_text.
    /// Bytes without an interval are synthetic and cannot be mapped.
    mappings: []const Mapping = &.{},

    pub fn originalBytes(source: View) [:0]const u8 {
        return source.original_text orelse source.text;
    }

    fn originalOffset(source: View, offset: u32, end_bias: bool) ?u32 {
        if (offset > source.text.len) return null;
        if (source.original_text == null) return if (source.mappings.len == 0) offset else null;
        var previous_end: ?u32 = null;
        for (source.mappings) |mapping| {
            const parser_end = std.math.add(u32, mapping.parser_start, mapping.len) catch return null;
            const original_end = std.math.add(u32, mapping.original_start, mapping.len) catch return null;
            if (parser_end > source.text.len or original_end > source.originalBytes().len) return null;
            if (offset == parser_end) {
                if (end_bias) return original_end;
                previous_end = original_end;
            }
            if (offset >= mapping.parser_start and offset < parser_end)
                return mapping.original_start + (offset - mapping.parser_start);
        }
        return if (offset == source.text.len) previous_end else null;
    }

    pub fn originalRange(source: View, range: Range) ?Range {
        if (range.start > range.end) return null;
        const start = source.originalOffset(range.start, false) orelse return null;
        const end = source.originalOffset(range.end, true) orelse return null;
        if (start > end) return null;
        return .{ .start = start, .end = end };
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

    pub fn originalRange(location: Location) ?Range {
        const origin = location.origin orelse return null;
        return origin.originalRange(.{ .start = location.start, .end = location.end orelse return null });
    }

    pub fn originalSlice(location: Location) ?[]const u8 {
        const origin = location.origin orelse return null;
        const range = location.originalRange() orelse return null;
        return origin.originalBytes()[range.start..range.end];
    }

    pub fn absoluteRange(location: Location) ?Range {
        const origin = location.origin orelse return null;
        const base = origin.base_offset orelse return null;
        const range = location.originalRange() orelse return null;
        return .{
            .start = std.math.add(u32, base, range.start) catch return null,
            .end = std.math.add(u32, base, range.end) catch return null,
        };
    }
};

pub fn init(gpa: std.mem.Allocator, source: View) std.mem.Allocator.Error!Source {
    const text = try gpa.dupeZ(u8, source.text);
    errdefer gpa.free(text);
    const original = if (source.original_text) |value| try gpa.dupeZ(u8, value) else null;
    errdefer if (original) |value| gpa.free(value);
    const mappings = try gpa.dupe(Mapping, source.mappings);
    errdefer gpa.free(mappings);
    return .{
        .text = text,
        .name = if (source.name) |name| try gpa.dupe(u8, name) else null,
        .id = source.id,
        .revision = source.revision,
        .line_offset = source.line_offset,
        .base_offset = source.base_offset,
        .original_text = original,
        .mappings = mappings,
    };
}

pub fn deinit(source: *Source, gpa: std.mem.Allocator) void {
    gpa.free(source.text);
    if (source.name) |name| gpa.free(name);
    if (source.original_text) |original| gpa.free(original);
    gpa.free(source.mappings);
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
        .original_text = source.original_text,
        .mappings = source.mappings,
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

pub fn setInputMapping(source: *Source, gpa: std.mem.Allocator, original: []const u8, mappings: []const Mapping) std.mem.Allocator.Error!void {
    const copy = try gpa.dupeZ(u8, original);
    errdefer gpa.free(copy);
    const mapping_copy = try gpa.dupe(Mapping, mappings);
    if (source.original_text) |previous| gpa.free(previous);
    gpa.free(source.mappings);
    source.original_text = copy;
    source.mappings = mapping_copy;
}

/// Composes a child's parser-to-input mapping with a mapped parent slice.
/// Child original offsets are relative to parent.start. Returned original
/// offsets are relative to parent.originalRange().start.
pub fn composeMappings(gpa: std.mem.Allocator, child: []const Mapping, parent: Location) std.mem.Allocator.Error![]Mapping {
    const origin = parent.origin orelse return gpa.alloc(Mapping, 0);
    const range = parent.originalRange() orelse return gpa.alloc(Mapping, 0);
    if (origin.original_text == null) return gpa.dupe(Mapping, child);
    var result: std.ArrayList(Mapping) = .empty;
    errdefer result.deinit(gpa);
    for (child) |inner| {
        const start = std.math.add(u32, parent.start, inner.original_start) catch continue;
        const end = std.math.add(u32, start, inner.len) catch continue;
        for (origin.mappings) |outer| {
            const outer_end = std.math.add(u32, outer.parser_start, outer.len) catch continue;
            const overlap_start = @max(start, outer.parser_start);
            const overlap_end = @min(end, outer_end);
            if (overlap_start >= overlap_end) continue;
            const raw_start = std.math.add(u32, outer.original_start, overlap_start - outer.parser_start) catch continue;
            const raw_end = std.math.add(u32, raw_start, overlap_end - overlap_start) catch continue;
            if (raw_start < range.start or raw_end > range.end) continue;
            try result.append(gpa, .{
                .parser_start = std.math.add(u32, inner.parser_start, overlap_start - start) catch continue,
                .original_start = raw_start - range.start,
                .len = overlap_end - overlap_start,
            });
        }
    }
    return result.toOwnedSlice(gpa);
}

test "source mappings own raw bytes and distinguish unknown or synthetic offsets" {
    const raw = "a\r\nhidden\r\nb";
    var mappings = [_]Mapping{
        .{ .parser_start = 0, .original_start = 0, .len = 1 },
        .{ .parser_start = 1, .original_start = 2, .len = 1 },
        .{ .parser_start = 2, .original_start = 10, .len = 1 },
        .{ .parser_start = 3, .original_start = 11, .len = 1 },
    };
    var owned = try Source.init(std.testing.allocator, .{
        .text = "a\n\nb",
        .original_text = raw,
        .mappings = &mappings,
        .base_offset = 100,
    });
    mappings[3].original_start = 0;
    var copy = try owned.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    owned.deinit(std.testing.allocator);
    const location: Location = .{ .start = 3, .end = 4, .origin = copy.view() };
    try std.testing.expectEqualStrings("b", location.originalSlice().?);
    try std.testing.expectEqualDeep(Range{ .start = 111, .end = 112 }, location.absoluteRange().?);
    var unknown = location;
    unknown.origin.?.base_offset = null;
    try std.testing.expect(unknown.absoluteRange() == null);
    const synthetic: Location = .{
        .start = 0,
        .end = 2,
        .origin = .{
            .text = "b\n",
            .original_text = "b",
            .mappings = &.{.{ .parser_start = 0, .original_start = 0, .len = 1 }},
        },
    };
    try std.testing.expect(synthetic.originalRange() == null);
}
