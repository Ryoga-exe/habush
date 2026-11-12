//! Diagnostic schema v0: revision/source in; revision and range/severity/message groups out.
const std = @import("std");
const Host = @import("Host.zig");
const protocol = @import("protocol.zig");
const Diagnostic = @import("habush-edit").Diagnostic;

pub fn collect(module: *const Host.Module, arena: std.mem.Allocator, entry: []const u8, request: Diagnostic.Request, scope: Host.Scope) Host.Error!Diagnostic.Result {
    var number: [20]u8 = undefined;
    const revision = std.fmt.bufPrint(&number, "{d}", .{request.revision}) catch unreachable;
    const bytes = try protocol.encode(arena, &.{&.{ revision, request.source }}, scope.limits.request_bytes);
    return decode(arena, try module.invoke(arena, entry, bytes, scope), request);
}

fn decode(arena: std.mem.Allocator, bytes: []const u8, request: Diagnostic.Request) Host.Error!Diagnostic.Result {
    const values = try protocol.decode(arena, bytes, 1 + Diagnostic.max_items * 4);
    if (values.len == 0 or (values.len - 1) % 4 != 0) return error.InvalidResponse;
    const revision = std.fmt.parseInt(u64, values[0], 10) catch return error.InvalidResponse;
    const items = try arena.alloc(Diagnostic, (values.len - 1) / 4);
    for (items, 0..) |*item, index| {
        const fields = values[1 + index * 4 ..][0..4];
        item.* = .{
            .start = std.fmt.parseInt(usize, fields[0], 10) catch return error.InvalidResponse,
            .end = std.fmt.parseInt(usize, fields[1], 10) catch return error.InvalidResponse,
            .severity = std.meta.stringToEnum(Diagnostic.Severity, fields[2]) orelse return error.InvalidResponse,
            .message = fields[3],
        };
    }
    const result: Diagnostic.Result = .{ .revision = revision, .items = items };
    if (!result.valid(request)) return error.InvalidResponse;
    return result;
}

test "diagnostic replies reject stale revisions and malformed range groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const request: Diagnostic.Request = .{ .source = "abc", .revision = 7 };
    const valid = try protocol.encode(gpa, &.{&.{ "7", "0", "3", "warning", "literal\x1b" }}, 8192);
    try std.testing.expectEqual(@as(usize, 1), (try decode(gpa, valid, request)).items.len);
    for ([_][]const []const u8{
        &.{},                                 &.{ "7", "0" },                         &.{ "6", "0", "1", "note", "stale" },
        &.{ "7", "0", "4", "note", "range" }, &.{ "7", "2", "1", "note", "reverse" }, &.{ "7", "0", "1", "unknown", "severity" },
    }) |values| try std.testing.expectError(error.InvalidResponse, decode(gpa, try protocol.encode(gpa, &.{values}, 8192), request));
}
