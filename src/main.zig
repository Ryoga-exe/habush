const std = @import("std");
const builtin = @import("builtin");
const habush = @import("habush");
const Io = std.Io;
const platform = @import("platform.zig");
const Shell = @import("Shell.zig");
const ShellIntegration = @import("terminal/ShellIntegration.zig");
const Config = @import("Config.zig");
const Cli = @import("Cli.zig");
const features = @import("features");
const Plugins = if (features.wasm_plugins) @import("Plugins.zig") else void;

pub fn main(init: std.process.Init) !habush.runtime.ExitStatus {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const stdin_file = Io.File.stdin();
    const stdout_file = Io.File.stdout();
    const stderr_file = Io.File.stderr();

    // The shell and external children share this descriptor. One-byte buffering
    // prevents the parser or a builtin from hiding later input from a child.
    var stdin_buffer: [1]u8 = undefined;
    var stdout_buffer: [0]u8 = undefined; // TODO: add buffer

    var stdin_reader = stdin_file.readerStreaming(io, &stdin_buffer);
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buffer);
    var stderr_writer = stderr_file.writerStreaming(io, &.{});

    const stdin = &stdin_reader.interface;
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], habush.worker.argument))
        return habush.worker.run(init, args[2..]);
    const startup = Cli.parse(args) orelse {
        try stderr.print("habush: usage: {s}\n", .{Cli.usage});
        return 2;
    };
    const invocation = startup.invocation;
    const interactive = invocation == .stream and try stdin_file.isTty(io) and try stderr_file.isTty(io);

    var paths = try Config.Paths.init(gpa, init.environ_map);
    defer paths.deinit(gpa);
    var config: Config = .{};
    // Ambient application settings and rc are interactive startup behavior.
    // An explicit --config is still validated for -c and script invocations.
    if (!startup.no_config and (interactive or startup.config_path != null)) {
        config = (try Config.load(gpa, arena, io, paths, startup.config_path, stderr)) orelse return 2;
    }
    if (interactive or startup.config_path != null) {
        config = config.withEnvironment(init.environ_map) catch |err| {
            try Config.reportError(stderr, null, err);
            return 2;
        };
    }

    if (interactive) try platform.installInteractiveInterruptHandler();

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buffer) catch |err| switch (err) {
        error.NameTooLong => unreachable,
        else => |e| return e,
    };
    const cwd = cwd_buffer[0..cwd_len];
    const variables = try environmentBindings(arena, init.environ_map);
    const invocation_name = switch (invocation) {
        .script => |script| script.path,
        else => args[0],
    };
    const positional_parameters: []const []const u8 = switch (invocation) {
        .script => |script| try argumentSlices(arena, script.arguments),
        else => &.{},
    };
    const resolver_options: habush.CommandResolver.System.Options = if (builtin.target.os.tag == .windows)
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

    const worker_executable: ?[:0]u8 = if (builtin.target.os.tag == .windows)
        null
    else
        try std.process.executablePathAlloc(io, gpa);
    defer if (worker_executable) |path| gpa.free(path);
    var system_host: habush.Host.System = .{
        .gpa = gpa,
        .io = io,
        .environ_map = init.environ_map,
        .worker_executable = worker_executable,
    };
    defer system_host.deinit();
    var system_resolver = habush.CommandResolver.System.init(io, resolver_options);
    var concurrent_host: ?habush.concurrent.Host = habush.concurrent.Host.init(
        gpa,
        system_host.host(),
        io,
    ) catch |err| switch (err) {
        error.Unsupported => null,
        else => return err,
    };
    defer if (concurrent_host) |*adapter| adapter.deinit();
    var concurrent_resolver: habush.concurrent.Resolver = .{
        .inner = system_resolver.resolver(),
        .io = io,
    };
    const runtime_host = if (concurrent_host) |*adapter| adapter.host() else system_host.host();
    var plugins: Plugins = if (features.wasm_plugins) .{ .gpa = gpa, .io = io } else {};
    defer if (features.wasm_plugins) plugins.deinit();
    if (features.wasm_plugins) {
        plugins.load(config.plugins) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try stderr.print("habush: plugin: {s}: {s}\n", .{ plugins.loading_path orelse "initialization", @errorName(err) });
            return 2;
        };
    } else if (config.plugins.len != 0) {
        try stderr.writeAll("habush: plugins require a build with -Dwasmtime=<SDK>\n");
        return 2;
    }
    var session = try habush.Session.init(gpa, runtime_host, .{
        .commands = if (features.wasm_plugins) plugins.commands else &.{},
        .cancel_io = io,
        .job_control = interactive and runtime_host.capabilities().terminal_control,
        .concurrent_pipeline = if (concurrent_host != null) .{ .io = io, .allocator = gpa } else null,
        .resolver = concurrent_resolver.resolver(),
        .invocation_name = invocation_name,
        .shell_process_id = platform.processId(),
        .positional_parameters = positional_parameters,
        .variables = variables,
        .context = .{
            .cwd = cwd,
            .io = .{
                .stdin = stdin,
                .stdout = stdout,
                .stderr = stderr,
                .diagnostic_options = .{ .program_name = "habush" },
            },
        },
    });
    defer session.deinit();

    // Terminal metadata uses a dedicated presentation writer, never a command's
    // redirected stdout. Explicit opt-in still requires interactive TTYs.
    const integration_enabled = ShellIntegration.enabled(.{
        .interactive_terminal = interactive,
        .setting = @tagName(config.shell_integration),
        .term = init.environ_map.get("TERM"),
        .term_program = init.environ_map.get("TERM_PROGRAM"),
        .kitty = init.environ_map.get("KITTY_WINDOW_ID") != null,
        .windows_terminal = init.environ_map.get("WT_SESSION") != null,
    });
    var hostname_buffer: [if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) 0 else std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname: []const u8 = if (!integration_enabled)
        ""
    else if (builtin.target.os.tag == .windows)
        init.environ_map.get("COMPUTERNAME") orelse ""
    else
        std.posix.gethostname(&hostname_buffer) catch "";
    var shell: Shell = .{
        .allocator = gpa,
        .stdin = stdin,
        .stderr = stderr,
        .session = &session,
        .interactive = interactive,
        .interruptible = interactive,
        .io = io,
        .line_edit = config.lineEditEnabled(interactive, init.environ_map.get("TERM")),
        .completion_limits = config.completion_limits,
        .resolver_options = resolver_options,
        .completion_provider = if (features.wasm_plugins) plugins.provider() else null,
        .integration = if (integration_enabled) .{
            .writer = stderr,
            .hostname = hostname,
            .path_style = if (builtin.target.os.tag == .windows) .windows else .posix,
        } else null,
    };

    if (interactive and !startup.no_config and !startup.no_rc and config.load_rc) {
        const candidates = [_]?[]const u8{ try paths.rcFile(arena), try paths.legacyRcFile(arena) };
        for (candidates) |candidate| {
            const path = candidate orelse continue;
            const source = Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(Config.max_rc_bytes), .of(u8), 0) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.OutOfMemory => return err,
                else => {
                    try reportScriptReadError(stderr, path, err);
                    return 1;
                },
            };
            defer gpa.free(source);
            const status = try shell.runSource(source, path);
            if (session.lastResult().control_flow == .exit) return status;
            // Existing XDG rc takes precedence even when it is empty or fails;
            // compatibility fallback must never execute a second startup file.
            break;
        }
    }

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
        // Native Windows environment names are case-insensitive. Expose its
        // PATH entry under the shell's canonical spelling before lookup moves
        // into the case-sensitive shell variable store.
        const shell_name = if (builtin.target.os.tag == .windows and std.ascii.eqlIgnoreCase(name, "PATH"))
            "PATH"
        else
            name;
        bindings[len] = .{ .name = shell_name, .value = value, .exported = true };
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
