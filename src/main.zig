const std = @import("std");
const builtin = @import("builtin");
const habush = @import("habush");
const Io = std.Io;
const platform = @import("platform.zig");
const Shell = @import("Shell.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const stdin_file = Io.File.stdin();
    const stdout_file = Io.File.stdout();
    const stderr_file = Io.File.stderr();

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [0]u8 = undefined; // TODO: add buffer

    var stdin_reader = stdin_file.readerStreaming(io, &stdin_buffer);
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buffer);
    var stderr_writer = stderr_file.writerStreaming(io, &.{});

    const stdin = &stdin_reader.interface;
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const invocation = Invocation.parse(args) orelse {
        try stderr.print("habush: usage: {s}\n", .{Invocation.usage});
        return 2;
    };
    const interactive = invocation == .stream and try stdin_file.isTty(io) and try stderr_file.isTty(io);

    if (interactive) try platform.ignoreInteractiveInterrupt();

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buffer) catch |err| switch (err) {
        error.NameTooLong => unreachable,
        else => |e| return e,
    };
    const cwd = cwd_buffer[0..cwd_len];
    const variables = try environmentBindings(arena, init.environ_map);
    const positional_parameters: []const []const u8 = switch (invocation) {
        .script => |script| try argumentSlices(arena, script.arguments),
        else => &.{},
    };
    const search_path = if (init.environ_map.get("PATH")) |path|
        try splitEnvironmentList(arena, path, std.fs.path.delimiter)
    else
        &.{};
    const resolver_options: habush.CommandResolver.System.Options = if (builtin.os.tag == .windows)
        if (init.environ_map.get("PATHEXT")) |extensions|
            .{ .executable_extensions = try splitEnvironmentList(
                arena,
                extensions,
                std.fs.path.delimiter,
            ) }
        else
            .{}
    else
        .{};

    var system_host: habush.Host.System = .{
        .gpa = gpa,
        .io = io,
        .environ_map = init.environ_map,
    };
    defer system_host.deinit();
    var system_resolver = habush.CommandResolver.System.init(io, resolver_options);
    var session = try habush.Session.init(gpa, system_host.host(), .{
        .resolver = system_resolver.resolver(),
        .cwd = cwd,
        .search_path = search_path,
        .positional_parameters = positional_parameters,
        .variables = variables,
        .io = .{
            .stdout = stdout,
            .stderr = stderr,
            .diagnostic_options = .{ .program_name = "habush" },
        },
    });
    defer session.deinit();

    var shell: Shell = .{
        .allocator = gpa,
        .stdin = stdin,
        .stderr = stderr,
        .session = &session,
        .interactive = interactive,
    };

    return switch (invocation) {
        .stream => shell.run(),
        .command => |command| shell.runCommand(command),
        .script => |script| {
            const source = Io.Dir.cwd().readFileAllocOptions(
                io,
                script.path,
                gpa,
                .unlimited,
                .of(u8),
                0,
            ) catch |err| {
                try reportScriptReadError(stderr, script.path, err);
                return 1;
            };
            defer gpa.free(source);
            return shell.runSource(source, script.path);
        },
    };
}

const Invocation = union(enum) {
    stream,
    command: []const u8,
    script: struct {
        path: []const u8,
        arguments: []const [:0]const u8,
    },

    const usage = "habush [-c command | script [argument ...]]";

    fn parse(args: []const [:0]const u8) ?Invocation {
        if (args.len <= 1) return .stream;
        if (args.len == 3 and std.mem.eql(u8, args[1], "-c")) {
            return .{ .command = args[2] };
        }
        if (std.mem.eql(u8, args[1], "--")) {
            if (args.len == 2) return .stream;
            return .{ .script = .{ .path = args[2], .arguments = args[3..] } };
        }
        if (std.mem.startsWith(u8, args[1], "-")) return null;
        return .{ .script = .{ .path = args[1], .arguments = args[2..] } };
    }
};

fn argumentSlices(
    allocator: std.mem.Allocator,
    arguments: []const [:0]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len);
    for (arguments, result) |argument, *destination| destination.* = argument;
    return result;
}

fn reportScriptReadError(
    writer: *Io.Writer,
    path: []const u8,
    err: anyerror,
) Io.Writer.Error!void {
    const message = switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        error.StreamTooLong => "file too large",
        else => @errorName(err),
    };
    try writer.print("habush: {s}: {s}\n", .{ path, message });
}

fn environmentBindings(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const habush.VariableStore.Binding {
    const bindings = try allocator.alloc(habush.VariableStore.Binding, environ_map.count());
    var len: usize = 0;
    for (environ_map.keys(), environ_map.values()) |name, value| {
        if (!habush.VariableStore.isValidName(name)) continue;
        bindings[len] = .{ .name = name, .value = value, .exported = true };
        len += 1;
    }
    return bindings[0..len];
}

fn splitEnvironmentList(
    allocator: std.mem.Allocator,
    value: []const u8,
    delimiter: u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, value, delimiter);
    while (iterator.next()) |item| try result.append(allocator, item);
    return result.toOwnedSlice(allocator);
}
