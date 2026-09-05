//! Owned named shell variables for one runtime session.

const std = @import("std");
const VariableStore = @This();

gpa: std.mem.Allocator,
map: std.StringArrayHashMapUnmanaged([]u8) = .empty,

pub const Binding = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = std.mem.Allocator.Error || error{InvalidName};

pub fn init(gpa: std.mem.Allocator) VariableStore {
    return .{ .gpa = gpa };
}

pub fn deinit(variables: *VariableStore) void {
    for (variables.map.keys(), variables.map.values()) |name, value| {
        variables.gpa.free(name);
        variables.gpa.free(value);
    }
    variables.map.deinit(variables.gpa);
    variables.* = undefined;
}

pub fn get(variables: VariableStore, name: []const u8) ?[]const u8 {
    return variables.map.get(name);
}

/// Sets a named shell variable while preserving the previous value if
/// allocation fails.
pub fn set(variables: *VariableStore, name: []const u8, value: []const u8) Error!void {
    if (!isValidName(name)) return error.InvalidName;

    const value_copy = try variables.gpa.dupe(u8, value);
    errdefer variables.gpa.free(value_copy);

    if (variables.map.getEntry(name)) |entry| {
        variables.gpa.free(entry.value_ptr.*);
        entry.value_ptr.* = value_copy;
        return;
    }

    const name_copy = try variables.gpa.dupe(u8, name);
    errdefer variables.gpa.free(name_copy);
    try variables.map.putNoClobber(variables.gpa, name_copy, value_copy);
}

pub fn unset(variables: *VariableStore, name: []const u8) bool {
    const index = variables.map.getIndex(name) orelse return false;
    const owned_name = variables.map.keys()[index];
    const owned_value = variables.map.values()[index];
    variables.map.orderedRemoveAt(index);
    variables.gpa.free(owned_name);
    variables.gpa.free(owned_value);
    return true;
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or !isNameStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isNameContinue(byte)) return false;
    }
    return true;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}

test "variable store owns names and values" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try variables.set(&name, &value);
    name[0] = 'x';
    value[0] = 'x';

    try std.testing.expectEqualStrings("value", variables.get("name").?);
    try std.testing.expect(variables.get("xame") == null);
}

test "variable store replaces and removes values" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    try variables.set("name", "first");
    try variables.set("name", "second");
    try std.testing.expectEqualStrings("second", variables.get("name").?);
    try std.testing.expect(variables.unset("name"));
    try std.testing.expect(!variables.unset("name"));
    try std.testing.expect(variables.get("name") == null);
}

test "failed replacement preserves the previous value" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var variables = VariableStore.init(failing.allocator());
    defer variables.deinit();
    try variables.set("name", "previous");

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, variables.set("name", "replacement"));
    try std.testing.expectEqualStrings("previous", variables.get("name").?);
}

test "variable store rejects invalid names" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();

    const invalid_names = [_][]const u8{ "", "1name", "not-valid" };
    for (invalid_names) |name| {
        try std.testing.expectError(error.InvalidName, variables.set(name, "value"));
    }
}

test "variable store handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        setWithAllocator,
        .{},
    );
}

fn setWithAllocator(gpa: std.mem.Allocator) !void {
    var variables = VariableStore.init(gpa);
    defer variables.deinit();
    try variables.set("first", "one");
    try variables.set("second", "two");
    try variables.set("first", "replacement");
}

test {
    std.testing.refAllDecls(@This());
}
