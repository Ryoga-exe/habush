//! Structured diagnostics produced while evaluating shell commands.
//!
//! String payloads borrow execution input and must be copied when a diagnostic
//! needs to outlive the command that produced it.

const std = @import("std");
const Diagnostic = @This();
const types = @import("types.zig");

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
    numeric_argument_required: []const u8,
    invalid_loop_count: []const u8,
    not_in_loop,
    not_in_function,
    variable_not_set: []const u8,
    parameter_expansion: ParameterExpansion,
    ambiguous_redirect,
    invalid_file_descriptor: []const u8,
    cannot_open: CannotOpenReason,
    invalid_name: []const u8,
    cannot_change_directory: []const u8,
    working_directory_unavailable,
    function_call_depth_exceeded,
    command_not_found,
    cannot_execute: CannotExecuteReason,
};

pub const ParameterExpansion = struct {
    parameter: []const u8,
    message: []const u8,
};

pub const CannotExecuteReason = enum {
    access_denied,
    invalid_executable,
    resource_unavailable,
    sandbox_unavailable,
    unsupported,
};

pub const CannotOpenReason = enum {
    not_found,
    access_denied,
    invalid_path,
    path_already_exists,
    resource_unavailable,
    unsupported,
};

pub const RenderOptions = struct {
    program_name: ?[]const u8 = null,
};

pub fn status(diagnostic: Diagnostic) types.ExitStatus {
    return switch (diagnostic.kind) {
        .unsupported_option,
        .unexpected_argument,
        .too_many_arguments,
        .numeric_argument_required,
        .invalid_loop_count,
        => 2,
        .not_in_loop,
        .not_in_function,
        .variable_not_set,
        .parameter_expansion,
        .ambiguous_redirect,
        .invalid_file_descriptor,
        .cannot_open,
        .invalid_name,
        .cannot_change_directory,
        .working_directory_unavailable,
        .function_call_depth_exceeded,
        => 1,
        .command_not_found => 127,
        .cannot_execute => 126,
    };
}

/// Renders one diagnostic without a trailing newline.
pub fn render(
    diagnostic: Diagnostic,
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
        .numeric_argument_required => |argument| try writer.print("numeric argument required: {s}", .{argument}),
        .invalid_loop_count => |argument| try writer.print("invalid loop count: {s}", .{argument}),
        .not_in_loop => try writer.writeAll("not in a loop"),
        .not_in_function => try writer.writeAll("not in a function"),
        .variable_not_set => |name| try writer.print("{s} not set", .{name}),
        .parameter_expansion => |failure| try writer.print(
            "{s}: {s}",
            .{ failure.parameter, failure.message },
        ),
        .ambiguous_redirect => try writer.writeAll("ambiguous redirect"),
        .invalid_file_descriptor => |descriptor| try writer.print(
            "invalid file descriptor: {s}",
            .{descriptor},
        ),
        .cannot_open => |reason| switch (reason) {
            .not_found => try writer.writeAll("no such file or directory"),
            .access_denied => try writer.writeAll("permission denied"),
            .invalid_path => try writer.writeAll("invalid path"),
            .path_already_exists => try writer.writeAll("file exists"),
            .resource_unavailable => try writer.writeAll("system resources unavailable"),
            .unsupported => try writer.writeAll("operation not supported"),
        },
        .invalid_name => |name| try writer.print("invalid name: {s}", .{name}),
        .cannot_change_directory => |path| try writer.print("cannot change directory: {s}", .{path}),
        .working_directory_unavailable => try writer.writeAll("working directory unavailable"),
        .function_call_depth_exceeded => try writer.writeAll("maximum function call depth exceeded"),
        .command_not_found => try writer.writeAll("command not found"),
        .cannot_execute => |reason| switch (reason) {
            .access_denied => try writer.writeAll("permission denied"),
            .invalid_executable => try writer.writeAll("invalid executable"),
            .resource_unavailable => try writer.writeAll("system resources unavailable"),
            .sandbox_unavailable => try writer.writeAll("required sandbox unavailable"),
            .unsupported => try writer.writeAll("operation not supported"),
        },
    }
}

test "renders the shell status classes" {
    const Case = struct {
        diagnostic: Diagnostic,
        options: RenderOptions = .{},
        status: types.ExitStatus,
        rendered: []const u8,
    };
    const cases = [_]Case{
        .{
            .diagnostic = .{
                .subject = .{ .command = "cd" },
                .kind = .{ .variable_not_set = "HOME" },
            },
            .options = .{ .program_name = "habush" },
            .status = 1,
            .rendered = "habush: cd: HOME not set",
        },
        .{
            .diagnostic = .{
                .subject = .{ .command = "pwd" },
                .kind = .{ .unsupported_option = "-P" },
            },
            .status = 2,
            .rendered = "pwd: unsupported option: -P",
        },
        .{
            .diagnostic = .{
                .subject = .{ .command = "missing" },
                .kind = .command_not_found,
            },
            .status = 127,
            .rendered = "missing: command not found",
        },
        .{
            .diagnostic = .{
                .subject = .{ .command = "tool" },
                .kind = .{ .cannot_execute = .access_denied },
            },
            .status = 126,
            .rendered = "tool: permission denied",
        },
    };

    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try case.diagnostic.render(&output.writer, case.options);
        try std.testing.expectEqual(case.status, case.diagnostic.status());
        try std.testing.expectEqualStrings(case.rendered, output.written());
    }
}

test {
    std.testing.refAllDecls(@This());
}
