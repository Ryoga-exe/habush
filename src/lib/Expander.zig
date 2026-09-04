//! Context-sensitive expansion of HIR words.

const std = @import("std");
const Expander = @This();
const Hir = @import("Hir.zig");

allocator: std.mem.Allocator,

pub const Error = std.mem.Allocator.Error || error{
    ParameterExpansionUnsupported,
    PathnameExpansionUnsupported,
    TildeExpansionUnsupported,
};

pub fn init(allocator: std.mem.Allocator) Expander {
    return .{ .allocator = allocator };
}

/// Expands one argument word to zero or more fields.
///
/// Returned slices are owned by `allocator`. The initial implementation only
/// performs quote removal for static words and always returns one field.
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
            .parameter,
            .braced_parameter,
            .double_quoted_parameter,
            .double_quoted_braced_parameter,
            => return error.ParameterExpansionUnsupported,
            else => unreachable,
        }
    }

    const field = try bytes.toOwnedSlice(expander.allocator);
    errdefer expander.allocator.free(field);
    const fields = try expander.allocator.alloc([]const u8, 1);
    fields[0] = field;
    return fields;
}

test {
    _ = @import("expander_test.zig");
    std.testing.refAllDecls(@This());
}
