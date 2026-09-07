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
    /// Expanded command word. The resolver decides whether this is an explicit
    /// path or requires a platform-specific search.
    name: []const u8,
    search_path: []const []const u8,
    cwd: ?[]const u8,
};

/// Returns an allocator-owned executable representation accepted by `Host`, or
/// `null` when no executable matches the request. Resolution includes explicit
/// paths because path syntax is platform-specific.
pub fn resolve(
    resolver: CommandResolver,
    allocator: std.mem.Allocator,
    request: Request,
) Error!?[]u8 {
    if (request.name.len == 0) return null;
    return resolver.vtable.resolve(resolver.userdata, allocator, request);
}

/// A resolver for callers that guarantee command words are already in the
/// executable form expected by their `Host` implementation.
pub fn preResolved() CommandResolver {
    return .{ .userdata = null, .vtable = &pre_resolved_vtable };
}

const pre_resolved_vtable: VTable = .{ .resolve = resolvePreResolved };

fn resolvePreResolved(
    userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Request,
) Error!?[]u8 {
    _ = userdata;
    return try allocator.dupe(u8, request.name);
}

test {
    _ = @import("command_resolver_test.zig");
    std.testing.refAllDecls(@This());
}
