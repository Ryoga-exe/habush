//! Standard streams and diagnostic output shared by runtime commands.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Pipeline = @import("../Pipeline.zig");
const Host = @import("../Host.zig");
const Io = @This();

/// A null output stream discards output. A null input stream is at EOF.
/// Non-null streams are borrowed and must remain valid during execution.
stdin: ?*std.Io.Reader = null,
stdout: ?*std.Io.Writer = null,
stderr: ?*std.Io.Writer = null,
diagnostic_options: Diagnostic.RenderOptions = .{},
/// When present, receives structured diagnostics instead of the default stderr
/// rendering. The sink decides whether/how to render and must copy retained data.
diagnostic_sink: ?Diagnostic.Sink = null,
/// Set by the evaluator for the currently executing source instruction.
diagnostic_source: ?Diagnostic.Source = null,

pub fn reportDiagnostic(
    runtime_io: Io,
    diagnostic: Diagnostic,
) std.Io.Writer.Error!void {
    var located = diagnostic;
    if (located.source == null) located.source = runtime_io.diagnostic_source;
    if (runtime_io.diagnostic_sink) |sink| {
        sink.report(sink.userdata, located);
        return;
    }
    if (located.worker_reported) return;
    const writer = runtime_io.stderr orelse return;
    try located.render(writer, runtime_io.diagnostic_options);
    try writer.writeByte('\n');
}

/// Startup attribution belongs to the original request, never to a later
/// `wait`/`jobs` input. The worker's stderr output is retained without adding a
/// second default rendering in the parent.
pub fn reportStartupFailure(runtime_io: Io, context: Pipeline.FailureContext, failure: Host.SpawnFailure) error{Unexpected}!void {
    const diagnostic = try Diagnostic.fromStartupFailure(context, failure);
    if (runtime_io.diagnostic_sink) |sink| sink.report(sink.userdata, diagnostic);
}

test "reports diagnostics to stderr" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const runtime_io: Io = .{
        .stderr = &diagnostics.writer,
        .diagnostic_options = .{ .program_name = "habush" },
    };

    try runtime_io.reportDiagnostic(.{
        .subject = .{ .command = "missing" },
        .kind = .command_not_found,
    });
    try runtime_io.reportDiagnostic(.{
        .subject = .{ .command = "missing" },
        .kind = .command_not_found,
        .worker_reported = true,
    });

    try std.testing.expectEqualStrings(
        "habush: missing: command not found\n",
        diagnostics.written(),
    );
}

test {
    std.testing.refAllDecls(@This());
}
