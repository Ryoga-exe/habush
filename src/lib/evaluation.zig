//! Outcome of evaluating one shell input unit.
//!
//! `syntax` owns the AST's allocated tables, but the AST borrows its source
//! and collected here-document bodies. Keep those inputs alive while reading
//! diagnostics from this value. Call `deinit` with the parser allocator.

const std = @import("std");
const Ast = @import("Ast.zig");
const Executor = @import("Executor.zig");

pub const Result = union(enum) {
    executed: Executor.Result,
    syntax: Ast,
    unsupported: Unsupported,

    pub const Unsupported = error{
        UnsupportedInstruction,
        ParameterAssignmentUnavailable,
        PathnameExpansionUnsupported,
        TildeExpansionUnsupported,
        ParameterExpansionUnsupported,
    };

    pub fn deinit(evaluation: *Result, gpa: std.mem.Allocator) void {
        switch (evaluation.*) {
            .syntax => |*tree| tree.deinit(gpa),
            .executed, .unsupported => {},
        }
        evaluation.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
