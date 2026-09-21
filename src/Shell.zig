//! Frontend loop for parsing and executing shell input.

const std = @import("std");
const habush = @import("habush");
const Io = std.Io;
const Shell = @This();

allocator: std.mem.Allocator,
stdin: *Io.Reader,
stderr: *Io.Writer,
session: *habush.Session,
interactive: bool,
last_status: u8 = 0,

pub fn run(self: *Shell) !u8 {
    while (true) {
        const source = try self.readCommand() orelse return self.last_status;
        defer self.allocator.free(source);

        if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) {
            continue;
        }

        switch (try self.handleInput(source, null)) {
            .none => continue,
            .exit => return self.last_status,
            .@"return", .@"break", .@"continue" => unreachable,
        }
    }
}

pub fn runCommand(self: *Shell, command: []const u8) !u8 {
    const source = try self.allocator.dupeZ(u8, command);
    defer self.allocator.free(source);
    return self.runSource(source, null);
}

pub fn runSource(self: *Shell, source: [:0]const u8, source_name: ?[]const u8) !u8 {
    if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) return 0;

    _ = try self.handleInput(source, source_name);
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

fn handleInput(
    self: *Shell,
    source: [:0]const u8,
    source_name: ?[]const u8,
) !habush.runtime.ControlFlow {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try habush.Ast.parse(allocator, source);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        for (tree.errors) |parse_error| {
            const location = tree.tokenLocation(0, parse_error.token);
            try self.stderr.writeAll("habush: ");
            if (source_name) |name| try self.stderr.print("{s}:", .{name});
            try self.stderr.print("{d}:{d}: ", .{
                location.line + 1,
                location.column + 1,
            });
            try tree.renderError(parse_error, self.stderr);
            try self.stderr.writeByte('\n');
        }
        self.last_status = 2;
        return .none;
    }
    switch (tree.status) {
        .complete => {},
        .incomplete => {
            try self.stderr.writeAll("habush: incomplete input\n");
            self.last_status = 2;
            return .none;
        },
    }

    var hir = try habush.AstGen.generate(allocator, tree);
    defer hir.deinit(allocator);
    const result = self.session.executeWithOptions(hir, .{
        .last_status = self.last_status,
    }) catch |err| switch (err) {
        error.UnsupportedInstruction,
        error.ParameterAssignmentUnavailable,
        error.PathnameExpansionUnsupported,
        error.TildeExpansionUnsupported,
        error.ParameterExpansionUnsupported,
        => {
            try self.stderr.print("habush: unsupported runtime feature: {s}\n", .{
                @errorName(err),
            });
            self.last_status = 2;
            return .none;
        },
        else => |other| return other,
    };
    self.last_status = result.status;

    return result.control_flow;
}

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
