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

test {
    _ = @import("variable_store_test.zig");
    std.testing.refAllDecls(@This());
}
