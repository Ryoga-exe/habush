//! Completion ABI v0: prefix followed by literal argv, candidate values out.
//! Candidate quoting and source edits remain the language adapter's job.
const std = @import("std");
const Host = @import("Host.zig");
const protocol = @import("protocol.zig");

pub const Result = struct {
    bytes: []u8,
    values: [][]const u8,

    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        gpa.free(result.values);
        gpa.free(result.bytes);
        result.* = undefined;
    }
};

pub fn collect(module: *const Host.Module, gpa: std.mem.Allocator, entry: []const u8, prefix: []const u8, argv: []const []const u8, scope: Host.Scope, max_candidates: u32) Host.Error!Result {
    const request = try protocol.encode(gpa, &.{ &.{prefix}, argv }, scope.limits.request_bytes);
    defer gpa.free(request);
    const response = try module.invoke(gpa, entry, request, scope);
    errdefer gpa.free(response);
    return .{ .bytes = response, .values = try protocol.decode(gpa, response, max_candidates) };
}
