const std = @import("std");
const builtin = @import("builtin");
const habush = @import("habush");
const Io = std.Io;
const platform = @import("platform.zig");

pub fn main(init: std.process.Init) !void {
    const status = try runApplication(init);
    if (status != 0) std.process.exit(status);
}

const Invocation = union(enum) {
    stream,
    command: []const u8,
};

fn runApplication(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [0]u8 = .{};
    var stdout_file_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr_buffer: [0]u8 = .{};
    var stderr_file_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);

    const args = try init.minimal.args.toSlice(arena);
    const invocation = parseInvocation(args) orelse {
        try stderr_file_writer.interface.writeAll("habush: usage: habush [-c command]\n");
        return 2;
    };
    const interactive = invocation == .stream and
        try Io.File.stdin().isTty(io) and
        try Io.File.stderr().isTty(io);

    if (interactive) {
        try platform.ignoreInteractiveInterrupt();
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const variables = try environmentBindings(arena, init.environ_map);
    const search_path = if (init.environ_map.get("PATH")) |path|
        try splitEnvironmentList(arena, path, std.fs.path.delimiter)
    else
        &.{};
    const executable_extensions = if (builtin.os.tag == .windows)
        if (init.environ_map.get("PATHEXT")) |extensions|
            try splitEnvironmentList(arena, extensions, std.fs.path.delimiter)
        else
            default_executable_extensions
    else
        &.{};

    var system_host: habush.Host.System = .{
        .gpa = gpa,
        .io = io,
        .environ_map = init.environ_map,
    };
    defer system_host.deinit();
    var system_resolver: habush.CommandResolver.System = .{
        .io = io,
        .executable_extensions = executable_extensions,
    };
    var session = try habush.Session.init(gpa, system_host.host(), .{
        .resolver = system_resolver.resolver(),
        .cwd = cwd,
        .search_path = search_path,
        .variables = variables,
        .io = .{
            .stdout = &stdout_file_writer.interface,
            .stderr = &stderr_file_writer.interface,
            .diagnostic_options = .{ .program_name = "habush" },
        },
    });
    defer session.deinit();

    var shell: Shell = .{
        .allocator = gpa,
        .stdin = &stdin_file_reader.interface,
        .stderr = &stderr_file_writer.interface,
        .session = &session,
        .interactive = interactive,
    };

    return switch (invocation) {
        .stream => shell.run(),
        .command => |command| shell.runCommand(command),
    };
}

fn parseInvocation(args: []const [:0]const u8) ?Invocation {
    if (args.len <= 1) return .stream;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--")) return .stream;
    if (args.len == 3 and std.mem.eql(u8, args[1], "-c")) {
        return .{ .command = args[2] };
    }
    return null;
}

const Shell = struct {
    allocator: std.mem.Allocator,
    stdin: *Io.Reader,
    stderr: *Io.Writer,
    session: *habush.Session,
    interactive: bool,
    last_status: u8 = 0,

    const LoopAction = enum {
        @"continue",
        exit,
    };

    fn run(self: *Shell) !u8 {
        while (true) {
            const source = try self.readCommand() orelse return self.last_status;
            defer self.allocator.free(source);

            if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) {
                continue;
            }

            switch (try self.handleInput(source)) {
                .@"continue" => continue,
                .exit => return self.last_status,
            }
        }
    }

    fn runCommand(self: *Shell, command: []const u8) !u8 {
        if (std.mem.trim(u8, command, &std.ascii.whitespace).len == 0) return 0;

        const source = try self.allocator.dupeZ(u8, command);
        defer self.allocator.free(source);
        _ = try self.handleInput(source);
        return self.last_status;
    }

    fn readCommand(self: *Shell) !?[:0]u8 {
        var command: Io.Writer.Allocating = .init(self.allocator);
        errdefer command.deinit();
        var continuation = false;

        while (true) {
            if (self.interactive) try self.printPrompt(continuation);
            const line = try readLineAlloc(self.stdin, self.allocator) orelse {
                if (self.interactive) try self.stderr.writeByte('\n');
                if (command.written().len == 0) {
                    command.deinit();
                    return null;
                }
                return try command.toOwnedSliceSentinel(0);
            };
            defer self.allocator.free(line);

            try command.writer.writeAll(line);
            try command.writer.writeByte('\n');

            const source_len = command.written().len;
            try command.writer.writeByte(0);
            const source = command.written()[0..source_len :0];
            const ready = try self.commandIsReady(source);
            command.shrinkRetainingCapacity(source_len);
            if (ready) return try command.toOwnedSliceSentinel(0);
            continuation = true;
        }
    }

    fn commandIsReady(self: *Shell, source: [:0]const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var tree = try habush.Ast.parse(arena.allocator(), source);
        defer tree.deinit(arena.allocator());
        if (tree.errors.len != 0) return true;
        return tree.status == .complete;
    }

    fn printPrompt(self: *Shell, continuation: bool) !void {
        try self.stderr.writeAll(if (continuation) "> " else "habush> ");
        try self.stderr.flush();
    }

    fn handleInput(self: *Shell, source: [:0]const u8) !LoopAction {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (std.mem.eql(u8, std.mem.trim(u8, source, &std.ascii.whitespace), "exit")) {
            return .exit;
        }

        var tree = try habush.Ast.parse(allocator, source);
        defer tree.deinit(allocator);
        if (tree.errors.len != 0) {
            for (tree.errors) |parse_error| {
                const location = tree.tokenLocation(0, parse_error.token);
                try self.stderr.print("habush: {d}:{d}: ", .{
                    location.line + 1,
                    location.column + 1,
                });
                try tree.renderError(parse_error, self.stderr);
                try self.stderr.writeByte('\n');
            }
            self.last_status = 2;
            return .@"continue";
        }
        switch (tree.status) {
            .complete => {},
            .incomplete => {
                try self.stderr.writeAll("habush: incomplete input\n");
                self.last_status = 2;
                return .@"continue";
            },
        }

        var hir = try habush.AstGen.generate(allocator, tree);
        defer hir.deinit(allocator);
        const result = self.session.execute(hir) catch |err| switch (err) {
            error.UnsupportedInstruction,
            error.FieldSplittingUnsupported,
            error.PathnameExpansionUnsupported,
            error.TildeExpansionUnsupported,
            error.ParameterExpansionUnsupported,
            => {
                try self.stderr.print("habush: unsupported runtime feature: {s}\n", .{
                    @errorName(err),
                });
                self.last_status = 2;
                return .@"continue";
            },
            else => |other| return other,
        };
        self.last_status = result.status;

        return .@"continue";
    }
};

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

const default_executable_extensions: []const []const u8 = &.{
    ".COM",
    ".EXE",
    ".BAT",
    ".CMD",
};

fn readLineAlloc(reader: *Io.Reader, allocator: std.mem.Allocator) !?[:0]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const n = try reader.streamDelimiterEnding(&out.writer, '\n');

    const found_newline = reader.bufferedLen() > 0;
    if (found_newline) {
        // consume new line
        reader.toss(1);
    } else if (n == 0) {
        // EOF
        out.deinit();
        return null;
    }

    const written = out.written();

    // CRLF
    if (written.len > 0 and written[written.len - 1] == '\r') {
        out.shrinkRetainingCapacity(written.len - 1);
    }

    return try out.toOwnedSliceSentinel(0);
}
