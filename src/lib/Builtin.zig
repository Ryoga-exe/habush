//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();
const ExecutionContext = @import("ExecutionContext.zig");
const Host = @import("Host.zig");
const runtime = @import("runtime.zig");
const VariableStore = @import("VariableStore.zig");

tag: Tag,
special: bool = false,
pipeline_support: PipelineSupport = .unsupported,

pub const Tag = enum {
    @":",
    @"break",
    @"continue",
    true,
    false,
    cd,
    exit,
    pwd,
    read,
    jobs,
    wait,
    fg,
    bg,
    @"return",
    shift,
    @"export",
    unset,
};

pub const PipelineSupport = enum {
    unsupported,
    /// The builtin does not consume pipeline input. It may write output after
    /// the downstream stage has been launched.
    no_stdin,
    /// The builtin may block on pipeline input, so it requires the single
    /// general in-process stage slot in the current pipeline executor.
    reads_stdin,
};

pub const Result = struct {
    status: runtime.ExitStatus,
    control_flow: runtime.ControlFlow = .none,
};

pub const Context = struct {
    host: ?Host = null,
    runtime_state: ?*runtime.State = null,
    /// Function-local positional parameters, borrowed for this call. A null
    /// pointer selects the persistent parameters in `runtime_state`.
    positional_parameters: ?*[]const []const u8 = null,
    jobs: ?*runtime.Jobs = null,
    execution_context: ExecutionContext.Ref = .{ .view = .{} },
    variable_overrides: ?*const VariableStore = null,
    io: runtime.Io = .{},
    last_status: runtime.ExitStatus = 0,
    loop_depth: u32 = 0,
    function_depth: u32 = 0,
};

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Reader.Error || Host.Error || error{
    HostUnavailable,
    RuntimeStateUnavailable,
    ExecutionContextUnavailable,
};

const definitions = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .tag = .@":", .special = true, .pipeline_support = .no_stdin } },
    .{ "break", Builtin{ .tag = .@"break", .special = true, .pipeline_support = .no_stdin } },
    .{ "continue", Builtin{ .tag = .@"continue", .special = true, .pipeline_support = .no_stdin } },
    .{ "true", Builtin{ .tag = .true, .pipeline_support = .no_stdin } },
    .{ "false", Builtin{ .tag = .false, .pipeline_support = .no_stdin } },
    .{ "cd", Builtin{ .tag = .cd, .pipeline_support = .no_stdin } },
    .{ "exit", Builtin{ .tag = .exit, .special = true, .pipeline_support = .no_stdin } },
    .{ "pwd", Builtin{ .tag = .pwd, .pipeline_support = .no_stdin } },
    .{ "read", Builtin{ .tag = .read, .pipeline_support = .reads_stdin } },
    .{ "jobs", Builtin{ .tag = .jobs, .pipeline_support = .no_stdin } },
    .{ "wait", Builtin{ .tag = .wait } },
    .{ "fg", Builtin{ .tag = .fg } },
    .{ "bg", Builtin{ .tag = .bg } },
    .{ "return", Builtin{ .tag = .@"return", .special = true, .pipeline_support = .no_stdin } },
    .{ "shift", Builtin{ .tag = .shift, .special = true, .pipeline_support = .no_stdin } },
    .{ "export", Builtin{ .tag = .@"export", .special = true, .pipeline_support = .no_stdin } },
    .{ "unset", Builtin{ .tag = .unset, .special = true, .pipeline_support = .no_stdin } },
});

pub fn lookup(name: []const u8) ?Builtin {
    return definitions.get(name);
}

pub fn supportsPipeline(builtin: Builtin) bool {
    return builtin.pipeline_support != .unsupported;
}

pub fn run(builtin: Builtin, context: Context, argv: []const []const u8) Error!Result {
    if (argv.len == 0) return .{ .status = 2 };
    return switch (builtin.tag) {
        .@":", .true => .{ .status = 0 },
        .@"break" => runLoopControl(context, argv, .@"break"),
        .@"continue" => runLoopControl(context, argv, .@"continue"),
        .false => .{ .status = 1 },
        .cd => runCd(context, argv),
        .exit => runExit(context, argv),
        .pwd => runPwd(context, argv),
        .read => runRead(context, argv),
        .jobs => runJobs(context, argv),
        .wait => runWait(context, argv),
        .fg => runJobControl(context, argv, true),
        .bg => runJobControl(context, argv, false),
        .@"return" => runReturn(context, argv),
        .shift => runShift(context, argv),
        .@"export" => runExport(context, argv),
        .unset => runUnset(context, argv),
    };
}

const LoopControl = enum {
    @"break",
    @"continue",
};

fn runLoopControl(
    context: Context,
    argv: []const []const u8,
    control: LoopControl,
) Error!Result {
    if (argv.len > 2) return commandFailure(context, argv[0], .too_many_arguments);
    const requested_levels = if (argv.len == 1)
        1
    else
        std.fmt.parseUnsigned(u32, argv[1], 10) catch
            return commandFailure(context, argv[0], .{ .invalid_loop_count = argv[1] });
    if (requested_levels == 0) {
        return commandFailure(context, argv[0], .{ .invalid_loop_count = argv[1] });
    }
    if (context.loop_depth == 0) return commandFailure(context, argv[0], .not_in_loop);

    const levels = @min(requested_levels, context.loop_depth);
    return switch (control) {
        .@"break" => .{ .status = 0, .control_flow = .{ .@"break" = levels } },
        .@"continue" => .{ .status = 0, .control_flow = .{ .@"continue" = levels } },
    };
}

fn runExit(context: Context, argv: []const []const u8) Error!Result {
    if (argv.len > 2) return commandFailure(context, argv[0], .too_many_arguments);
    if (argv.len == 1) {
        return .{ .status = context.last_status, .control_flow = .exit };
    }

    const value = std.fmt.parseInt(i64, argv[1], 10) catch {
        const failure = try commandFailure(
            context,
            argv[0],
            .{ .numeric_argument_required = argv[1] },
        );
        return .{ .status = failure.status, .control_flow = .exit };
    };
    // Shell statuses expose the low eight bits of a valid integer operand.
    const status: runtime.ExitStatus = @truncate(@as(u64, @bitCast(value)));
    return .{ .status = status, .control_flow = .exit };
}

fn runReturn(context: Context, argv: []const []const u8) Error!Result {
    if (argv.len > 2) return commandFailure(context, argv[0], .too_many_arguments);
    if (context.function_depth == 0)
        return commandFailure(context, argv[0], .not_in_function);
    if (argv.len == 1) {
        return .{ .status = context.last_status, .control_flow = .@"return" };
    }

    const value = std.fmt.parseInt(i64, argv[1], 10) catch {
        const failure = try commandFailure(
            context,
            argv[0],
            .{ .numeric_argument_required = argv[1] },
        );
        return .{ .status = failure.status, .control_flow = .@"return" };
    };
    const status: runtime.ExitStatus = @truncate(@as(u64, @bitCast(value)));
    return .{ .status = status, .control_flow = .@"return" };
}

fn runShift(context: Context, argv: []const []const u8) Error!Result {
    if (argv.len > 2) return commandFailure(context, argv[0], .too_many_arguments);
    const count = if (argv.len == 1) 1 else count: {
        const operand = argv[1];
        if (operand.len == 0)
            return commandFailure(context, argv[0], .{ .numeric_argument_required = operand });
        for (operand) |byte| {
            if (!std.ascii.isDigit(byte))
                return commandFailure(context, argv[0], .{ .numeric_argument_required = operand });
        }
        break :count std.fmt.parseUnsigned(usize, operand, 10) catch
            return commandFailure(context, argv[0], .shift_count_out_of_range);
    };
    const parameters = if (context.positional_parameters) |local|
        local.*
    else if (context.runtime_state) |state|
        state.positionalParameters()
    else
        return error.RuntimeStateUnavailable;
    if (count > parameters.len) return commandFailure(context, argv[0], .shift_count_out_of_range);
    if (count == 0) return .{ .status = 0 };

    if (context.positional_parameters) |local| {
        local.* = parameters[count..];
    } else {
        try context.runtime_state.?.setPositionalParameters(parameters[count..]);
    }
    return .{ .status = 0 };
}

fn runCd(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    const execution_context = switch (context.execution_context) {
        .mutable => |value| value,
        .view => return error.ExecutionContextUnavailable,
    };
    const host = context.host orelse return error.HostUnavailable;
    var operands = argv[1..];
    var write_directory = false;
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) {
        operands = operands[1..];
    } else if (operands.len != 0 and std.mem.eql(u8, operands[0], "-")) {
        write_directory = true;
    } else if (operands.len != 0 and operands[0].len != 0 and operands[0][0] == '-') {
        return commandFailure(context, argv[0], .{ .unsupported_option = operands[0] });
    }
    if (operands.len > 1) return commandFailure(context, argv[0], .too_many_arguments);

    const path = if (write_directory)
        variable(context, "OLDPWD") orelse
            return commandFailure(context, argv[0], .{ .variable_not_set = "OLDPWD" })
    else if (operands.len == 1)
        operands[0]
    else
        variable(context, "HOME") orelse
            return commandFailure(context, argv[0], .{ .variable_not_set = "HOME" });
    const resolved = host.resolveWorkingDirectory(state.allocator(), .{
        .current = execution_context.workingDirectory(),
        .path = path,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return commandFailure(
            context,
            argv[0],
            .{ .cannot_change_directory = path },
        ),
    };
    defer state.allocator().free(resolved);
    try state.changeWorkingDirectory(execution_context, resolved);
    if (write_directory) {
        if (context.io.stdout) |stdout| {
            try stdout.writeAll(resolved);
            try stdout.writeByte('\n');
        }
    }
    return .{ .status = 0 };
}

fn variable(context: Context, name: []const u8) ?[]const u8 {
    if (context.variable_overrides) |overrides|
        if (overrides.get(name)) |value| return value;
    if (context.runtime_state) |state| return state.variable(name);
    return null;
}

fn runPwd(context: Context, argv: []const []const u8) Error!Result {
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len != 0) {
        const kind: runtime.Diagnostic.Kind = if (operands[0].len != 0 and operands[0][0] == '-')
            .{ .unsupported_option = operands[0] }
        else
            .{ .unexpected_argument = operands[0] };
        return commandFailure(context, argv[0], kind);
    }

    const cwd = context.execution_context.get().cwd orelse
        return commandFailure(context, argv[0], .working_directory_unavailable);
    if (context.io.stdout) |stdout| {
        try stdout.writeAll(cwd);
        try stdout.writeByte('\n');
    }
    return .{ .status = 0 };
}

fn runRead(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var operand_index: usize = 1;
    var raw = false;
    while (operand_index < argv.len) : (operand_index += 1) {
        const operand = argv[operand_index];
        if (std.mem.eql(u8, operand, "--")) {
            operand_index += 1;
            break;
        }
        if (std.mem.eql(u8, operand, "-r")) {
            raw = true;
            continue;
        }
        if (operand.len != 0 and operand[0] == '-')
            return commandFailure(context, argv[0], .{ .unsupported_option = operand });
        break;
    }
    // A name is required by POSIX. REPLY is the usual shell extension for an
    // omitted name and keeps `read` useful at the interactive prompt.
    const use_reply = operand_index == argv.len;
    const names: []const []const u8 = if (use_reply)
        &.{"REPLY"}
    else
        argv[operand_index..];
    for (names) |name| {
        if (!VariableStore.isValidName(name))
            return commandFailure(context, argv[0], .{ .invalid_name = name });
    }

    var input: ReadInput = .{};
    defer input.deinit(state.allocator());
    const complete = if (context.io.stdin) |reader|
        try input.readLine(state.allocator(), reader, raw)
    else
        false;

    if (use_reply) {
        try setVariable(state, "REPLY", input.bytes.items);
        return .{ .status = if (complete) 0 else 1 };
    }

    const ifs = variable(context, "IFS") orelse " \t\n";
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(state.allocator());
    try values.ensureTotalCapacity(state.allocator(), names.len);
    var cursor: usize = 0;
    for (names, 0..) |_, index| {
        const value = if (index + 1 == names.len)
            input.remainingField(&cursor, ifs)
        else
            input.nextField(&cursor, ifs);
        values.appendAssumeCapacity(value);
    }
    // Split every field before updating variables: assigning to IFS itself
    // can invalidate the borrowed separator value.
    for (names, values.items) |name, value| try setVariable(state, name, value);
    return .{ .status = if (complete) 0 else 1 };
}

fn runJobs(context: Context, argv: []const []const u8) Error!Result {
    if (argv.len != 1) return commandFailure(context, argv[0], .too_many_arguments);
    const jobs = context.jobs orelse return .{ .status = 0 };
    try jobs.poll();
    if (context.io.stdout) |writer| {
        for (jobs.entries.items) |*entry| {
            try writer.print("[{d}] {s}\t{s}\n", .{
                @backingInt(entry.id),
                switch (entry.pipeline.state()) {
                    .running => "Running",
                    .stopped => "Stopped",
                    .completed => "Done",
                },
                entry.title,
            });
        }
    }
    return .{ .status = 0 };
}

fn runJobControl(context: Context, argv: []const []const u8, foreground: bool) Error!Result {
    if (argv.len > 2) return commandFailure(context, argv[0], .too_many_arguments);
    const jobs = context.jobs orelse return commandFailure(context, argv[0], .job_control_unavailable);
    const id = (if (argv.len == 1) jobs.latest() else jobs.resolve(argv[1])) orelse
        return commandFailure(context, argv[0], .{ .no_such_job = if (argv.len == 1) "current" else argv[1] });
    const status: runtime.ExitStatus = if (foreground)
        (jobs.foreground(id) catch |err| switch (err) {
            error.Unsupported, error.ResourceUnavailable, error.AccessDenied => return commandFailure(context, argv[0], .job_control_unavailable),
            else => return err,
        }) orelse 127
    else blk: {
        _ = jobs.signal(id, .cont) catch |err| switch (err) {
            error.Unsupported, error.AccessDenied => return commandFailure(context, argv[0], .job_control_unavailable),
            else => return err,
        };
        break :blk 0;
    };
    return .{ .status = status };
}

fn runWait(context: Context, argv: []const []const u8) Error!Result {
    const jobs = context.jobs orelse return .{ .status = if (argv.len == 1) 0 else 127 };
    if (argv.len == 1) return .{ .status = try jobs.waitAll() };
    var status: runtime.ExitStatus = 0;
    for (argv[1..]) |operand| {
        const id = jobs.resolve(operand) orelse {
            try context.io.reportDiagnostic(.{ .subject = .{ .command = argv[0] }, .kind = .{ .no_such_job = operand } });
            status = 127;
            continue;
        };
        status = (try jobs.wait(id)) orelse missing: {
            try context.io.reportDiagnostic(.{ .subject = .{ .command = argv[0] }, .kind = .{ .no_such_job = operand } });
            break :missing 127;
        };
    }
    return .{ .status = status };
}

const ReadInput = struct {
    bytes: std.ArrayList(u8) = .empty,
    escaped: std.ArrayList(bool) = .empty,

    fn deinit(input: *ReadInput, allocator: std.mem.Allocator) void {
        input.bytes.deinit(allocator);
        input.escaped.deinit(allocator);
    }

    /// Returns true only when a logical line ended with an unescaped newline.
    /// A partial final line still assigns its fields but gives read status 1.
    fn readLine(
        input: *ReadInput,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        raw: bool,
    ) (std.mem.Allocator.Error || std.Io.Reader.Error)!bool {
        var pending_escape = false;
        while (true) {
            const byte = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (!raw and pending_escape) {
                pending_escape = false;
                if (byte == '\n') continue;
                try input.append(allocator, byte, true);
                continue;
            }
            if (byte == '\n') return true;
            if (!raw and byte == '\\') {
                pending_escape = true;
                continue;
            }
            try input.append(allocator, byte, false);
        }
        if (pending_escape) try input.append(allocator, '\\', false);
        return false;
    }

    fn append(input: *ReadInput, allocator: std.mem.Allocator, byte: u8, is_escaped: bool) std.mem.Allocator.Error!void {
        try input.bytes.append(allocator, byte);
        try input.escaped.append(allocator, is_escaped);
    }

    fn nextField(input: ReadInput, cursor: *usize, ifs: []const u8) []const u8 {
        cursor.* = input.skipWhitespace(cursor.*, ifs);
        if (cursor.* == input.bytes.items.len) return "";
        if (input.separator(cursor.*, ifs) == .other) {
            cursor.* = input.skipWhitespace(cursor.* + 1, ifs);
            return "";
        }

        const start = cursor.*;
        while (cursor.* < input.bytes.items.len and input.separator(cursor.*, ifs) == .none)
            cursor.* += 1;
        const end = cursor.*;
        if (cursor.* < input.bytes.items.len) {
            const kind = input.separator(cursor.*, ifs);
            cursor.* = input.skipWhitespace(cursor.*, ifs);
            if (kind == .other or
                (cursor.* < input.bytes.items.len and input.separator(cursor.*, ifs) == .other))
            {
                cursor.* += 1;
                cursor.* = input.skipWhitespace(cursor.*, ifs);
            }
        }
        return input.bytes.items[start..end];
    }

    fn remainingField(input: ReadInput, cursor: *usize, ifs: []const u8) []const u8 {
        cursor.* = input.skipWhitespace(cursor.*, ifs);
        var next = cursor.*;
        const field = input.nextField(&next, ifs);
        if (next == input.bytes.items.len) return field;
        var end = input.bytes.items.len;
        while (end > cursor.* and input.separator(end - 1, ifs) == .whitespace)
            end -= 1;
        return input.bytes.items[cursor.*..end];
    }

    const Separator = enum { none, whitespace, other };

    fn separator(input: ReadInput, index: usize, ifs: []const u8) Separator {
        if (input.escaped.items[index] or std.mem.indexOfScalar(u8, ifs, input.bytes.items[index]) == null)
            return .none;
        return switch (input.bytes.items[index]) {
            ' ', '\t', '\n' => .whitespace,
            else => .other,
        };
    }

    fn skipWhitespace(input: ReadInput, start: usize, ifs: []const u8) usize {
        var index = start;
        while (index < input.bytes.items.len and input.separator(index, ifs) == .whitespace)
            index += 1;
        return index;
    }
};

fn runExport(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: runtime.ExitStatus = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len == 0) try writeExportedVariables(context.io.stdout, state.variableStore());
    for (operands) |operand| {
        if (operand.len != 0 and operand[0] == '-') {
            status = @max(status, try reportCommandDiagnostic(
                context,
                argv[0],
                .{ .unsupported_option = operand },
            ));
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, operand, '=');
        const name = if (equals) |index| operand[0..index] else operand;
        if (!VariableStore.isValidName(name)) {
            status = @max(status, try reportCommandDiagnostic(
                context,
                argv[0],
                .{ .invalid_name = name },
            ));
            continue;
        }
        if (equals) |index|
            try setVariable(state, name, operand[index + 1 ..]);
        try setVariableExported(state, name);
    }
    return .{ .status = status };
}

fn writeExportedVariables(
    optional_writer: ?*std.Io.Writer,
    variables: *const VariableStore,
) std.Io.Writer.Error!void {
    const writer = optional_writer orelse return;
    var iterator = variables.iterator();
    while (iterator.next()) |binding| {
        if (!binding.exported) continue;
        try writer.writeAll("export ");
        try writer.writeAll(binding.name);
        try writer.writeAll("=");
        try writeShellQuoted(writer, binding.value);
        try writer.writeByte('\n');
    }
}

fn writeShellQuoted(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('\'');
    var remaining = value;
    while (std.mem.indexOfScalar(u8, remaining, '\'')) |index| {
        try writer.writeAll(remaining[0..index]);
        try writer.writeAll("'\\''");
        remaining = remaining[index + 1 ..];
    }
    try writer.writeAll(remaining);
    try writer.writeByte('\'');
}

fn runUnset(context: Context, argv: []const []const u8) Error!Result {
    const state = context.runtime_state orelse return error.RuntimeStateUnavailable;
    var status: runtime.ExitStatus = 0;
    var operands = argv[1..];
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    for (operands) |name| {
        if (!VariableStore.isValidName(name)) {
            if (name.len != 0 and name[0] == '-') {
                status = @max(status, try reportCommandDiagnostic(
                    context,
                    argv[0],
                    .{ .unsupported_option = name },
                ));
            } else {
                status = @max(status, try reportCommandDiagnostic(
                    context,
                    argv[0],
                    .{ .invalid_name = name },
                ));
            }
            continue;
        }
        _ = state.unsetVariable(name);
    }
    return .{ .status = status };
}

fn setVariable(state: *runtime.State, name: []const u8, value: []const u8) Error!void {
    state.setVariable(name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

fn setVariableExported(state: *runtime.State, name: []const u8) Error!void {
    state.setVariableExported(name, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

fn commandFailure(
    context: Context,
    command: []const u8,
    kind: runtime.Diagnostic.Kind,
) Error!Result {
    return .{ .status = try reportCommandDiagnostic(context, command, kind) };
}

fn reportCommandDiagnostic(
    context: Context,
    command: []const u8,
    kind: runtime.Diagnostic.Kind,
) std.Io.Writer.Error!runtime.ExitStatus {
    const diagnostic: runtime.Diagnostic = .{
        .subject = .{ .command = command },
        .kind = kind,
    };
    try context.io.reportDiagnostic(diagnostic);
    return diagnostic.status();
}

test "looks up core builtins by command name" {
    try std.testing.expect(lookup("exit").?.special);
    try std.testing.expect(lookup("break").?.special);
    try std.testing.expect(lookup("continue").?.special);
    try std.testing.expect(lookup("return").?.special);
    try std.testing.expect(!lookup("true").?.special);
    try std.testing.expect(lookup("missing") == null);
    try std.testing.expect(lookup("./true") == null);
    try std.testing.expect(lookup(":").?.supportsPipeline());
    try std.testing.expect(lookup("true").?.supportsPipeline());
    try std.testing.expect(lookup("false").?.supportsPipeline());
    try std.testing.expect(lookup("pwd").?.supportsPipeline());
    try std.testing.expect(lookup("read").?.supportsPipeline());
    try std.testing.expectEqual(PipelineSupport.reads_stdin, lookup("read").?.pipeline_support);
    try std.testing.expect(lookup("cd").?.supportsPipeline());
    try std.testing.expect(lookup("export").?.supportsPipeline());
    try std.testing.expect(lookup("unset").?.supportsPipeline());
    try std.testing.expect(lookup("exit").?.supportsPipeline());
    try std.testing.expect(lookup("return").?.supportsPipeline());
    try std.testing.expect(lookup("break").?.supportsPipeline());
    try std.testing.expect(lookup("continue").?.supportsPipeline());
}

test "runs status-only core builtins" {
    try std.testing.expectEqual(@as(u8, 0), (try lookup(":").?.run(.{}, &.{":"})).status);
    try std.testing.expectEqual(@as(u8, 0), (try lookup("true").?.run(.{}, &.{"true"})).status);
    try std.testing.expectEqual(@as(u8, 1), (try lookup("false").?.run(.{}, &.{"false"})).status);
}

test "shift updates positional parameters and leaves failures unchanged" {
    var state = try runtime.State.init(std.testing.allocator, .{
        .invocation_name = "script",
        .positional_parameters = &.{ "one", "two", "three" },
    });
    defer state.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{ .runtime_state = &state, .io = .{ .stderr = &diagnostics.writer } };
    const builtin = lookup("shift").?;
    try std.testing.expect(builtin.special);
    try std.testing.expect(builtin.supportsPipeline());

    try std.testing.expectEqual(@as(u8, 0), (try builtin.run(context, &.{"shift"})).status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "two", "three" }), state.positionalParameters());
    try std.testing.expectEqualStrings("script", state.invocationName());
    try std.testing.expectEqual(@as(u8, 0), (try builtin.run(context, &.{ "shift", "0" })).status);
    try std.testing.expectEqual(@as(u8, 1), (try builtin.run(context, &.{ "shift", "3" })).status);
    try std.testing.expectEqual(@as(u8, 2), (try builtin.run(context, &.{ "shift", "-1" })).status);
    try std.testing.expectEqual(@as(u8, 2), (try builtin.run(context, &.{ "shift", "1", "2" })).status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "two", "three" }), state.positionalParameters());

    var local: []const []const u8 = &.{ "local", "tail" };
    var function_context = context;
    function_context.positional_parameters = &local;
    try std.testing.expectEqual(@as(u8, 0), (try builtin.run(function_context, &.{"shift"})).status);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"tail"}), local);
    try std.testing.expectEqual(@as(usize, 2), state.positionalParameters().len);
    try std.testing.expectEqual(@as(u8, 0), (try builtin.run(context, &.{ "shift", "2" })).status);
    try std.testing.expectEqual(@as(usize, 0), state.positionalParameters().len);
}

test "read splits IFS fields and assigns the remaining input to the last name" {
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    try state.setVariable("IFS", ":");
    var input: std.Io.Reader = .fixed("first:second:third\nnext:tail\n  reply  \n");
    const context: Context = .{ .runtime_state = &state, .io = .{ .stdin = &input } };

    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{ "read", "FIRST", "REST" },
    )).status);
    try std.testing.expectEqualStrings("first", state.variable("FIRST").?);
    try std.testing.expectEqualStrings("second:third", state.variable("REST").?);

    // The input is read through the same reader on the next invocation.
    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{ "read", "NEXT" },
    )).status);
    try std.testing.expectEqualStrings("next:tail", state.variable("NEXT").?);

    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{"read"},
    )).status);
    try std.testing.expectEqualStrings("  reply  ", state.variable("REPLY").?);
}

test "read drops a final IFS delimiter only when no surplus fields remain" {
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    try state.setVariable("IFS", ": ");
    const cases = .{
        .{ "a:b:\n", "b" },
        .{ "a:b:  \n", "b" },
        .{ "a:b::\n", "b::" },
        .{ "a:b:c:\n", "b:c:" },
        .{ "a::\n", "" },
        .{ "a:b\\:\n", "b:" },
    };
    inline for (cases) |case| {
        var input: std.Io.Reader = .fixed(case[0]);
        const result = try lookup("read").?.run(.{
            .runtime_state = &state,
            .io = .{ .stdin = &input },
        }, &.{ "read", "FIRST", "LAST" });
        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expectEqualStrings(case[1], state.variable("LAST").?);
    }
}

test "read preserves variables on an input failure" {
    const Failing = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    try state.setVariable("value", "original");
    var buffer: [1]u8 = undefined;
    var input: std.Io.Reader = .{ .vtable = &.{ .stream = Failing.stream }, .buffer = &buffer, .seek = 0, .end = 0 };
    try std.testing.expectError(error.ReadFailed, lookup("read").?.run(.{
        .runtime_state = &state,
        .io = .{ .stdin = &input },
    }, &.{ "read", "value" }));
    try std.testing.expectEqualStrings("original", state.variable("value").?);
}

test "read handles escaped separators, raw input, continuation, and partial EOF" {
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    var input: std.Io.Reader = .fixed("a\\ b c\nnext\\\ncontinued word\nraw\\ text\npartial");
    const context: Context = .{ .runtime_state = &state, .io = .{ .stdin = &input } };

    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{ "read", "FIRST", "SECOND" },
    )).status);
    try std.testing.expectEqualStrings("a b", state.variable("FIRST").?);
    try std.testing.expectEqualStrings("c", state.variable("SECOND").?);

    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{ "read", "CONTINUED", "WORD" },
    )).status);
    try std.testing.expectEqualStrings("nextcontinued", state.variable("CONTINUED").?);
    try std.testing.expectEqualStrings("word", state.variable("WORD").?);

    try std.testing.expectEqual(@as(u8, 0), (try lookup("read").?.run(
        context,
        &.{ "read", "-r", "RAW", "TAIL" },
    )).status);
    try std.testing.expectEqualStrings("raw\\", state.variable("RAW").?);
    try std.testing.expectEqualStrings("text", state.variable("TAIL").?);

    try std.testing.expectEqual(@as(u8, 1), (try lookup("read").?.run(
        context,
        &.{ "read", "PARTIAL" },
    )).status);
    try std.testing.expectEqualStrings("partial", state.variable("PARTIAL").?);
}

test "break and continue request loop control" {
    const context: Context = .{ .loop_depth = 3 };

    const break_result = try lookup("break").?.run(context, &.{ "break", "2" });
    try std.testing.expectEqual(@as(u8, 0), break_result.status);
    switch (break_result.control_flow) {
        .@"break" => |levels| try std.testing.expectEqual(@as(u32, 2), levels),
        else => return error.TestUnexpectedResult,
    }

    const continue_result = try lookup("continue").?.run(context, &.{ "continue", "9" });
    try std.testing.expectEqual(@as(u8, 0), continue_result.status);
    switch (continue_result.control_flow) {
        .@"continue" => |levels| try std.testing.expectEqual(@as(u32, 3), levels),
        else => return error.TestUnexpectedResult,
    }
}

test "break and continue diagnose invalid contexts and operands" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{ .io = .{ .stderr = &diagnostics.writer } };

    const outside = try lookup("break").?.run(context, &.{"break"});
    try std.testing.expectEqual(@as(u8, 1), outside.status);
    try std.testing.expect(outside.control_flow.isNone());

    const zero = try lookup("continue").?.run(context, &.{ "continue", "0" });
    try std.testing.expectEqual(@as(u8, 2), zero.status);
    try std.testing.expect(zero.control_flow.isNone());

    const non_numeric = try lookup("break").?.run(context, &.{ "break", "many" });
    try std.testing.expectEqual(@as(u8, 2), non_numeric.status);
    try std.testing.expect(non_numeric.control_flow.isNone());

    try std.testing.expectEqualStrings(
        "break: not in a loop\n" ++
            "continue: invalid loop count: 0\n" ++
            "break: invalid loop count: many\n",
        diagnostics.written(),
    );
}

test "exit requests shell termination with selected status" {
    const inherited = try lookup("exit").?.run(.{ .last_status = 23 }, &.{"exit"});
    try std.testing.expectEqual(@as(u8, 23), inherited.status);
    try std.testing.expectEqual(runtime.ControlFlow.exit, inherited.control_flow);

    const explicit = try lookup("exit").?.run(.{}, &.{ "exit", "7" });
    try std.testing.expectEqual(@as(u8, 7), explicit.status);
    try std.testing.expectEqual(runtime.ControlFlow.exit, explicit.control_flow);

    const truncated = try lookup("exit").?.run(.{}, &.{ "exit", "1010101010" });
    try std.testing.expectEqual(@as(u8, 18), truncated.status);
    try std.testing.expectEqual(runtime.ControlFlow.exit, truncated.control_flow);

    const negative = try lookup("exit").?.run(.{}, &.{ "exit", "-1" });
    try std.testing.expectEqual(@as(u8, 255), negative.status);
    try std.testing.expectEqual(runtime.ControlFlow.exit, negative.control_flow);
}

test "exit diagnoses invalid operands" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{ .io = .{ .stderr = &diagnostics.writer } };

    const invalid = try lookup("exit").?.run(
        context,
        &.{ "exit", "999999999999999999999999999999" },
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.status);
    try std.testing.expectEqual(runtime.ControlFlow.exit, invalid.control_flow);

    const too_many = try lookup("exit").?.run(context, &.{ "exit", "1", "2" });
    try std.testing.expectEqual(@as(u8, 2), too_many.status);
    try std.testing.expectEqual(runtime.ControlFlow.none, too_many.control_flow);
    try std.testing.expectEqualStrings(
        "exit: numeric argument required: 999999999999999999999999999999\n" ++
            "exit: too many arguments\n",
        diagnostics.written(),
    );
}

test "return requests function completion with selected status" {
    const context: Context = .{ .function_depth = 1, .last_status = 23 };

    const inherited = try lookup("return").?.run(context, &.{"return"});
    try std.testing.expectEqual(@as(u8, 23), inherited.status);
    try std.testing.expectEqual(runtime.ControlFlow.@"return", inherited.control_flow);

    const explicit = try lookup("return").?.run(context, &.{ "return", "257" });
    try std.testing.expectEqual(@as(u8, 1), explicit.status);
    try std.testing.expectEqual(runtime.ControlFlow.@"return", explicit.control_flow);

    const negative = try lookup("return").?.run(context, &.{ "return", "-1" });
    try std.testing.expectEqual(@as(u8, 255), negative.status);
    try std.testing.expectEqual(runtime.ControlFlow.@"return", negative.control_flow);
}

test "return diagnoses invalid contexts and operands" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const outside_context: Context = .{ .io = .{ .stderr = &diagnostics.writer } };

    const outside = try lookup("return").?.run(outside_context, &.{"return"});
    try std.testing.expectEqual(@as(u8, 1), outside.status);
    try std.testing.expect(outside.control_flow.isNone());

    const function_context: Context = .{
        .function_depth = 1,
        .io = .{ .stderr = &diagnostics.writer },
    };
    const invalid = try lookup("return").?.run(
        function_context,
        &.{ "return", "not-a-number" },
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.status);
    try std.testing.expectEqual(runtime.ControlFlow.@"return", invalid.control_flow);

    try std.testing.expectEqualStrings(
        "return: not in a function\n" ++
            "return: numeric argument required: not-a-number\n",
        diagnostics.written(),
    );
}

test "export and unset mutate runtime state" {
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    const context: Context = .{ .runtime_state = &state };

    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("export").?.run(context, &.{ "export", "NAME=value", "EMPTY" })).status,
    );
    try std.testing.expectEqualStrings("value", state.variable("NAME").?);
    try std.testing.expect(state.isVariableExported("NAME"));
    try std.testing.expectEqualStrings("", state.variable("EMPTY").?);
    try std.testing.expect(state.isVariableExported("EMPTY"));

    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("unset").?.run(context, &.{ "unset", "NAME", "missing" })).status,
    );
    try std.testing.expect(state.variable("NAME") == null);
}

test "export without operands writes exported variables" {
    var state = try runtime.State.init(std.testing.allocator, .{
        .variables = &.{
            .{ .name = "PLAIN", .value = "value", .exported = true },
            .{ .name = "LOCAL", .value = "hidden" },
            .{ .name = "QUOTED", .value = "one'two", .exported = true },
        },
    });
    defer state.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const result = try lookup("export").?.run(.{
        .runtime_state = &state,
        .io = .{ .stdout = &output.writer },
    }, &.{"export"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings(
        \\export PLAIN='value'
        \\export QUOTED='one'\''two'
        \\
    , output.written());
    var buffer: [1]u8 = undefined;
    var failing_output: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, lookup("export").?.run(.{
        .runtime_state = &state,
        .io = .{ .stdout = &failing_output },
    }, &.{"export"}));
}

test "stateful builtins report invalid operands as command status" {
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .runtime_state = &state,
        .io = .{ .stderr = &diagnostics.writer },
    };

    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("export").?.run(context, &.{ "export", "not-valid" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("unset").?.run(context, &.{ "unset", "-f" })).status,
    );
    try std.testing.expectEqualStrings(
        \\export: invalid name: not-valid
        \\unset: unsupported option: -f
        \\
    , diagnostics.written());
    try std.testing.expectError(
        error.RuntimeStateUnavailable,
        lookup("export").?.run(.{}, &.{ "export", "NAME" }),
    );
}

test "cd resolves and persists the working directory" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/workspace/project";
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    var execution_context = try ExecutionContext.init(std.testing.allocator, .{ .cwd = "/workspace" });
    defer execution_context.deinit();

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .execution_context = .{ .mutable = &execution_context },
    }, &.{ "cd", "project" });

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace/project", execution_context.workingDirectory().?);
    const request = fake.resolve_working_directory_calls.items[0];
    try std.testing.expectEqualStrings("/workspace", request.current.?);
    try std.testing.expectEqualStrings("project", request.path);
}

test "cd uses command-local HOME without persisting it" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/temporary";
    var state = try runtime.State.init(std.testing.allocator, .{
        .variables = &.{.{ .name = "HOME", .value = "/home/user" }},
    });
    defer state.deinit();
    var execution_context = try ExecutionContext.init(std.testing.allocator, .{});
    defer execution_context.deinit();
    var overrides = VariableStore.init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.set("HOME", "/temporary");

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .execution_context = .{ .mutable = &execution_context },
        .variable_overrides = &overrides,
    }, &.{"cd"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/temporary", execution_context.workingDirectory().?);
    try std.testing.expectEqualStrings("/home/user", state.variable("HOME").?);
    try std.testing.expectEqualStrings(
        "/temporary",
        fake.resolve_working_directory_calls.items[0].path,
    );
}

test "cd updates directory variables and dash uses OLDPWD" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.working_directory_result = "/previous";
    var state = try runtime.State.init(std.testing.allocator, .{
        .variables = &.{
            .{ .name = "PWD", .value = "/current", .exported = true },
            .{ .name = "OLDPWD", .value = "/previous", .exported = true },
        },
    });
    defer state.deinit();
    var execution_context = try ExecutionContext.init(std.testing.allocator, .{ .cwd = "/current" });
    defer execution_context.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const result = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .execution_context = .{ .mutable = &execution_context },
        .io = .{ .stdout = &output.writer },
    }, &.{ "cd", "-" });

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/previous", execution_context.workingDirectory().?);
    try std.testing.expectEqualStrings("/previous", state.variable("PWD").?);
    try std.testing.expectEqualStrings("/current", state.variable("OLDPWD").?);
    try std.testing.expect(state.isVariableExported("PWD"));
    try std.testing.expect(state.isVariableExported("OLDPWD"));
    try std.testing.expectEqualStrings("/previous\n", output.written());
    try std.testing.expectEqualStrings(
        "/previous",
        fake.resolve_working_directory_calls.items[0].path,
    );
}

test "cd reports usage and host failures as command status" {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(std.testing.allocator);
    defer fake.deinit();
    fake.resolve_working_directory_error = error.AccessDenied;
    var state = try runtime.State.init(std.testing.allocator, .{});
    defer state.deinit();
    var execution_context = try ExecutionContext.init(std.testing.allocator, .{});
    defer execution_context.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .host = fake.host(),
        .runtime_state = &state,
        .execution_context = .{ .mutable = &execution_context },
        .io = .{ .stderr = &diagnostics.writer },
    };

    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("cd").?.run(context, &.{ "cd", "one", "two" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("cd").?.run(context, &.{ "cd", "/denied" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        (try lookup("cd").?.run(context, &.{"cd"})).status,
    );
    try std.testing.expectEqualStrings(
        \\cd: too many arguments
        \\cd: cannot change directory: /denied
        \\cd: HOME not set
        \\
    , diagnostics.written());
}

test "pwd writes the logical working directory" {
    var execution_context = try ExecutionContext.init(std.testing.allocator, .{ .cwd = "/workspace/project" });
    defer execution_context.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const context: Context = .{
        .execution_context = .{ .view = execution_context.view() },
        .io = .{
            .stdout = &output.writer,
            .stderr = &diagnostics.writer,
        },
    };

    const result = try lookup("pwd").?.run(context, &.{"pwd"});

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("/workspace/project\n", output.written());
    try std.testing.expectEqual(
        @as(u8, 0),
        (try lookup("pwd").?.run(context, &.{ "pwd", "--" })).status,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        (try lookup("pwd").?.run(context, &.{ "pwd", "-P" })).status,
    );
    try std.testing.expectEqualStrings("pwd: unsupported option: -P\n", diagnostics.written());
    var buffer: [1]u8 = undefined;
    var failing_diagnostics: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WriteFailed, lookup("pwd").?.run(.{
        .execution_context = .{ .view = execution_context.view() },
        .io = .{ .stderr = &failing_diagnostics },
    }, &.{ "pwd", "-P" }));
}

test "cd execution handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runCdWithAllocator,
        .{},
    );
}

fn runCdWithAllocator(gpa: std.mem.Allocator) !void {
    const FakeHost = @import("Host/FakeHost.zig");
    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    fake.working_directory_result = "/workspace/project";
    var state = try runtime.State.init(gpa, .{});
    defer state.deinit();
    var execution_context = try ExecutionContext.init(gpa, .{ .cwd = "/workspace" });
    defer execution_context.deinit();

    _ = try lookup("cd").?.run(.{
        .host = fake.host(),
        .runtime_state = &state,
        .execution_context = .{ .mutable = &execution_context },
    }, &.{ "cd", "project" });
}

test {
    std.testing.refAllDecls(@This());
}
