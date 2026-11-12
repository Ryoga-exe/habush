//! Connects shell completion providers to a language-independent editor.
//! Providers and the continuation prefix are borrowed for one line-input scope.
const std = @import("std");
const habush = @import("habush");
const edit = @import("habush-edit");
const CompletionService = @This();

gpa: std.mem.Allocator,
prefix: []const u8,
providers: []const habush.Completion.Provider,
limits: habush.Completion.Provider.Limits = .{},
active: ?habush.Completion.Provider.Result = null,
labels: std.ArrayList([]const u8) = .empty,

pub fn deinit(service: *CompletionService) void {
    service.clear();
    service.labels.deinit(service.gpa);
    service.* = undefined;
}

pub fn completion(service: *CompletionService) edit.Completion {
    return .{ .userdata = service, .query = query, .choose = choose };
}

fn clear(service: *CompletionService) void {
    if (service.active) |*result| {
        const source = result.context.source;
        result.deinit(service.gpa);
        service.gpa.free(source);
        service.active = null;
    }
    service.labels.clearRetainingCapacity();
}

fn query(userdata: *anyopaque, request: edit.Completion.Request) edit.Completion.Error!?edit.Completion.Result {
    const service: *CompletionService = @ptrCast(@alignCast(userdata));
    service.clear();
    if (request.cursor > request.source.len) return null;
    const source = try std.mem.concat(service.gpa, u8, &.{ service.prefix, request.source });
    var retained = false;
    defer if (!retained) service.gpa.free(source);
    const context = habush.Completion.inspect(source, service.prefix.len + request.cursor, request.revision) catch return null;
    if (context.replace.start < service.prefix.len) return null;
    const prefix = context.literalPrefix(service.gpa) catch |err| switch (err) {
        error.UnsupportedContext => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer service.gpa.free(prefix);
    var result = try habush.Completion.Provider.collect(service.gpa, .{
        .context = context,
        .prefix = prefix,
    }, service.providers, service.limits);
    errdefer result.deinit(service.gpa);
    try service.labels.ensureTotalCapacity(service.gpa, result.candidates.len);
    for (result.candidates) |candidate|
        service.labels.appendAssumeCapacity(candidate.label orelse candidate.value);
    service.active = result;
    retained = true;
    return .{
        .labels = service.labels.items,
        .truncated = result.truncated,
        .incomplete = result.incomplete,
    };
}

fn choose(userdata: *anyopaque, gpa: std.mem.Allocator, request: edit.Completion.Request, index: usize) edit.Completion.Error!?edit.Completion.Edit {
    const service: *CompletionService = @ptrCast(@alignCast(userdata));
    const result = service.active orelse return null;
    const context = result.context;
    if (request.cursor > request.source.len or context.cursor != service.prefix.len + request.cursor or
        context.revision != request.revision or !std.mem.startsWith(u8, context.source, service.prefix) or
        !std.mem.eql(u8, context.source[service.prefix.len..], request.source)) return null;
    const replacement = result.makeEdit(gpa, index, context.source, request.revision) catch |err| switch (err) {
        error.StaleContext, error.UnsupportedContext, error.InvalidCandidate => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{
        .revision = request.revision,
        .cursor = request.cursor,
        .start = replacement.range.start - service.prefix.len,
        .end = replacement.range.end - service.prefix.len,
        .text = replacement.text,
    };
}

test "native completion owns its query and quotes current-line edits after a continuation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "a b'$(literal)";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var native: habush.Completion.Native = .{ .io = io, .cwd = cwd };
    const providers = [_]habush.Completion.Provider{native.provider()};
    var service: CompletionService = .{
        .gpa = gpa,
        .prefix = "true &&\ncd ",
        .providers = &providers,
    };
    defer service.deinit();
    const interface = service.completion();
    var input = [_]u8{'a'};
    var request: edit.Completion.Request = .{ .source = &input, .cursor = 1, .revision = 3 };
    const result = (try interface.query(interface.userdata, request)).?;
    try std.testing.expect(result.unique());
    try std.testing.expectEqualStrings(name, result.labels[0]);
    input[0] = 'b';
    try std.testing.expectEqualStrings("true &&\ncd a", service.active.?.context.source);
    try std.testing.expectEqual(null, try interface.choose(interface.userdata, gpa, request, 0));
    input[0] = 'a';
    request.cursor = 0;
    try std.testing.expectEqual(null, try interface.choose(interface.userdata, gpa, request, 0));
    request.cursor = 1;
    request.revision += 1;
    try std.testing.expectEqual(null, try interface.choose(interface.userdata, gpa, request, 0));
    request.revision -= 1;
    var replacement = (try interface.choose(interface.userdata, gpa, request, 0)).?;
    defer replacement.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), replacement.start);
    try std.testing.expectEqual(@as(usize, 1), replacement.end);
    try std.testing.expectEqualStrings("'a b'\\''$(literal)'", replacement.text);
    service.limits.candidates = 0;
    const partial = (try interface.query(interface.userdata, request)).?;
    try std.testing.expect(partial.truncated and !partial.unique());
    service.prefix = "cd '";
    try std.testing.expectEqual(null, try interface.query(interface.userdata, request));
    try std.testing.expectEqual(null, try interface.choose(interface.userdata, gpa, request, 0));
}
