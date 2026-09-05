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
/// performs quote removal and named parameter expansion inside double quotes.
/// Field splitting remains a separate, unsupported stage.
pub fn expandArgument(
    expander: Expander,
    hir: Hir,
    word: Hir.Inst.Index,
) Error![]const []const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(expander.allocator);
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
            },
            .escaped,
            .single_quoted,
            .double_quoted,
            .double_quoted_escaped,
            => try bytes.appendSlice(expander.allocator, value),
            .parameter, .braced_parameter => return error.FieldSplittingUnsupported,
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => try expander.appendNamedParameter(&bytes, value),
            else => unreachable,
        }
    }

    const field = try bytes.toOwnedSlice(expander.allocator);
    errdefer expander.allocator.free(field);
    const fields = try expander.allocator.alloc([]const u8, 1);
    fields[0] = field;
    return fields;
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
            => try expander.appendNamedParameter(&bytes, value),
            else => unreachable,
        }
    }
    return bytes.toOwnedSlice(expander.allocator);
}

fn appendNamedParameter(
    expander: Expander,
    bytes: *std.ArrayList(u8),
    name: []const u8,
) Error!void {
    if (!VariableStore.isValidName(name)) return error.ParameterExpansionUnsupported;
    if (expander.context.variable(name)) |parameter_value|
        try bytes.appendSlice(expander.allocator, parameter_value);
}

test {
    _ = @import("expander_test.zig");
    std.testing.refAllDecls(@This());
}
