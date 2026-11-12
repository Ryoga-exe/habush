//! Completion bindings are independent of executable lookup. Provider userdata
//! is borrowed and must outlive every session/snapshot using the binding.
const std = @import("std");
const Provider = @import("Provider.zig");
const VariableStore = @import("../VariableStore.zig");
const Registry = @This();

gpa: std.mem.Allocator,
map: std.array_hash_map.String(Handler) = .empty,

pub const Handler = union(enum) { function: []const u8, provider: Provider };
pub const Error = std.mem.Allocator.Error || error{InvalidName};

pub fn deinit(registry: *Registry) void {
    for (registry.map.keys(), registry.map.values()) |name, handler| {
        registry.gpa.free(name);
        registry.freeHandler(handler);
    }
    registry.map.deinit(registry.gpa);
    registry.* = undefined;
}

pub fn clone(registry: Registry, gpa: std.mem.Allocator) std.mem.Allocator.Error!Registry {
    var copy: Registry = .{ .gpa = gpa };
    errdefer copy.deinit();
    for (registry.map.keys(), registry.map.values()) |name, handler|
        copy.set(name, handler) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => unreachable,
        };
    return copy;
}

pub fn get(registry: Registry, name: []const u8) ?Handler {
    return registry.map.get(name);
}

/// Keeps the old registration intact if allocation fails.
pub fn set(registry: *Registry, name: []const u8, handler: Handler) Error!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
    const owned: Handler = switch (handler) {
        .function => |function| value: {
            if (!VariableStore.isValidName(function)) return error.InvalidName;
            break :value .{ .function = try registry.gpa.dupe(u8, function) };
        },
        .provider => handler,
    };
    errdefer registry.freeHandler(owned);
    if (registry.map.getPtr(name)) |previous| {
        registry.freeHandler(previous.*);
        previous.* = owned;
        return;
    }
    const key = try registry.gpa.dupe(u8, name);
    errdefer registry.gpa.free(key);
    try registry.map.putNoClobber(registry.gpa, key, owned);
}

pub fn remove(registry: *Registry, name: []const u8) bool {
    const entry = registry.map.fetchSwapRemove(name) orelse return false;
    registry.gpa.free(entry.key);
    registry.freeHandler(entry.value);
    return true;
}

fn freeHandler(registry: Registry, handler: Handler) void {
    if (handler == .function) registry.gpa.free(handler.function);
}

test "registrations own names and clone independently" {
    var registry: Registry = .{ .gpa = std.testing.allocator };
    defer registry.deinit();
    var name = [_]u8{ 'g', 'i', 't' };
    try registry.set(&name, .{ .function = "first" });
    name[0] = 'x';
    var copy = try registry.clone(std.testing.allocator);
    defer copy.deinit();
    try registry.set("git", .{ .function = "second" });
    try std.testing.expectEqualStrings("first", copy.get("git").?.function);
    try std.testing.expectEqualStrings("second", registry.get("git").?.function);
    try std.testing.expect(copy.remove("git"));
    try std.testing.expect(!copy.remove("git"));
    try std.testing.expect(registry.get("git") != null);
    try std.testing.expectError(error.InvalidName, registry.set("git", .{ .function = "bad name" }));
    try std.testing.expectEqualStrings("second", registry.get("git").?.function);
}
