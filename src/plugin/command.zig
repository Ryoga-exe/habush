//! Command ABI v0: argv byte list in, one exit-status byte out. I/O uses Scope.
const std = @import("std");
const Host = @import("Host.zig");
const protocol = @import("protocol.zig");

pub fn run(module: *const Host.Module, gpa: std.mem.Allocator, entry: []const u8, argv: []const []const u8, scope: Host.Scope) Host.Error!u8 {
    const request = try protocol.encode(gpa, &.{argv}, scope.limits.request_bytes);
    defer gpa.free(request);
    const response = try module.invoke(gpa, entry, request, scope);
    defer gpa.free(response);
    if (response.len != 1) return error.InvalidResponse;
    return response[0];
}
