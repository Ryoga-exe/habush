//! Resolves a command name using explicit shell session state.

const std = @import("std");
const CommandResolver = @This();

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    resolve: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        Request,
    ) Error!?[]u8,
};

pub const Error = std.mem.Allocator.Error || error{
    AccessDenied,
    Unexpected,
};

pub const Request = struct {
    name: []const u8,
    search_path: []const []const u8,
    cwd: ?[]const u8,
};

/// Returns an allocator-owned executable path, or `null` when no executable
/// matches the request.
pub fn resolve(
    resolver: CommandResolver,
    allocator: std.mem.Allocator,
    request: Request,
) Error!?[]u8 {
    if (request.name.len == 0) return null;
    return resolver.vtable.resolve(resolver.userdata, allocator, request);
}

test {
    _ = @import("command_resolver_test.zig");
    std.testing.refAllDecls(@This());
}
