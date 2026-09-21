//! Context-sensitive expansion of HIR words.

const std = @import("std");
const Expander = @This();
const Hir = @import("Hir.zig");
const VariableStore = @import("VariableStore.zig");

allocator: std.mem.Allocator,
context: Context,

pub const Context = struct {
    variables: ?*const VariableStore = null,
    overrides: ?*const VariableStore = null,
    positional_parameters: []const []const u8 = &.{},
    last_status: u8 = 0,

    fn variable(context: Context, name: []const u8) ?[]const u8 {
        if (context.overrides) |overrides| {
            if (overrides.get(name)) |value| return value;
        }
        if (context.variables) |variables| return variables.get(name);
        return null;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    FieldSplittingUnsupported,
    ParameterExpansionUnsupported,
    PathnameExpansionUnsupported,
    TildeExpansionUnsupported,
};

pub fn init(allocator: std.mem.Allocator) Expander {
    return initWithContext(allocator, .{});
}

pub fn initWithContext(allocator: std.mem.Allocator, context: Context) Expander {
    return .{ .allocator = allocator, .context = context };
}

/// Expands one argument word to zero or more fields.
///
/// Returned slices are owned by `allocator`. The initial implementation
/// performs quote removal and parameter expansion inside double quotes. Field
/// splitting remains a separate, unsupported stage.
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
    var preserves_empty_field = false;
    for (hir.wordParts(word), 0..) |part, part_index| {
        const tag = hir.instructionTag(part);
        const value = hir.wordPart(part);
        switch (tag) {
            .literal => {
                if (std.mem.indexOfAny(u8, value, "*?[") != null)
                    return error.PathnameExpansionUnsupported;
                if (part_index == 0 and std.mem.startsWith(u8, value, "~"))
                    return error.TildeExpansionUnsupported;
                try bytes.appendSlice(expander.allocator, value);
                preserves_empty_field = true;
            },
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            => {
                try bytes.appendSlice(expander.allocator, value);
                preserves_empty_field = true;
            },
            .parameter, .braced_parameter => {
                if (!isFieldSplittingIndependent(value))
                    return error.FieldSplittingUnsupported;
                try expander.appendParameter(&bytes, value);
                preserves_empty_field = true;
            },
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => {
                if (std.mem.eql(u8, value, "@")) {
                    if (expander.context.positional_parameters.len != 0) {
                        try bytes.appendSlice(
                            expander.allocator,
                            expander.context.positional_parameters[0],
                        );
                        for (expander.context.positional_parameters[1..]) |parameter| {
                            try finishField(expander.allocator, &fields, &bytes);
                            try bytes.appendSlice(expander.allocator, parameter);
                        }
                        preserves_empty_field = true;
                    }
                } else {
                    try expander.appendParameter(&bytes, value);
                    preserves_empty_field = true;
                }
            },
            else => unreachable,
        }
    }

    if (preserves_empty_field) try finishField(expander.allocator, &fields, &bytes);
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
        switch (tag) {
            .literal => {
                if (part_index == 0 and std.mem.startsWith(u8, value, "~"))
                    return error.TildeExpansionUnsupported;
                try bytes.appendSlice(expander.allocator, value);
            },
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            => try bytes.appendSlice(expander.allocator, value),
            .parameter,
            .braced_parameter,
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => try expander.appendParameter(&bytes, value),
            else => unreachable,
        }
    }
    return bytes.toOwnedSlice(expander.allocator);
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
    if (isDecimal(name)) {
        const position = std.fmt.parseUnsigned(usize, name, 10) catch return;
        if (position == 0) return error.ParameterExpansionUnsupported;
        if (position <= expander.context.positional_parameters.len)
            try bytes.appendSlice(
                expander.allocator,
                expander.context.positional_parameters[position - 1],
            );
        return;
    }
    return error.ParameterExpansionUnsupported;
}

fn joinSeparator(expander: Expander) ?u8 {
    const ifs = expander.context.variable("IFS") orelse return ' ';
    return if (ifs.len == 0) null else ifs[0];
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

fn isFieldSplittingIndependent(name: []const u8) bool {
    return std.mem.eql(u8, name, "?") or std.mem.eql(u8, name, "#");
}

fn isDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test {
    _ = @import("expander_test.zig");
    std.testing.refAllDecls(@This());
}
