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
last_status: habush.runtime.ExitStatus = 0,
input_line: usize = 0,

pub fn run(self: *Shell) !habush.runtime.ExitStatus {
    return self.runInput(null);
}

fn runInput(self: *Shell, source_name: ?[]const u8) !habush.runtime.ExitStatus {
    while (true) {
        var input = try self.readCommand() orelse return self.last_status;
        defer input.deinit(self.allocator);

        if (input.incomplete_here_document) {
            try self.stderr.writeAll("habush: incomplete here-document\n");
            self.last_status = 2;
            continue;
        }
        if (std.mem.trim(u8, input.source, &std.ascii.whitespace).len == 0) {
            continue;
        }

        switch (try self.handleInput(
            input.source,
            input.here_documents,
            source_name,
            input.source_line,
        )) {
            .none => continue,
            .exit => return self.last_status,
            .@"return", .@"break", .@"continue" => unreachable,
        }
    }
}

pub fn runCommand(self: *Shell, command: []const u8) !habush.runtime.ExitStatus {
    const source = try self.allocator.dupeZ(u8, command);
    defer self.allocator.free(source);
    return self.runSource(source, null);
}

pub fn runSource(
    self: *Shell,
    source: [:0]const u8,
    source_name: ?[]const u8,
) !habush.runtime.ExitStatus {
    if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) return 0;
    var reader: Io.Reader = .fixed(source);
    const previous_stdin = self.stdin;
    const previous_interactive = self.interactive;
    const previous_input_line = self.input_line;
    self.stdin = &reader;
    self.interactive = false;
    self.input_line = 0;
    defer {
        self.stdin = previous_stdin;
        self.interactive = previous_interactive;
        self.input_line = previous_input_line;
    }
    return self.runInput(source_name);
}

const CommandInput = struct {
    source: [:0]u8,
    here_documents: []habush.heredoc.Collected,
    incomplete_here_document: bool,
    source_line: usize,

    fn deinit(input: *CommandInput, allocator: std.mem.Allocator) void {
        allocator.free(input.source);
        for (input.here_documents) |document| {
            allocator.free(document.delimiter);
            allocator.free(document.body);
        }
        allocator.free(input.here_documents);
        input.* = undefined;
    }
};

fn readCommand(self: *Shell) !?CommandInput {
    const source_line = self.input_line;
    var command: Io.Writer.Allocating = .init(self.allocator);
    errdefer command.deinit();
    var documents: std.ArrayList(habush.heredoc.Collected) = .empty;
    errdefer {
        for (documents.items) |document| {
            self.allocator.free(document.delimiter);
            self.allocator.free(document.body);
        }
        documents.deinit(self.allocator);
    }
    var continuation = false;

    while (true) {
        if (self.interactive) try self.printPrompt(continuation);
        const line = try self.readInputLine() orelse {
            if (self.interactive) try self.stderr.writeByte('\n');
            if (command.written().len == 0) {
                command.deinit();
                return null;
            }
            return .{
                .source = try command.toOwnedSliceSentinel(0),
                .here_documents = try documents.toOwnedSlice(self.allocator),
                .incomplete_here_document = false,
                .source_line = source_line,
            };
        };
        defer self.allocator.free(line);

        try command.writer.writeAll(line);
        try command.writer.writeByte('\n');

        const source_len = command.written().len;
        try command.writer.writeByte(0);
        const source = command.written()[0..source_len :0];
        var inspection = try self.inspectCommand(source, documents.items);
        defer inspection.deinit(self.allocator);
        command.shrinkRetainingCapacity(source_len);
        var incomplete_here_document = false;
        if (inspection.ready_here_document_count > documents.items.len) {
            for (documents.items.len..inspection.ready_here_document_count) |document_index| {
                const metadata = inspection.here_documents[document_index];
                const body = try self.readHereDocument(metadata) orelse {
                    incomplete_here_document = true;
                    break;
                };
                errdefer self.allocator.free(body);
                const delimiter = try self.allocator.dupe(u8, metadata.delimiter);
                errdefer self.allocator.free(delimiter);
                try documents.append(self.allocator, .{
                    .delimiter = delimiter,
                    .strip_tabs = metadata.strip_tabs,
                    .expand_body = metadata.expand_body,
                    .body = body,
                });
            }
        }
        if (incomplete_here_document) return .{
            .source = try command.toOwnedSliceSentinel(0),
            .here_documents = try documents.toOwnedSlice(self.allocator),
            .incomplete_here_document = true,
            .source_line = source_line,
        };

        const ready = inspection.errors or !inspection.incomplete;
        if (ready) return .{
            .source = try command.toOwnedSliceSentinel(0),
            .here_documents = try documents.toOwnedSlice(self.allocator),
            .incomplete_here_document = false,
            .source_line = source_line,
        };
        continuation = true;
    }
}

const CommandInspection = struct {
    errors: bool,
    incomplete: bool,
    ready_here_document_count: usize,
    here_documents: []HereDocumentMetadata,

    const HereDocumentMetadata = struct {
        delimiter: []u8,
        strip_tabs: bool,
        expand_body: bool,
    };

    fn deinit(inspection: *CommandInspection, allocator: std.mem.Allocator) void {
        for (inspection.here_documents) |document| allocator.free(document.delimiter);
        allocator.free(inspection.here_documents);
        inspection.* = undefined;
    }
};

fn inspectCommand(
    self: *Shell,
    source: [:0]const u8,
    collected: []const habush.heredoc.Collected,
) !CommandInspection {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var tree = try habush.Ast.parseWithOptions(arena.allocator(), source, .{
        .collected_here_documents = collected,
    });
    defer tree.deinit(arena.allocator());
    const metadata = try self.allocator.alloc(
        CommandInspection.HereDocumentMetadata,
        tree.ready_here_document_count,
    );
    var initialized: usize = 0;
    errdefer {
        for (metadata[0..initialized]) |document| self.allocator.free(document.delimiter);
        self.allocator.free(metadata);
    }
    for (metadata, 0..) |*destination, index| {
        const document = tree.hereDocument(@enumFromInt(index));
        destination.* = .{
            .delimiter = try self.allocator.dupe(u8, document.delimiter),
            .strip_tabs = document.strip_tabs,
            .expand_body = document.expand_body,
        };
        initialized += 1;
    }
    return .{
        .errors = tree.errors.len != 0,
        .incomplete = tree.status == .incomplete,
        .ready_here_document_count = tree.ready_here_document_count,
        .here_documents = metadata,
    };
}

fn readHereDocument(
    self: *Shell,
    metadata: CommandInspection.HereDocumentMetadata,
) !?[]u8 {
    var body: Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();
    while (true) {
        if (self.interactive) try self.printPrompt(true);
        const line = try self.readInputLine() orelse {
            body.deinit();
            return null;
        };
        defer self.allocator.free(line);
        const stripped = habush.heredoc.lineAfterTabStripping(line, metadata.strip_tabs);
        if (std.mem.eql(u8, stripped, metadata.delimiter))
            return try body.toOwnedSlice();
        try body.writer.writeAll(stripped);
        try body.writer.writeByte('\n');
    }
}

fn readInputLine(self: *Shell) !?[:0]u8 {
    const line = try readLineAlloc(self.stdin, self.allocator) orelse return null;
    self.input_line += 1;
    return line;
}

fn printPrompt(self: *Shell, continuation: bool) !void {
    try self.stderr.writeAll(if (continuation) "> " else "habush> ");
    try self.stderr.flush();
}

fn handleInput(
    self: *Shell,
    source: [:0]const u8,
    collected_here_documents: []const habush.heredoc.Collected,
    source_name: ?[]const u8,
    source_line: usize,
) !habush.runtime.ControlFlow {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try habush.Ast.parseWithOptions(allocator, source, .{
        .collected_here_documents = collected_here_documents,
    });
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        for (tree.errors) |parse_error| {
            const location = tree.tokenLocation(0, parse_error.token);
            try self.stderr.writeAll("habush: ");
            if (source_name) |name| try self.stderr.print("{s}:", .{name});
            try self.stderr.print("{d}:{d}: ", .{
                source_line + location.line + 1,
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
