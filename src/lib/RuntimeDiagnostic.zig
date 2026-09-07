//! Structured diagnostics produced while evaluating shell commands.
//!
//! String payloads borrow execution input and must be copied when a diagnostic
//! needs to outlive the command that produced it.

const std = @import("std");
const RuntimeDiagnostic = @This();

subject: Subject,
kind: Kind,

pub const Subject = union(enum) {
    shell,
    command: []const u8,
    path: []const u8,
};

pub const Kind = union(enum) {
    unsupported_option: []const u8,
    unexpected_argument: []const u8,
    too_many_arguments,
    variable_not_set: []const u8,
    invalid_name: []const u8,
    cannot_change_directory: []const u8,
    working_directory_unavailable,
};

pub const RenderOptions = struct {
    program_name: ?[]const u8 = null,
};

pub fn status(diagnostic: RuntimeDiagnostic) u8 {
    return switch (diagnostic.kind) {
        .unsupported_option, .unexpected_argument, .too_many_arguments => 2,
        .variable_not_set,
        .invalid_name,
        .cannot_change_directory,
        .working_directory_unavailable,
        => 1,
    };
}

/// Renders one diagnostic without a trailing newline.
pub fn render(
    diagnostic: RuntimeDiagnostic,
    writer: *std.Io.Writer,
    options: RenderOptions,
) std.Io.Writer.Error!void {
    if (options.program_name) |program_name| {
        try writer.writeAll(program_name);
        try writer.writeAll(": ");
    }
    switch (diagnostic.subject) {
        .shell => {},
        .command, .path => |subject| {
            try writer.writeAll(subject);
            try writer.writeAll(": ");
        },
    }
    switch (diagnostic.kind) {
        .unsupported_option => |option| try writer.print("unsupported option: {s}", .{option}),
        .unexpected_argument => |argument| try writer.print("unexpected argument: {s}", .{argument}),
        .too_many_arguments => try writer.writeAll("too many arguments"),
        .variable_not_set => |name| try writer.print("{s} not set", .{name}),
        .invalid_name => |name| try writer.print("invalid name: {s}", .{name}),
        .cannot_change_directory => |path| try writer.print("cannot change directory: {s}", .{path}),
        .working_directory_unavailable => try writer.writeAll("working directory unavailable"),
    }
}

test "renders a command diagnostic with an optional program name" {
    const diagnostic: RuntimeDiagnostic = .{
        .subject = .{ .command = "cd" },
        .kind = .{ .variable_not_set = "HOME" },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try diagnostic.render(&output.writer, .{ .program_name = "habush" });

    try std.testing.expectEqualStrings("habush: cd: HOME not set", output.written());
    try std.testing.expectEqual(@as(u8, 1), diagnostic.status());
}

test "usage diagnostics have status two" {
    const diagnostic: RuntimeDiagnostic = .{
        .subject = .{ .command = "pwd" },
        .kind = .{ .unsupported_option = "-P" },
    };

    try std.testing.expectEqual(@as(u8, 2), diagnostic.status());
}

test {
    std.testing.refAllDecls(@This());
}
