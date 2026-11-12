//! Collects here-document bodies from an already available source buffer.
//! Parser input retains blank physical lines where bodies and delimiters were
//! consumed, using the same submitted-input contract as the CLI input adapter.

const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const heredoc = @import("heredoc.zig");
const SourceInput = @This();
const Source = @import("Source.zig");

source: [:0]u8,
original_source: [:0]u8,
mappings: []Source.Mapping,
here_documents: []heredoc.Collected,

pub const Error = std.mem.Allocator.Error || error{ UnterminatedHereDocument, SourceTooLarge };

pub fn collect(gpa: std.mem.Allocator, source: []const u8) Error!SourceInput {
    const Pending = struct { delimiter: []const u8, strip_tabs: bool, expand_body: bool };
    const original = try gpa.dupeSentinel(u8, source, 0);
    errdefer gpa.free(original);
    var parser_source: std.ArrayList(u8) = .empty;
    defer parser_source.deinit(gpa);
    var mappings: std.ArrayList(Source.Mapping) = .empty;
    defer mappings.deinit(gpa);
    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |document| gpa.free(document.delimiter);
        pending.deinit(gpa);
    }
    var documents: std.ArrayList(heredoc.Collected) = .empty;
    errdefer {
        for (documents.items) |document| {
            gpa.free(document.delimiter);
            gpa.free(document.body);
        }
        documents.deinit(gpa);
    }
    var tokenizer = Tokenizer.init(original);
    var copied: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .lt_lt or token.tag == .lt_lt_minus) {
            const delimiter_token = tokenizer.next();
            if (delimiter_token.tag != .word and delimiter_token.tag != .digits and
                !std.mem.startsWith(u8, @tagName(delimiter_token.tag), "keyword_")) continue;
            const decoded = try heredoc.decodeDelimiter(gpa, source[delimiter_token.loc.start..delimiter_token.loc.end]);
            errdefer gpa.free(decoded.text);
            try pending.append(gpa, .{
                .delimiter = decoded.text,
                .strip_tabs = token.tag == .lt_lt_minus,
                .expand_body = !decoded.quoted,
            });
        } else if (token.tag == .newline and pending.items.len != 0) {
            try appendMapping(gpa, &mappings, parser_source.items.len, copied, token.loc.end - copied);
            try parser_source.appendSlice(gpa, source[copied..token.loc.end]);
            var offset = token.loc.end;
            for (pending.items) |*document| {
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(gpa);
                var physical: std.ArrayList(u8) = .empty;
                defer physical.deinit(gpa);
                var candidate: std.ArrayList(u8) = .empty;
                defer candidate.deinit(gpa);
                while (true) {
                    const line = nextLine(source, &offset) orelse return error.UnterminatedHereDocument;
                    if (offset > 0 and source[offset - 1] == '\n')
                        try appendMapping(gpa, &mappings, parser_source.items.len, offset - 1, 1);
                    try parser_source.append(gpa, '\n');
                    const stripped = heredoc.lineAfterTabStripping(line, document.strip_tabs);
                    try physical.appendSlice(gpa, stripped);
                    try physical.append(gpa, '\n');
                    const continued = document.expand_body and heredoc.hasLineContinuation(stripped);
                    try candidate.appendSlice(gpa, if (continued) stripped[0 .. stripped.len - 1] else stripped);
                    if (continued) continue;
                    if (std.mem.eql(u8, candidate.items, document.delimiter)) break;
                    try body.appendSlice(gpa, physical.items);
                    physical.clearRetainingCapacity();
                    candidate.clearRetainingCapacity();
                }
                const contents = try body.toOwnedSlice(gpa);
                errdefer gpa.free(contents);
                try documents.append(gpa, .{
                    .delimiter = document.delimiter,
                    .strip_tabs = document.strip_tabs,
                    .expand_body = document.expand_body,
                    .body = contents,
                });
                document.delimiter = &.{};
            }
            pending.clearRetainingCapacity();
            copied = offset;
            tokenizer.index = offset;
        }
    }
    if (pending.items.len != 0) return error.UnterminatedHereDocument;
    try appendMapping(gpa, &mappings, parser_source.items.len, copied, source.len - copied);
    try parser_source.appendSlice(gpa, source[copied..]);
    const collected = try documents.toOwnedSlice(gpa);
    errdefer {
        for (collected) |document| {
            gpa.free(document.delimiter);
            gpa.free(document.body);
        }
        gpa.free(collected);
    }
    const owned_source = try parser_source.toOwnedSliceSentinel(gpa, 0);
    errdefer gpa.free(owned_source);
    return .{
        .source = owned_source,
        .original_source = original,
        .mappings = try mappings.toOwnedSlice(gpa),
        .here_documents = collected,
    };
}

pub fn deinit(input: *SourceInput, gpa: std.mem.Allocator) void {
    gpa.free(input.source);
    gpa.free(input.original_source);
    gpa.free(input.mappings);
    for (input.here_documents) |document| {
        gpa.free(document.delimiter);
        gpa.free(document.body);
    }
    gpa.free(input.here_documents);
    input.* = undefined;
}

fn appendMapping(gpa: std.mem.Allocator, mappings: *std.ArrayList(Source.Mapping), parser_start: usize, original_start: usize, len: usize) Error!void {
    if (len == 0) return;
    try mappings.append(gpa, .{
        .parser_start = std.math.cast(u32, parser_start) orelse return error.SourceTooLarge,
        .original_start = std.math.cast(u32, original_start) orelse return error.SourceTooLarge,
        .len = std.math.cast(u32, len) orelse return error.SourceTooLarge,
    });
}

fn nextLine(source: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* == source.len) return null;
    const start = offset.*;
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    offset.* = @min(end + 1, source.len);
    return source[start..if (end > start and source[end - 1] == '\r') end - 1 else end];
}

test "source input owns here-documents across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseCollection, .{});
}

fn exerciseCollection(gpa: std.mem.Allocator) !void {
    const source = "cat <<'ONE' <<-TWO\n)\nONE\n\t$inner\n\tTWO\ntrue\n";
    var input = try collect(gpa, source);
    defer input.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), input.here_documents.len);
    try std.testing.expectEqualStrings(")\n", input.here_documents[0].body);
    try std.testing.expect(!input.here_documents[0].expand_body);
    try std.testing.expectEqualStrings("$inner\n", input.here_documents[1].body);
    try std.testing.expect(input.here_documents[1].expand_body);
    try std.testing.expectEqual(std.mem.count(u8, source, "\n"), std.mem.count(u8, input.source, "\n"));
    const start = std.mem.indexOf(u8, input.source, "true").?;
    const location: Source.Location = .{
        .start = @intCast(start),
        .end = @intCast(start + 4),
        .origin = .{ .text = input.source, .original_text = input.original_source, .mappings = input.mappings },
    };
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "true").?)), location.originalRange().?.start);
    try std.testing.expectEqualStrings("true", location.originalSlice().?);
}

test "source collection maps commands after CRLF here-documents" {
    const source = "cat <<EOF\r\nlong body\r\nEOF\r\nmissing\r\n";
    var input = try collect(std.testing.allocator, source);
    defer input.deinit(std.testing.allocator);
    const start = std.mem.indexOf(u8, input.source, "missing").?;
    const location: Source.Location = .{
        .start = @intCast(start),
        .end = @intCast(start + 7),
        .origin = .{ .text = input.source, .original_text = input.original_source, .mappings = input.mappings },
    };
    try std.testing.expectEqualStrings("missing", location.originalSlice().?);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "missing").?)), location.absoluteRange().?.start);
}
