//! Context-sensitive expansion of HIR words.
//!
//! This stage performs current-user tilde expansion, parameter expansion,
//! field splitting, and quote removal. Pathname expansion, named-user tilde
//! expansion, and parameter transformations such as `${#name}` remain
//! explicit unsupported boundaries.

const std = @import("std");
const Expander = @This();
const Hir = @import("Hir.zig");
const runtime_types = @import("runtime/types.zig");
const VariableStore = @import("VariableStore.zig");
const Word = @import("word.zig");

allocator: std.mem.Allocator,
context: Context,

pub const Context = struct {
    variables: ?*VariableStore = null,
    overrides: ?*const VariableStore = null,
    invocation_name: ?[]const u8 = null,
    shell_process_id: ?runtime_types.ProcessId = null,
    positional_parameters: []const []const u8 = &.{},
    last_status: runtime_types.ExitStatus = 0,
    failure: ?*Failure = null,

    fn variable(context: Context, name: []const u8) ?[]const u8 {
        if (context.overrides) |overrides| {
            if (overrides.get(name)) |value| return value;
        }
        if (context.variables) |variables| return variables.get(name);
        return null;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    ParameterAssignmentUnavailable,
    ParameterExpansionFailed,
    ParameterExpansionUnsupported,
    PathnameExpansionUnsupported,
    TildeExpansionUnsupported,
};

pub const Failure = struct {
    parameter: []const u8,
    message: []const u8,
    owns_message: bool = false,

    pub fn deinit(failure: Failure, allocator: std.mem.Allocator) void {
        if (failure.owns_message) allocator.free(failure.message);
    }
};

pub fn init(allocator: std.mem.Allocator) Expander {
    return initWithContext(allocator, .{});
}

pub fn initWithContext(allocator: std.mem.Allocator, context: Context) Expander {
    return .{ .allocator = allocator, .context = context };
}

/// Expands one argument word to zero or more fields.
///
/// Returned slices are owned by `allocator`.
pub fn expandArgument(
    expander: Expander,
    hir: Hir,
    word: Hir.Inst.Index,
) Error![]const []const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(expander.allocator);
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| expander.allocator.free(field);
        fields.deinit(expander.allocator);
    }
    var current_field_active = false;
    for (hir.wordParts(word), 0..) |part, part_index| {
        const tag = hir.instructionTag(part);
        const value = hir.wordPart(part);
        try expander.appendArgumentPart(
            hirPartTag(tag),
            value,
            part_index == 0,
            false,
            false,
            &fields,
            &bytes,
            &current_field_active,
        );
    }

    if (current_field_active) try finishField(expander.allocator, &fields, &bytes);
    return fields.toOwnedSlice(expander.allocator);
}

/// Expands an assignment value without field splitting or pathname expansion.
///
/// The returned slice is owned by `allocator`.
pub fn expandAssignment(
    expander: Expander,
    hir: Hir,
    word: Hir.Inst.Index,
) Error![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(expander.allocator);
    for (hir.wordParts(word), 0..) |part, part_index| {
        const tag = hir.instructionTag(part);
        const value = hir.wordPart(part);
        try expander.appendAssignmentPart(
            hirPartTag(tag),
            value,
            part_index == 0,
            &bytes,
        );
    }
    return bytes.toOwnedSlice(expander.allocator);
}

fn appendArgumentPart(
    expander: Expander,
    tag: Word.Part.Tag,
    value: []const u8,
    is_first: bool,
    force_quoted: bool,
    expansion_word: bool,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    switch (tag) {
        .literal => {
            if (!force_quoted and std.mem.indexOfAny(u8, value, "*?[") != null)
                return error.PathnameExpansionUnsupported;
            if (!force_quoted and is_first and std.mem.startsWith(u8, value, "~")) {
                try expander.appendTilde(bytes, value);
                current_field_active.* = true;
                return;
            }
            if (force_quoted or !expansion_word) {
                try bytes.appendSlice(expander.allocator, value);
                current_field_active.* = true;
            } else {
                try expander.appendFieldSplit(fields, bytes, current_field_active, value);
            }
        },
        .escaped,
        .single_quoted,
        .double_quoted,
        .double_quoted_escaped,
        => {
            try bytes.appendSlice(expander.allocator, value);
            current_field_active.* = true;
        },
        .parameter => try expander.appendArgumentParameter(
            value,
            force_quoted,
            fields,
            bytes,
            current_field_active,
        ),
        .braced_parameter => try expander.appendBracedArgumentParameter(
            value,
            force_quoted,
            fields,
            bytes,
            current_field_active,
        ),
        .double_quoted_parameter => try expander.appendArgumentParameter(
            value,
            true,
            fields,
            bytes,
            current_field_active,
        ),
        .double_quoted_braced_parameter => try expander.appendBracedArgumentParameter(
            value,
            true,
            fields,
            bytes,
            current_field_active,
        ),
    }
}

fn appendArgumentParameter(
    expander: Expander,
    parameter: []const u8,
    quoted: bool,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    if (std.mem.eql(u8, parameter, "@")) {
        if (quoted) {
            try expander.appendQuotedAt(fields, bytes, current_field_active);
        } else {
            try expander.appendUnquotedAt(fields, bytes, current_field_active);
        }
        return;
    }
    if (quoted) {
        try expander.appendParameter(bytes, parameter);
        current_field_active.* = true;
        return;
    }

    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(expander.allocator);
    try expander.appendParameter(&expanded, parameter);
    try expander.appendFieldSplit(fields, bytes, current_field_active, expanded.items);
}

fn appendBracedArgumentParameter(
    expander: Expander,
    source: []const u8,
    quoted: bool,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    const expansion = Word.ParameterExpansion.parse(source) orelse
        return error.ParameterExpansionUnsupported;
    if (expansion.operator == null)
        return expander.appendArgumentParameter(
            expansion.parameter,
            quoted,
            fields,
            bytes,
            current_field_active,
        );
    switch (try expander.selectParameterExpansion(expansion)) {
        .value => |value| return expander.appendScalarArgument(
            value,
            quoted,
            fields,
            bytes,
            current_field_active,
        ),
        .empty => {
            if (quoted) current_field_active.* = true;
        },
        .word => |replacement| {
            if (replacement.len == 0 and quoted) {
                current_field_active.* = true;
                return;
            }
            try expander.appendExpansionWord(
                replacement,
                quoted,
                fields,
                bytes,
                current_field_active,
            );
        },
        .assign => |replacement| {
            const assigned = try expander.assignParameter(
                expansion.parameter,
                replacement,
                quoted,
            );
            defer expander.allocator.free(assigned);
            try expander.appendScalarArgument(
                assigned,
                quoted,
                fields,
                bytes,
                current_field_active,
            );
        },
        .fail => try expander.failParameter(expansion, quoted),
    }
}

fn appendScalarArgument(
    expander: Expander,
    value: []const u8,
    quoted: bool,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    if (quoted) {
        try bytes.appendSlice(expander.allocator, value);
        current_field_active.* = true;
    } else {
        try expander.appendFieldSplit(fields, bytes, current_field_active, value);
    }
}

fn appendExpansionWord(
    expander: Expander,
    source: []const u8,
    force_quoted: bool,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    var iterator = Word.Iterator.initExpansionWord(source, 0, force_quoted);
    var part_index: usize = 0;
    while (iterator.next()) |part| : (part_index += 1) {
        try expander.appendArgumentPart(
            part.tag,
            source[part.start..part.end],
            part_index == 0,
            force_quoted,
            true,
            fields,
            bytes,
            current_field_active,
        );
    }
    if (iterator.status != .complete) return error.ParameterExpansionUnsupported;
}

fn appendAssignmentPart(
    expander: Expander,
    tag: Word.Part.Tag,
    value: []const u8,
    is_first: bool,
    bytes: *std.ArrayList(u8),
) Error!void {
    switch (tag) {
        .literal => {
            if (is_first and std.mem.startsWith(u8, value, "~"))
                return expander.appendTilde(bytes, value);
            try bytes.appendSlice(expander.allocator, value);
        },
        .escaped,
        .single_quoted,
        .double_quoted,
        .double_quoted_escaped,
        => try bytes.appendSlice(expander.allocator, value),
        .parameter, .double_quoted_parameter => try expander.appendParameter(bytes, value),
        .braced_parameter => try expander.appendBracedAssignmentParameter(bytes, value, false),
        .double_quoted_braced_parameter => try expander.appendBracedAssignmentParameter(
            bytes,
            value,
            true,
        ),
    }
}

fn appendBracedAssignmentParameter(
    expander: Expander,
    bytes: *std.ArrayList(u8),
    source: []const u8,
    quoted: bool,
) Error!void {
    const expansion = Word.ParameterExpansion.parse(source) orelse
        return error.ParameterExpansionUnsupported;
    if (expansion.operator == null)
        return expander.appendParameter(bytes, expansion.parameter);
    switch (try expander.selectParameterExpansion(expansion)) {
        .value => |value| try bytes.appendSlice(expander.allocator, value),
        .empty => {},
        .word => |replacement| {
            try expander.appendExpansionWordScalar(bytes, replacement, quoted);
        },
        .assign => |replacement| {
            const assigned = try expander.assignParameter(
                expansion.parameter,
                replacement,
                quoted,
            );
            defer expander.allocator.free(assigned);
            try bytes.appendSlice(expander.allocator, assigned);
        },
        .fail => try expander.failParameter(expansion, quoted),
    }
}

fn appendExpansionWordScalar(
    expander: Expander,
    bytes: *std.ArrayList(u8),
    source: []const u8,
    quoted: bool,
) Error!void {
    var iterator = Word.Iterator.initExpansionWord(source, 0, quoted);
    var part_index: usize = 0;
    while (iterator.next()) |part| : (part_index += 1) {
        try expander.appendAssignmentPart(
            part.tag,
            source[part.start..part.end],
            part_index == 0,
            bytes,
        );
    }
    if (iterator.status != .complete) return error.ParameterExpansionUnsupported;
}

fn assignParameter(
    expander: Expander,
    parameter: []const u8,
    replacement: []const u8,
    quoted: bool,
) Error![]u8 {
    if (!VariableStore.isValidName(parameter)) return error.ParameterExpansionUnsupported;
    const variables = expander.context.variables orelse
        return error.ParameterAssignmentUnavailable;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(expander.allocator);
    try expander.appendExpansionWordScalar(&bytes, replacement, quoted);
    const value = try bytes.toOwnedSlice(expander.allocator);
    errdefer expander.allocator.free(value);
    variables.set(parameter, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => unreachable,
    };
    return value;
}

fn failParameter(
    expander: Expander,
    expansion: Word.ParameterExpansion,
    quoted: bool,
) Error!void {
    const default_message = switch (expansion.operator.?) {
        .error_if_unset => "parameter not set",
        .error_if_unset_or_null => "parameter null or not set",
        else => unreachable,
    };
    var failure: Failure = .{
        .parameter = expansion.parameter,
        .message = default_message,
    };
    if (expansion.word.len != 0) {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(expander.allocator);
        try expander.appendExpansionWordScalar(&bytes, expansion.word, quoted);
        failure.message = try bytes.toOwnedSlice(expander.allocator);
        failure.owns_message = true;
    }
    if (expander.context.failure) |destination| {
        destination.* = failure;
    } else {
        failure.deinit(expander.allocator);
    }
    return error.ParameterExpansionFailed;
}

fn appendParameter(
    expander: Expander,
    bytes: *std.ArrayList(u8),
    name: []const u8,
) Error!void {
    if (VariableStore.isValidName(name)) {
        if (expander.context.variable(name)) |parameter_value|
            try bytes.appendSlice(expander.allocator, parameter_value);
        return;
    }
    if (std.mem.eql(u8, name, "?")) {
        var buffer: [3]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{d}", .{expander.context.last_status}) catch
            unreachable;
        try bytes.appendSlice(expander.allocator, value);
        return;
    }
    if (std.mem.eql(u8, name, "#")) {
        var buffer: [32]u8 = undefined;
        const value = std.fmt.bufPrint(
            &buffer,
            "{d}",
            .{expander.context.positional_parameters.len},
        ) catch unreachable;
        try bytes.appendSlice(expander.allocator, value);
        return;
    }
    if (std.mem.eql(u8, name, "$")) {
        const process_id = expander.context.shell_process_id orelse
            return error.ParameterExpansionUnsupported;
        var buffer: [20]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{d}", .{@intFromEnum(process_id)}) catch
            unreachable;
        try bytes.appendSlice(expander.allocator, value);
        return;
    }
    if (std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "@")) {
        for (expander.context.positional_parameters, 0..) |parameter, index| {
            if (index != 0) {
                if (expander.joinSeparator()) |separator|
                    try bytes.append(expander.allocator, separator);
            }
            try bytes.appendSlice(expander.allocator, parameter);
        }
        return;
    }
    if (std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "!")) return;
    if (isDecimal(name)) {
        const position = std.fmt.parseUnsigned(usize, name, 10) catch return;
        if (position == 0) {
            const invocation_name = expander.context.invocation_name orelse
                return error.ParameterExpansionUnsupported;
            try bytes.appendSlice(expander.allocator, invocation_name);
            return;
        }
        if (position <= expander.context.positional_parameters.len)
            try bytes.appendSlice(
                expander.allocator,
                expander.context.positional_parameters[position - 1],
            );
        return;
    }
    return error.ParameterExpansionUnsupported;
}

const ParameterSelection = union(enum) {
    value: []const u8,
    word: []const u8,
    assign: []const u8,
    fail,
    empty,
};

fn selectParameterExpansion(
    expander: Expander,
    expansion: Word.ParameterExpansion,
) Error!ParameterSelection {
    const value = try expander.conditionalParameterValue(expansion.parameter);
    return switch (expansion.operator.?) {
        .default_if_unset => if (value) |set| .{ .value = set } else .{ .word = expansion.word },
        .default_if_unset_or_null => if (value) |set|
            if (set.len == 0) .{ .word = expansion.word } else .{ .value = set }
        else
            .{ .word = expansion.word },
        .alternative_if_set => if (value != null) .{ .word = expansion.word } else .empty,
        .alternative_if_set_and_not_null => if (value) |set|
            if (set.len == 0) .empty else .{ .word = expansion.word }
        else
            .empty,
        .assign_if_unset => if (value) |set| .{ .value = set } else .{ .assign = expansion.word },
        .assign_if_unset_or_null => if (value) |set|
            if (set.len == 0) .{ .assign = expansion.word } else .{ .value = set }
        else
            .{ .assign = expansion.word },
        .error_if_unset => if (value) |set| .{ .value = set } else .fail,
        .error_if_unset_or_null => if (value) |set|
            if (set.len == 0) .fail else .{ .value = set }
        else
            .fail,
    };
}

fn conditionalParameterValue(expander: Expander, parameter: []const u8) Error!?[]const u8 {
    if (VariableStore.isValidName(parameter)) return expander.context.variable(parameter);
    if (std.mem.eql(u8, parameter, "-")) return "";
    if (std.mem.eql(u8, parameter, "!")) return null;
    if (!isDecimal(parameter)) return error.ParameterExpansionUnsupported;

    const position = std.fmt.parseUnsigned(usize, parameter, 10) catch return null;
    if (position == 0) return expander.context.invocation_name;
    if (position > expander.context.positional_parameters.len) return null;
    return expander.context.positional_parameters[position - 1];
}

fn appendTilde(
    expander: Expander,
    bytes: *std.ArrayList(u8),
    value: []const u8,
) Error!void {
    std.debug.assert(value.len != 0 and value[0] == '~');
    const prefix_end = std.mem.indexOfScalar(u8, value, '/') orelse value.len;
    if (prefix_end != 1) return error.TildeExpansionUnsupported;
    const home = expander.context.variable("HOME") orelse
        return error.TildeExpansionUnsupported;
    try bytes.appendSlice(expander.allocator, home);
    try bytes.appendSlice(expander.allocator, value[prefix_end..]);
}

fn joinSeparator(expander: Expander) ?u8 {
    const ifs = expander.context.variable("IFS") orelse return ' ';
    return if (ifs.len == 0) null else ifs[0];
}

fn appendFieldSplit(
    expander: Expander,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
    value: []const u8,
) Error!void {
    if (std.mem.indexOfAny(u8, value, "*?[") != null)
        return error.PathnameExpansionUnsupported;

    const ifs = expander.context.variable("IFS") orelse " \t\n";
    if (ifs.len == 0) {
        if (value.len != 0) {
            try bytes.appendSlice(expander.allocator, value);
            current_field_active.* = true;
        }
        return;
    }

    var index: usize = 0;
    while (index < value.len) {
        if (!isIfsByte(ifs, value[index])) {
            const start = index;
            while (index < value.len and !isIfsByte(ifs, value[index])) : (index += 1) {}
            try bytes.appendSlice(expander.allocator, value[start..index]);
            current_field_active.* = true;
            continue;
        }

        var non_whitespace_delimiter = !isIfsWhitespace(ifs, value[index]);
        if (!non_whitespace_delimiter) {
            while (index < value.len and isIfsWhitespace(ifs, value[index])) : (index += 1) {}
            if (index < value.len and isIfsNonWhitespace(ifs, value[index])) {
                non_whitespace_delimiter = true;
                index += 1;
            }
        } else {
            index += 1;
        }
        while (index < value.len and isIfsWhitespace(ifs, value[index])) : (index += 1) {}

        if (non_whitespace_delimiter or current_field_active.*)
            try finishField(expander.allocator, fields, bytes);
        current_field_active.* = false;
    }
}

fn appendQuotedAt(
    expander: Expander,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    if (expander.context.positional_parameters.len == 0) return;
    try bytes.appendSlice(
        expander.allocator,
        expander.context.positional_parameters[0],
    );
    for (expander.context.positional_parameters[1..]) |parameter| {
        try finishField(expander.allocator, fields, bytes);
        try bytes.appendSlice(expander.allocator, parameter);
    }
    current_field_active.* = true;
}

fn appendUnquotedAt(
    expander: Expander,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
    current_field_active: *bool,
) Error!void {
    for (expander.context.positional_parameters, 0..) |parameter, index| {
        if (index != 0 and current_field_active.*) {
            try finishField(expander.allocator, fields, bytes);
            current_field_active.* = false;
        }
        try expander.appendFieldSplit(fields, bytes, current_field_active, parameter);
    }
}

fn finishField(
    allocator: std.mem.Allocator,
    fields: *std.ArrayList([]const u8),
    bytes: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    const field = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(field);
    try fields.append(allocator, field);
}

fn isIfsByte(ifs: []const u8, byte: u8) bool {
    return std.mem.indexOfScalar(u8, ifs, byte) != null;
}

fn isIfsWhitespace(ifs: []const u8, byte: u8) bool {
    return isIfsByte(ifs, byte) and switch (byte) {
        ' ', '\t', '\n' => true,
        else => false,
    };
}

fn isIfsNonWhitespace(ifs: []const u8, byte: u8) bool {
    return isIfsByte(ifs, byte) and !isIfsWhitespace(ifs, byte);
}

fn isDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn hirPartTag(tag: Hir.Inst.Tag) Word.Part.Tag {
    return switch (tag) {
        .literal => .literal,
        .escaped => .escaped,
        .single_quoted => .single_quoted,
        .double_quoted => .double_quoted,
        .double_quoted_escaped => .double_quoted_escaped,
        .parameter => .parameter,
        .braced_parameter => .braced_parameter,
        .double_quoted_parameter => .double_quoted_parameter,
        .double_quoted_braced_parameter => .double_quoted_braced_parameter,
        else => unreachable,
    };
}

test {
    _ = @import("expander_test.zig");
    std.testing.refAllDecls(@This());
}
