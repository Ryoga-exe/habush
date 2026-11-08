//! Builtin/function names and native filesystem completion from explicit views.
//! No expansion, command execution, process cwd, or process environment lookup.
const std = @import("std");
const builtin = @import("builtin");
const Builtin = @import("../Builtin.zig");
const Completion = @import("../Completion.zig");
const Provider = @import("Provider.zig");
const Resolver = @import("../CommandResolver/System.zig");
const Native = @This();

io: std.Io,
/// Absolute shell cwd, borrowed only during collection. These views must not
/// change concurrently; a missing cwd disables relative filesystem searches.
cwd: ?[]const u8 = null,
path: ?[]const u8 = null,
default_search_path: []const []const u8 = &.{},
function_names: []const []const u8 = &.{},
executable_extensions: []const []const u8 = default_resolver.executable_extensions,

const default_resolver: Resolver.Options = .{};

pub fn provider(native: *Native) Provider {
    return .{ .userdata = native, .complete = complete };
}

fn complete(userdata: ?*anyopaque, request: Provider.Request, collector: *Provider.Collector) Provider.Error!void {
    const native: *Native = @ptrCast(@alignCast(userdata.?));
    if (request.context.dynamic) return;
    switch (request.context.kind) {
        .command => if (lastSeparator(request.prefix) == null) {
            inline for (std.meta.fields(Builtin.Tag)) |field| {
                if (!collector.step()) return;
                if (std.mem.startsWith(u8, field.name, request.prefix) and
                    !try collector.add(.{ .value = field.name, .kind = .command })) return;
            }
            for (native.function_names) |name| {
                if (!collector.step()) return;
                if (std.mem.startsWith(u8, name, request.prefix) and
                    !try collector.add(.{ .value = name, .kind = .command })) return;
            }
            if (native.path) |path| {
                var iterator = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
                while (iterator.next()) |directory| {
                    if (!collector.step()) return;
                    try native.scan(directory, "", request.prefix, true, collector);
                    if (collector.truncated) return;
                }
            } else for (native.default_search_path) |directory| {
                if (!collector.step()) return;
                try native.scan(directory, "", request.prefix, true, collector);
                if (collector.truncated) return;
            }
        } else try native.files(request, collector),
        .argument, .redirection => try native.files(request, collector),
        .parameter, .comment => {},
    }
}

fn files(native: Native, request: Provider.Request, collector: *Provider.Collector) Provider.Error!void {
    const slash = lastSeparator(request.prefix);
    const dirname = if (slash) |index| request.prefix[0 .. index + 1] else "";
    const basename = if (slash) |index| request.prefix[index + 1 ..] else request.prefix;
    try native.scan(dirname, dirname, basename, request.context.kind == .command, collector);
}

fn scan(
    native: Native,
    directory: []const u8,
    value_prefix: []const u8,
    basename: []const u8,
    executable_only: bool,
    collector: *Provider.Collector,
) Provider.Error!void {
    if (!std.fs.path.isAbsolute(directory) and
        (native.cwd == null or !std.fs.path.isAbsolute(native.cwd.?))) return error.Unavailable;
    // Preserve symlink/.. traversal exactly as the eventual file operation
    // does. Lexical normalization can select a different directory here.
    const path = if (std.fs.path.isAbsolute(directory))
        try collector.gpa.dupe(u8, directory)
    else
        try std.fs.path.join(collector.gpa, &.{ native.cwd.?, directory });
    defer collector.gpa.free(path);
    var dir = std.Io.Dir.openDirAbsolute(native.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return unavailable(err),
    };
    defer dir.close(native.io);
    var iterator = dir.iterate();
    while (iterator.next(native.io) catch |err| return unavailable(err)) |entry| {
        if (!collector.step()) return;
        if (!std.mem.startsWith(u8, entry.name, basename)) continue;
        if (basename.len == 0 and std.mem.startsWith(u8, entry.name, ".")) continue;
        const kind = if (entry.kind == .sym_link or entry.kind == .unknown)
            (dir.statFile(native.io, entry.name, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return unavailable(err),
            }).kind
        else
            entry.kind;
        if (executable_only) {
            if (kind == .directory) {
                // PATH directories contain command names, not navigation entries.
                if (value_prefix.len == 0) continue;
            } else {
                if (kind != .file) continue;
                if (builtin.os.tag == .windows and !native.executableExtension(entry.name)) continue;
                dir.access(native.io, entry.name, .{ .execute = true }) catch |err| switch (err) {
                    error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                    else => return unavailable(err),
                };
            }
        }
        const value = try std.mem.concat(collector.gpa, u8, &.{ value_prefix, entry.name, if (kind == .directory) "/" else "" });
        defer collector.gpa.free(value);
        if (!try collector.add(.{
            .value = value,
            .kind = if (kind == .directory) .directory else if (executable_only) .command else .file,
        })) return;
    }
}

fn executableExtension(native: Native, name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    for (native.executable_extensions) |allowed|
        if (std.ascii.eqlIgnoreCase(extension, allowed)) return true;
    return false;
}

fn lastSeparator(value: []const u8) ?usize {
    return std.mem.lastIndexOfAny(u8, value, if (builtin.os.tag == .windows) "/\\" else "/");
}

fn unavailable(err: anyerror) Provider.Error {
    return if (err == error.Canceled) error.Canceled else error.Unavailable;
}

test "native completion uses shell cwd and PATH, functions, and literal file values" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "bin", .default_dir);
    var tool = try tmp.dir.createFile(std.testing.io, "bin/habush-tool", .{ .permissions = .executable_file });
    tool.close(std.testing.io);
    var plain = try tmp.dir.createFile(std.testing.io, "bin/habush-plain", .{});
    plain.close(std.testing.io);
    var local = try tmp.dir.createFile(std.testing.io, "habush-cwd", .{ .permissions = .executable_file });
    local.close(std.testing.io);
    const filename = "space '$(literal)";
    var file = try tmp.dir.createFile(std.testing.io, filename, .{});
    file.close(std.testing.io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    var native: Native = .{
        .io = std.testing.io,
        .cwd = cwd,
        .path = if (builtin.os.tag == .windows) "bin;bin" else "bin:bin",
        .default_search_path = &.{"missing"},
        .function_names = &.{ "habush-function", "pwd" },
    };
    const providers = [_]Provider{native.provider()};
    const context = try Completion.inspect("habush-", 7, 1);
    var commands = try Provider.collect(std.testing.allocator, .{ .context = context, .prefix = "habush-" }, &providers, .{});
    defer commands.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, if (builtin.os.tag == .windows) 1 else 2), commands.candidates.len);
    try std.testing.expect(!commands.truncated and !commands.incomplete);
    try std.testing.expectEqualStrings("habush-function", commands.candidates[0].value);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("habush-tool", commands.candidates[1].value);
    // An explicitly empty PATH searches cwd, rather than the fallback or process PATH.
    native.path = "";
    var local_commands = try Provider.collect(std.testing.allocator, .{ .context = context, .prefix = "habush-" }, &providers, .{});
    defer local_commands.deinit(std.testing.allocator);
    try std.testing.expectEqual(commands.candidates.len, local_commands.candidates.len);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("habush-cwd", local_commands.candidates[1].value);
    const file_context = try Completion.inspect("cat sp", 6, 2);
    var files_result = try Provider.collect(std.testing.allocator, .{ .context = file_context, .prefix = "sp" }, &providers, .{});
    defer files_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(filename, files_result.unique().?.value);
    var edit = try files_result.makeEdit(std.testing.allocator, 0, "cat sp", 2);
    defer edit.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("'space '\\''$(literal)'", edit.text);
    native.path = null;
    native.default_search_path = &.{"bin"};
    var fallback = try Provider.collect(std.testing.allocator, .{ .context = context, .prefix = "habush-" }, &providers, .{});
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqual(commands.candidates.len, fallback.candidates.len);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("habush-tool", fallback.candidates[1].value);
    const builtin_context = try Completion.inspect("pw", 2, 3);
    var duplicate = try Provider.collect(std.testing.allocator, .{ .context = builtin_context, .prefix = "pw" }, &providers, .{});
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pwd", duplicate.unique().?.value);
}

test "completion preserves relative and absolute symlink parent traversal" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "work", "target", "target/deeper" }) |path|
        try tmp.dir.createDir(std.testing.io, path, .default_dir);
    for ([_][]const u8{ "work/item-wrong", "target/item-right" }) |path| {
        const file = try tmp.dir.createFile(std.testing.io, path, .{});
        file.close(std.testing.io);
    }
    try tmp.dir.symLink(std.testing.io, "../target/deeper", "work/link", .{ .is_directory = true });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const cwd = try std.fs.path.join(std.testing.allocator, &.{ base, "work" });
    defer std.testing.allocator.free(cwd);
    for ([_]bool{ false, true }) |absolute| {
        const prefix = if (absolute)
            try std.fmt.allocPrint(std.testing.allocator, "{s}/link/../item", .{cwd})
        else
            try std.testing.allocator.dupe(u8, "link/../item");
        defer std.testing.allocator.free(prefix);
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "cat ", prefix });
        defer std.testing.allocator.free(source);
        const context = try Completion.inspect(source, source.len, 1);
        var native: Native = .{ .io = std.testing.io, .cwd = if (absolute) null else cwd };
        var result = try Provider.collect(std.testing.allocator, .{ .context = context, .prefix = prefix }, &.{native.provider()}, .{});
        defer result.deinit(std.testing.allocator);
        const expected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "-right" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.unique().?.value);
    }
}
