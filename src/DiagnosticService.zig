//! Native syntax diagnostics plus an optional application-supplied provider.
const std = @import("std");
const habush = @import("habush");
const Diagnostic = @import("habush-edit").Diagnostic;
const DiagnosticService = @This();

additional: ?Diagnostic.Provider = null,
cwd: ?[]const u8 = null,

pub fn provider(service: *DiagnosticService) Diagnostic.Provider {
    return .{ .userdata = service, .query = query };
}

fn query(userdata: ?*anyopaque, arena: std.mem.Allocator, request: Diagnostic.Request) Diagnostic.Error!Diagnostic.Result {
    const service: *DiagnosticService = @ptrCast(@alignCast(userdata.?));
    var result = try native(arena, request);
    const extra = service.additional orelse return result;
    var scoped = request;
    scoped.cwd = service.cwd;
    const added = extra.query(extra.userdata, arena, scoped) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        error.Unavailable => return result,
    };
    if (!added.valid(request)) return result;
    var items: std.ArrayList(Diagnostic) = .empty;
    try items.appendSlice(arena, result.items);
    var bytes: usize = 0;
    for (result.items) |item| bytes += item.message.len;
    for (added.items) |item| {
        if (items.items.len == Diagnostic.max_items or item.message.len > Diagnostic.max_bytes - bytes) break;
        try items.append(arena, item);
        bytes += item.message.len;
    }
    result.items = items.items;
    return result;
}

fn native(arena: std.mem.Allocator, request: Diagnostic.Request) Diagnostic.Error!Diagnostic.Result {
    const empty: Diagnostic.Result = .{ .revision = request.revision };
    const submitted = try arena.print("{s}\n", .{request.source});
    const input = habush.SourceInput.collect(arena, submitted) catch |err| switch (err) {
        error.UnterminatedHereDocument, error.SourceTooLarge => return empty,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const tree = habush.Ast.parseWithOptions(arena, input.source, .{ .collected_here_documents = input.here_documents }) catch |err| switch (err) {
        error.SourceTooLarge => return empty,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const origin: habush.Source.View = .{ .text = input.source, .original_text = input.original_source, .mappings = input.mappings };
    var items: std.ArrayList(Diagnostic) = .empty;
    var bytes: usize = 0;
    for (tree.errors[0..@min(tree.errors.len, Diagnostic.max_items)]) |parse_error| {
        const start = tree.tokenStart(parse_error.token);
        const token = tree.tokenSlice(parse_error.token);
        const range = origin.originalRange(.{ .start = start, .end = start + @as(u32, @intCast(token.len)) }) orelse continue;
        var message: std.Io.Writer.Allocating = .init(arena);
        tree.renderError(parse_error, &message.writer) catch return error.OutOfMemory;
        if (message.written().len > Diagnostic.max_bytes - bytes) break;
        bytes += message.written().len;
        try items.append(arena, .{
            .start = @min(range.start, request.source.len),
            .end = @min(range.end, request.source.len),
            .severity = .@"error",
            .message = message.written(),
        });
    }
    return .{ .revision = request.revision, .items = items.items };
}

test "native diagnostics map past here-documents and invalid extra results are discarded" {
    const Extra = struct {
        fn queryExtra(_: ?*anyopaque, _: std.mem.Allocator, request: Diagnostic.Request) Diagnostic.Error!Diagnostic.Result {
            return .{ .revision = request.revision + 1, .items = &.{.{ .start = 0, .end = 99999, .message = "stale" }} };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var service: DiagnosticService = .{ .additional = .{ .query = Extra.queryExtra } };
    const request: Diagnostic.Request = .{ .source = ": <<'EOF'\n$(never-run)\nEOF\n)", .revision = 7 };
    const result = try query(&service, arena.allocator(), request);
    try std.testing.expect(result.valid(request));
    try std.testing.expect(result.items.len != 0);
    try std.testing.expectEqual(request.source.len - 1, result.items[0].start);
    const incomplete = try query(&service, arena.allocator(), .{ .source = "if true; then", .revision = 8 });
    try std.testing.expectEqual(@as(usize, 0), incomplete.items.len);
}
