//! Frontend loop for parsing and executing shell input.

const std = @import("std");
const habush = @import("habush");
const ShellIntegration = @import("terminal/ShellIntegration.zig");
const LineEditor = @import("terminal/LineEditor.zig");
const edit = @import("habush-edit");
const CompletionService = @import("CompletionService.zig");
const interrupt = @import("interrupt.zig");
const Io = std.Io;
const Shell = @This();

allocator: std.mem.Allocator,
/// Command source reader. runSource swaps this without changing the session's
/// runtime stdin, so `-c` and script `read` commands use process input.
stdin: *Io.Reader,
stderr: *Io.Writer,
session: *habush.Session,
interactive: bool,
/// Allows an interactive caller's startup source to remain cancellable while
/// runSource suppresses prompts, editing, and shell-integration messages.
interruptible: bool = false,
io: ?std.Io = null,
line_edit: bool = false,
completion_limits: habush.Completion.Provider.Limits = .{},
completion_provider: ?habush.Completion.Provider = null,
resolver_options: habush.CommandResolver.System.Options = .{},
integration: ?ShellIntegration = null,
input_line: usize = 0,
/// Known only for a fixed script/command source buffer.
input_byte_offset: ?u32 = null,
last_line_ending: LineEnding = .lf,
interrupt_generation: u32 = 0,
editing: ?*Editing = null,

const Editing = struct {
    history: edit.History,
    queued: ?[:0]u8 = null,
    offset: usize = 0,

    fn discard(editing: *Editing) void {
        if (editing.queued) |source| editing.history.gpa.free(source);
        editing.queued = null;
        editing.offset = 0;
    }
};

pub fn run(self: *Shell) !habush.runtime.ExitStatus {
    var editing: Editing = .{ .history = .{ .gpa = self.allocator } };
    self.editing = &editing;
    defer {
        self.editing = null;
        editing.discard();
        editing.history.deinit();
    }
    return self.runInput(null);
}

fn runInput(self: *Shell, source_name: ?[]const u8) !habush.runtime.ExitStatus {
    while (true) {
        self.interrupt_generation = interrupt.snapshot();
        var input = (self.withInterrupt(?CommandInput, readCommand, .{self}, discardInput, true) catch |err| switch (err) {
            error.InputInterrupted, error.Canceled => {
                if (self.editing) |editing| editing.discard();
                self.session.interruptInput();
                if (err == error.Canceled) try self.stderr.writeByte('\n');
                continue;
            },
            else => return err,
        }) orelse return self.session.lastResult().status;
        defer input.deinit(self.allocator);
        if (self.interactive) {
            if (self.editing) |editing| try editing.history.append(input.original_source);
        }

        if (input.incomplete_here_document) {
            try self.beginCommand(true);
            var command_open = true;
            errdefer if (command_open) self.endCommand(null) catch {};
            try self.stderr.writeAll("habush: incomplete here-document\n");
            self.session.rejectInput();
            command_open = false;
            try self.endCommand(2);
            if (!self.interactive) return 2;
            continue;
        }
        if (std.mem.trim(u8, input.source, &std.ascii.whitespace).len == 0) {
            continue;
        }

        try self.beginCommand(input.emit_execution_marks);
        var command_open = input.emit_execution_marks;
        errdefer if (command_open) self.endCommand(null) catch {};
        const control_flow = try self.handleInput(
            input.source,
            input.here_documents,
            source_name,
            input.source_line,
            input.original_source,
            input.mappings,
            input.source_offset,
        );
        if (command_open) {
            command_open = false;
            try self.endCommand(self.session.lastResult().status);
        }
        switch (control_flow) {
            .none => continue,
            .exit => return self.session.lastResult().status,
            .@"return", .@"break", .@"continue" => unreachable,
        }
    }
}

pub fn runCommand(self: *Shell, command: []const u8) !habush.runtime.ExitStatus {
    const source = try self.allocator.dupeSentinel(u8, command, 0);
    defer self.allocator.free(source);
    return self.runSource(source, null);
}

pub fn runSource(
    self: *Shell,
    source: [:0]const u8,
    source_name: ?[]const u8,
) !habush.runtime.ExitStatus {
    if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0)
        return self.session.lastResult().status;
    var reader: Io.Reader = .fixed(source);
    const previous_stdin = self.stdin;
    const previous_interactive = self.interactive;
    const previous_input_line = self.input_line;
    const previous_input_offset = self.input_byte_offset;
    const previous_line_ending = self.last_line_ending;
    self.stdin = &reader;
    self.interactive = false;
    self.input_line = 0;
    self.input_byte_offset = 0;
    defer {
        self.stdin = previous_stdin;
        self.interactive = previous_interactive;
        self.input_line = previous_input_line;
        self.input_byte_offset = previous_input_offset;
        self.last_line_ending = previous_line_ending;
    }
    return self.runInput(source_name);
}

const CommandInput = struct {
    source: [:0]u8,
    original_source: [:0]u8,
    mappings: []habush.Source.Mapping,
    source_offset: ?u32,
    here_documents: []habush.heredoc.Collected,
    incomplete_here_document: bool,
    source_line: usize,
    emit_execution_marks: bool = true,

    fn deinit(input: *CommandInput, allocator: std.mem.Allocator) void {
        allocator.free(input.source);
        allocator.free(input.original_source);
        allocator.free(input.mappings);
        for (input.here_documents) |document| {
            allocator.free(document.delimiter);
            allocator.free(document.body);
        }
        allocator.free(input.here_documents);
        input.* = undefined;
    }
};

const LineEnding = enum {
    none,
    lf,
    crlf,
    cr,

    fn bytes(ending: LineEnding) []const u8 {
        return switch (ending) {
            .none => "",
            .lf => "\n",
            .crlf => "\r\n",
            .cr => "\r",
        };
    }
};

fn appendInputLine(
    allocator: std.mem.Allocator,
    command: *Io.Writer.Allocating,
    original: *Io.Writer.Allocating,
    mappings: *std.ArrayList(habush.Source.Mapping),
    line: []const u8,
    ending: LineEnding,
    placeholder: bool,
) !void {
    const raw_start = original.written().len;
    try original.writer.writeAll(line);
    try original.writer.writeAll(ending.bytes());
    if (!placeholder) {
        if (line.len != 0) try mappings.append(allocator, .{
            .parser_start = std.math.cast(u32, command.written().len) orelse return error.SourceTooLarge,
            .original_start = std.math.cast(u32, raw_start) orelse return error.SourceTooLarge,
            .len = std.math.cast(u32, line.len) orelse return error.SourceTooLarge,
        });
        try command.writer.writeAll(line);
    }
    if (ending == .lf or ending == .crlf) try mappings.append(allocator, .{
        .parser_start = std.math.cast(u32, command.written().len) orelse return error.SourceTooLarge,
        .original_start = std.math.cast(u32, raw_start + line.len + ending.bytes().len - 1) orelse return error.SourceTooLarge,
        .len = 1,
    });
    try command.writer.writeByte('\n');
}

fn finishInput(
    allocator: std.mem.Allocator,
    command: *Io.Writer.Allocating,
    original: *Io.Writer.Allocating,
    mappings: *std.ArrayList(habush.Source.Mapping),
    documents: *std.ArrayList(habush.heredoc.Collected),
    source_line: usize,
    source_offset: ?u32,
    incomplete: bool,
    emit_marks: bool,
) !CommandInput {
    const source = try command.toOwnedSliceSentinel(0);
    errdefer allocator.free(source);
    const raw = try original.toOwnedSliceSentinel(0);
    errdefer allocator.free(raw);
    const map = try mappings.toOwnedSlice(allocator);
    errdefer allocator.free(map);
    return .{
        .source = source,
        .original_source = raw,
        .mappings = map,
        .source_offset = source_offset,
        .here_documents = try documents.toOwnedSlice(allocator),
        .incomplete_here_document = incomplete,
        .source_line = source_line,
        .emit_execution_marks = emit_marks,
    };
}

fn readCommand(self: *Shell) !?CommandInput {
    const source_line = self.input_line;
    const source_offset = self.input_byte_offset;
    var command: Io.Writer.Allocating = .init(self.allocator);
    errdefer command.deinit();
    var original: Io.Writer.Allocating = .init(self.allocator);
    errdefer original.deinit();
    var mappings: std.ArrayList(habush.Source.Mapping) = .empty;
    errdefer mappings.deinit(self.allocator);
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
        const line = try self.readInputLine(if (continuation) "> " else "habush> ", command.written(), true) orelse {
            if (self.interactive) try self.stderr.writeByte('\n');
            if (command.written().len == 0) {
                command.deinit();
                original.deinit();
                mappings.deinit(self.allocator);
                documents.deinit(self.allocator);
                return null;
            }
            return try finishInput(self.allocator, &command, &original, &mappings, &documents, source_line, source_offset, false, true);
        };
        defer self.allocator.free(line);
        try appendInputLine(self.allocator, &command, &original, &mappings, line, self.last_line_ending, false);

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
                const body = try self.readHereDocument(metadata, &command, &original, &mappings) orelse {
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
        if (incomplete_here_document)
            return try finishInput(self.allocator, &command, &original, &mappings, &documents, source_line, source_offset, true, true);
        const ready = inspection.errors or !inspection.incomplete;
        if (ready)
            return try finishInput(self.allocator, &command, &original, &mappings, &documents, source_line, source_offset, false, !inspection.empty);
        continuation = true;
    }
}

const CommandInspection = struct {
    errors: bool,
    incomplete: bool,
    empty: bool,
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
        const document = tree.hereDocument(@fromBackingInt(@intCast(index)));
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
        .empty = tree.errors.len == 0 and tree.status == .complete and
            tree.nodeData(.root).opt_node == .none,
        .ready_here_document_count = tree.ready_here_document_count,
        .here_documents = metadata,
    };
}

fn readHereDocument(
    self: *Shell,
    metadata: CommandInspection.HereDocumentMetadata,
    command: *Io.Writer.Allocating,
    original: *Io.Writer.Allocating,
    mappings: *std.ArrayList(habush.Source.Mapping),
) !?[]u8 {
    var body: Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();
    var pending: Io.Writer.Allocating = .init(self.allocator);
    defer pending.deinit();
    var delimiter_candidate: Io.Writer.Allocating = .init(self.allocator);
    defer delimiter_candidate.deinit();
    while (true) {
        if (self.interactive) try self.printPrompt(true);
        const line = try self.readInputLine("> ", "", false) orelse {
            body.deinit();
            return null;
        };
        defer self.allocator.free(line);
        try appendInputLine(self.allocator, command, original, mappings, line, self.last_line_ending, true);
        const stripped = habush.heredoc.lineAfterTabStripping(line, metadata.strip_tabs);
        try pending.writer.writeAll(stripped);
        try pending.writer.writeByte('\n');

        const continued = metadata.expand_body and habush.heredoc.hasLineContinuation(stripped);
        try delimiter_candidate.writer.writeAll(
            if (continued) stripped[0 .. stripped.len - 1] else stripped,
        );
        if (continued) continue;

        if (std.mem.eql(u8, delimiter_candidate.written(), metadata.delimiter))
            return try body.toOwnedSlice();
        try body.writer.writeAll(pending.written());
        pending.clearRetainingCapacity();
        delimiter_candidate.clearRetainingCapacity();
    }
}

fn readInputLine(self: *Shell, prompt: []const u8, prefix: []const u8, allow_completion: bool) !?[:0]u8 {
    const line = (try self.takeEditedLine()) orelse if (self.interactive and self.line_edit and self.io != null) editor: {
        self.last_line_ending = .lf;
        self.input_byte_offset = null;
        var native: habush.Completion.Native = .{
            .io = self.io.?,
            .cwd = self.session.workingDirectory(),
            .path = self.session.variable("PATH"),
            .default_search_path = self.session.defaultSearchPath(),
            .function_names = self.session.functionNames(),
            .executable_extensions = self.resolver_options.executable_extensions,
        };
        var registered: habush.Completion.Registered = .{ .session = self.session, .io = self.io.? };
        var providers: [3]habush.Completion.Provider = undefined;
        providers[0] = registered.provider();
        providers[1] = self.completion_provider orelse native.provider();
        if (self.completion_provider != null) providers[2] = native.provider();
        var completion: CompletionService = .{
            .gpa = self.allocator,
            .prefix = prefix,
            .providers = providers[0..if (self.completion_provider != null) @as(usize, 3) else 2],
            .limits = self.completion_limits,
        };
        defer completion.deinit();
        const submitted = ((LineEditor{
            .gpa = self.allocator,
            .input = self.stdin,
            .output = self.stderr,
            .prompt = prompt,
            .completion = if (allow_completion) completion.completion() else null,
            .history = if (allow_completion and prefix.len == 0 and self.editing != null) &self.editing.?.history else null,
        }).read() catch |err| switch (err) {
            error.EditorUnavailable => try readLineAlloc(self.stdin, self.allocator, &self.last_line_ending),
            error.EndOfStream => null,
            else => return err,
        }) orelse return null;
        if (self.editing) |editing| {
            editing.queued = submitted;
            break :editor (try self.takeEditedLine()).?;
        }
        break :editor submitted;
    } else try readLineAlloc(self.stdin, self.allocator, &self.last_line_ending) orelse return null;
    self.input_line += 1;
    if (self.input_byte_offset) |offset| {
        self.input_byte_offset = offset: {
            const len = std.math.cast(u32, line.len + self.last_line_ending.bytes().len) orelse break :offset null;
            break :offset std.math.add(u32, offset, len) catch null;
        };
    }
    return line;
}

/// Recalled/pasted input follows the same physical-line and here-document path
/// as typed input, without consuming stdin intended for a running command.
fn takeEditedLine(self: *Shell) !?[:0]u8 {
    if (!self.interactive) return null;
    const editing = self.editing orelse return null;
    const source = editing.queued orelse return null;
    const start = editing.offset;
    const end = std.mem.indexOfAnyPos(u8, source, start, "\r\n") orelse source.len;
    const line = try self.allocator.dupeSentinel(u8, source[start..end], 0);
    self.last_line_ending = .lf;
    editing.offset = end + 1;
    if (end < source.len and source[end] == '\r' and end + 1 < source.len and source[end + 1] == '\n') {
        self.last_line_ending = .crlf;
        editing.offset += 1;
    }
    if (editing.offset >= source.len) editing.discard();
    return line;
}

fn printPrompt(self: *Shell, continuation: bool) !void {
    if (!continuation) {
        if (self.integration) |*integration|
            try integration.beginPrompt(self.session.workingDirectory());
    }
    try self.stderr.writeAll(if (continuation) "> " else "habush> ");
    if (!continuation) {
        if (self.integration) |*integration| try integration.endPrompt();
    }
    try self.stderr.flush();
}

fn beginCommand(self: *Shell, emit: bool) !void {
    if (!self.interactive or !emit) return;
    if (self.integration) |*integration| try integration.beginCommand();
}

fn endCommand(self: *Shell, status: ?u8) !void {
    if (!self.interactive) return;
    if (self.integration) |*integration| try integration.endCommand(status);
}

fn handleInput(
    self: *Shell,
    source: [:0]const u8,
    collected_here_documents: []const habush.heredoc.Collected,
    source_name: ?[]const u8,
    source_line: usize,
    original_source: [:0]const u8,
    mappings: []const habush.Source.Mapping,
    source_offset: ?u32,
) !habush.runtime.ControlFlow {
    var evaluation = self.evaluate(source, .{
        .collected_here_documents = collected_here_documents,
        .source_name = source_name,
        .source_line_offset = source_line,
        .source_base_offset = source_offset,
        .original_source = original_source,
        .source_mappings = mappings,
    }) catch |err| switch (err) {
        error.Canceled => {
            if (self.editing) |editing| editing.discard();
            self.session.interruptInput();
            try self.stderr.writeByte('\n');
            return .none;
        },
        else => return err,
    };
    defer evaluation.deinit(self.session.allocator());
    switch (evaluation) {
        .syntax => |tree| {
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
            } else if (tree.status == .incomplete) {
                try self.stderr.writeAll("habush: incomplete input\n");
            }
            return if (self.interactive) .none else .exit;
        },
        .unsupported => |err| {
            try self.stderr.print("habush: unsupported runtime feature: {s}\n", .{
                @errorName(err),
            });
            return .none;
        },
        .executed => |result| return result.control_flow,
    }
}

fn evaluate(self: *Shell, source: [:0]const u8, options: habush.Session.EvaluateOptions) !habush.Evaluation {
    return self.withInterrupt(habush.Evaluation, habush.Session.evaluate, .{ self.session, source, options }, discardEvaluation, false);
}

fn discardInput(self: *Shell, value: ?CommandInput) void {
    var owned = value orelse return;
    owned.deinit(self.allocator);
}

fn discardEvaluation(self: *Shell, value: habush.Evaluation) void {
    var owned = value;
    owned.deinit(self.session.allocator());
}

/// Both tasks are joined before the caller touches the reader/session again.
/// A completed operation may own a result even when the interrupt wins.
fn withInterrupt(
    self: *Shell,
    comptime T: type,
    comptime operation: anytype,
    args: std.meta.ArgsTuple(@TypeOf(operation)),
    comptime discard: fn (*Shell, T) void,
    poll_background: bool,
) !T {
    if (!self.interruptible and !poll_background) return @call(.auto, operation, args);
    const io = self.io orelse return @call(.auto, operation, args);
    const Result = union(enum) {
        completed: @typeInfo(@TypeOf(operation)).@"fn".return_type.?,
        interrupted: std.Io.Cancelable!void,
        poll_failed: habush.Host.Error!void,
    };
    var storage: [3]Result = undefined;
    var pending: std.Io.Select(Result) = .init(io, &storage);
    defer while (pending.cancel()) |result| {
        if (result == .completed) {
            if (result.completed) |value| discard(self, value) else |_| {}
        }
    };
    try pending.concurrent(.completed, operation, args);
    if (self.interruptible)
        try pending.concurrent(.interrupted, interrupt.wait, .{ io, self.interrupt_generation });
    if (poll_background and self.session.host.capabilities().poll)
        try pending.concurrent(.poll_failed, pollJobs, .{self});
    return switch (try pending.await()) {
        .completed => |result| result,
        .interrupted => error.Canceled,
        .poll_failed => |result| {
            try result;
            unreachable;
        },
    };
}

// Only input waiting runs beside this task; evaluation owns the table itself.
fn pollJobs(self: *Shell) habush.Host.Error!void {
    const io = self.io.?;
    while (true) {
        try io.sleep(.fromMilliseconds(20), .awake);
        try self.session.jobs.poll();
    }
}

fn readLineAlloc(reader: *Io.Reader, allocator: std.mem.Allocator, ending: *LineEnding) !?[:0]u8 {
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
    ending.* = if (found_newline) .lf else .none;

    // CRLF
    if (written.len > 0 and written[written.len - 1] == '\r') {
        out.shrinkRetainingCapacity(written.len - 1);
        ending.* = if (found_newline) .crlf else .cr;
    }

    return try out.toOwnedSliceSentinel(0);
}

test "script diagnostics retain raw CRLF here-document and final-line byte ranges" {
    const Capture = struct {
        ranges: [3]?habush.Source.Range = undefined,
        count: usize = 0,
        correct_name: bool = true,

        fn report(userdata: ?*anyopaque, diagnostic: habush.runtime.Diagnostic) void {
            const capture: *@This() = @ptrCast(@alignCast(userdata.?));
            const location = diagnostic.source.?;
            capture.ranges[capture.count] = location.absoluteRange();
            capture.count += 1;
            capture.correct_name = capture.correct_name and std.mem.eql(u8, location.origin.?.name.?, "script.hb");
        }
    };
    const MissingResolver = struct {
        fn resolve(_: ?*anyopaque, _: std.mem.Allocator, _: habush.CommandResolver.Request) habush.CommandResolver.Error!?[]u8 {
            return null;
        }
    };
    var system: habush.Host.System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var capture: Capture = .{};
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var session = try habush.Session.init(std.testing.allocator, system.host(), .{
        .resolver = .{ .userdata = null, .vtable = &.{ .resolve = MissingResolver.resolve } },
        .context = .{ .io = .{
            .stderr = &stderr.writer,
            .diagnostic_sink = .{ .userdata = &capture, .report = Capture.report },
        } },
    });
    defer session.deinit();
    var reader: Io.Reader = .fixed("");
    var shell: Shell = .{
        .allocator = std.testing.allocator,
        .stdin = &reader,
        .stderr = &stderr.writer,
        .session = &session,
        .interactive = false,
    };
    const script = ":\r\n{\r\n : <<EOF\r\nlong body\r\nEOF\r\n missing\r\n}\r\nvalue=$(: <<EOF\r\ninner body\r\nEOF\r\ninner=$(missing_nested))\r\nmissing_final";
    try std.testing.expectEqual(@as(u8, 127), try shell.runSource(script, "script.hb"));
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expect(capture.correct_name);
    const first = std.mem.indexOf(u8, script, "missing").?;
    const nested = std.mem.indexOf(u8, script, "missing_nested").?;
    const last = std.mem.indexOf(u8, script, "missing_final").?;
    try std.testing.expectEqualDeep(habush.Source.Range{ .start = @intCast(first), .end = @intCast(first + 7) }, capture.ranges[0].?);
    try std.testing.expectEqualDeep(habush.Source.Range{ .start = @intCast(nested), .end = @intCast(nested + "missing_nested".len) }, capture.ranges[1].?);
    try std.testing.expectEqualDeep(habush.Source.Range{ .start = @intCast(last), .end = @intCast(script.len) }, capture.ranges[2].?);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "recalled compound input collects here-documents before execution" {
    const gpa = std.testing.allocator;
    var system: habush.Host.System = .{ .gpa = gpa, .io = std.testing.io };
    defer system.deinit();
    var session = try habush.Session.init(gpa, system.host(), .{});
    defer session.deinit();
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var reader: Io.Reader = .fixed("");
    const source = "{\n: <<'EOF'\nliteral $(missing)\nEOF\n}\n";
    var editing: Editing = .{
        .history = .{ .gpa = gpa },
        .queued = try gpa.dupeSentinel(u8, source, 0),
    };
    defer editing.discard();
    var shell: Shell = .{
        .allocator = gpa,
        .stdin = &reader,
        .stderr = &output.writer,
        .session = &session,
        .interactive = true,
        .editing = &editing,
    };
    var input = (try shell.readCommand()).?;
    defer input.deinit(gpa);
    try std.testing.expectEqualStrings(source, input.original_source);
    try std.testing.expectEqualStrings("literal $(missing)\n", input.here_documents[0].body);
    try std.testing.expect(editing.queued == null);
}

// NOTE: Zig's macOS stack unwinder can consume cancellation (also in 0.16):
// https://codeberg.org/ziglang/zig/pulls/36010
test "startup source stays interruptible without interactive presentation" {
    if (@import("builtin").target.os.tag == .macos and
        std.mem.eql(u8, std.testing.environ.getPosix("HABUSH_TEST_SKIP_ZIG_36010") orelse "", "1"))
    {
        std.debug.print("SKIP: startup cancellation check (Zig PR #36010)\n", .{});
        return error.SkipZigTest;
    }
    const Notify = struct {
        io: std.Io,
        started: std.Io.Event = .unset,

        fn observe(userdata: ?*anyopaque, event: habush.Session.Event) void {
            const notify: *@This() = @ptrCast(@alignCast(userdata.?));
            if (event == .started) notify.started.set(notify.io);
        }

        fn run(notify: *@This()) std.Io.Cancelable!void {
            try notify.started.wait(notify.io);
            interrupt.notify();
        }
    };
    var system: habush.Host.System = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer system.deinit();
    var notify: Notify = .{ .io = std.testing.io };
    var session = try habush.Session.init(std.testing.allocator, system.host(), .{
        .cancel_io = std.testing.io,
        .observer = .{ .userdata = &notify, .notify = Notify.observe },
    });
    defer session.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var reader: Io.Reader = .fixed("");
    var shell: Shell = .{
        .allocator = std.testing.allocator,
        .stdin = &reader,
        .stderr = &output.writer,
        .session = &session,
        .interactive = true,
        .interruptible = true,
        .io = std.testing.io,
    };
    var notifier = try std.testing.io.concurrent(Notify.run, .{&notify});
    defer notifier.cancel(std.testing.io) catch {};
    try std.testing.expectEqual(@as(u8, 130), try shell.runSource("while true; do :; done\n", "rc"));
    try std.testing.expect(shell.interactive);
    try std.testing.expectEqualStrings("\n", output.written());
}
