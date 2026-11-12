//! Prompt schema v1 context in; alternating style/text byte-list items out.
const std = @import("std");
const Host = @import("Host.zig");
const protocol = @import("protocol.zig");
const Prompt = @import("habush-edit").Prompt;

pub fn render(module: *const Host.Module, arena: std.mem.Allocator, entry: []const u8, supplied_context: Prompt.Context, scope: Host.Scope) Host.Error!Prompt {
    const context = if (module.permissions(scope.capabilities.permissions).context) supplied_context else Prompt.Context{ .cwd = null, .status = 0 };
    var status: [3]u8 = undefined;
    const code = std.fmt.bufPrint(&status, "{d}", .{context.status}) catch unreachable;
    var duration_buffer: [20]u8 = undefined;
    const duration = if (context.duration_ns) |ns| std.fmt.bufPrint(&duration_buffer, "{d}", .{ns / std.time.ns_per_ms}) catch unreachable else "";
    var jobs_buffer: [20]u8 = undefined;
    const jobs = std.fmt.bufPrint(&jobs_buffer, "{d}", .{context.jobs}) catch unreachable;
    const git = context.git;
    const request = try protocol.encode(arena, &.{&.{
        "1",                               context.cwd orelse "",                         code,                                          duration, jobs,
        if (git) |info| info.root else "", if (git) |info| info.branch orelse "" else "", if (git) |info| info.commit orelse "" else "",
    }}, scope.limits.request_bytes);
    const bytes = try module.invoke(arena, entry, request, scope);
    return decode(arena, bytes);
}

fn decode(arena: std.mem.Allocator, bytes: []const u8) Host.Error!Prompt {
    const values = try protocol.decode(arena, bytes, Prompt.max_spans * 2);
    if (values.len % 2 != 0) return error.InvalidResponse;
    const spans = try arena.alloc(Prompt.Span, values.len / 2);
    for (spans, 0..) |*span, index| {
        const style = values[index * 2];
        if (style.len != 3 or style[0] < '0' or style[0] > '8' or
            style[1] < '0' or style[1] > '8' or style[2] < '0' or style[2] > '1') return error.InvalidResponse;
        span.* = .{ .text = values[index * 2 + 1], .style = .{
            .foreground = @fromBackingInt(style[0] - '0'),
            .background = @fromBackingInt(style[1] - '0'),
            .bold = style[2] == '1',
        } };
    }
    const prompt: Prompt = .{ .spans = spans };
    if (!prompt.valid()) return error.InvalidResponse;
    return prompt;
}

test "prompt replies validate styles, arity, and display limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const bytes = try protocol.encode(gpa, &.{&.{ "301", "日\x1b" }}, 4096);
    const result = try decode(gpa, bytes);
    try std.testing.expectEqual(Prompt.Color.green, result.spans[0].style.foreground);
    try std.testing.expect(result.spans[0].style.bold);
    for ([_][]const []const u8{ &.{"000"}, &.{ "900", "x" }, &.{ "00x", "x" }, &.{ "00", "x" } }) |values|
        try std.testing.expectError(error.InvalidResponse, decode(gpa, try protocol.encode(gpa, &.{values}, 4096)));
}
