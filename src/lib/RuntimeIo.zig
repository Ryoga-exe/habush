//! Standard streams and diagnostic output shared by runtime commands.

const std = @import("std");
const RuntimeDiagnostic = @import("RuntimeDiagnostic.zig");
const RuntimeIo = @This();

/// A null stream discards output. Non-null writers must remain valid for every
/// execution using this value.
stdout: ?*std.Io.Writer = null,
stderr: ?*std.Io.Writer = null,
diagnostic_options: RuntimeDiagnostic.RenderOptions = .{},

pub fn reportDiagnostic(
    runtime_io: RuntimeIo,
    diagnostic: RuntimeDiagnostic,
) std.Io.Writer.Error!void {
    const writer = runtime_io.stderr orelse return;
    try diagnostic.render(writer, runtime_io.diagnostic_options);
    try writer.writeByte('\n');
}

test "reports diagnostics to stderr" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const runtime_io: RuntimeIo = .{
        .stderr = &diagnostics.writer,
        .diagnostic_options = .{ .program_name = "habush" },
    };

    try runtime_io.reportDiagnostic(.{
        .subject = .{ .command = "missing" },
        .kind = .command_not_found,
    });

    try std.testing.expectEqualStrings(
        "habush: missing: command not found\n",
        diagnostics.written(),
    );
}

test {
    std.testing.refAllDecls(@This());
}
