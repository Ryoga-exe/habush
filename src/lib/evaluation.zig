//! Outcome of evaluating one shell input unit.
//!
//! `syntax` owns the AST's allocated tables, but the AST borrows its source
//! and collected here-document bodies. Keep those inputs alive while reading
//! diagnostics from this value. Call `deinit` with the parser allocator.

const std = @import("std");
const Ast = @import("Ast.zig");
const Executor = @import("Executor.zig");

/// Scoped to one Session and independent of native PIDs and background job IDs.
pub const Id = enum(u64) { _ };

/// Observes one accepted Session.evaluate call, including empty input and
/// comments. Low-level execute, input-adapter rejection, individual pipeline
/// stages, and later background completion do not emit these events. Started
/// payloads are borrowed only for that callback. Finished values never borrow
/// the returned syntax AST.
pub const Event = union(enum) {
    started: struct {
        id: Id,
        source: [:0]const u8,
        cwd: ?[]const u8,
    },
    finished: struct {
        id: Id,
        outcome: Outcome,
    },

    pub const Outcome = union(enum) {
        executed: Executor.Result,
        syntax,
        unsupported: Result.Unsupported,
        failed: anyerror,
    };
};

/// Called synchronously on the evaluating task. Callbacks must not reenter or
/// change the Session; copy borrowed payloads before retaining them. Observing
/// cannot replace an execution result or authorize any additional operation.
pub const Observer = struct {
    userdata: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, Event) void,
};

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
