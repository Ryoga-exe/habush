//! Owned named shell variables for one runtime session.

const std = @import("std");
const VariableStore = @This();

gpa: std.mem.Allocator,
map: std.StringArrayHashMapUnmanaged(Value) = .empty,

pub const Binding = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
};

const Value = struct {
    bytes: []u8,
    exported: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{InvalidName};

pub const Iterator = struct {
    variables: *const VariableStore,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Binding {
        if (self.index == self.variables.map.count()) return null;
        defer self.index += 1;
        return .{
            .name = self.variables.map.keys()[self.index],
            .value = self.variables.map.values()[self.index].bytes,
            .exported = self.variables.map.values()[self.index].exported,
        };
    }
};

pub fn init(gpa: std.mem.Allocator) VariableStore {
    return .{ .gpa = gpa };
}

pub fn deinit(variables: *VariableStore) void {
    for (variables.map.keys(), variables.map.values()) |name, value| {
        variables.gpa.free(name);
        variables.gpa.free(value.bytes);
    }
    variables.map.deinit(variables.gpa);
    variables.* = undefined;
}

pub fn get(variables: VariableStore, name: []const u8) ?[]const u8 {
    const value = variables.map.get(name) orelse return null;
    return value.bytes;
}

pub fn isExported(variables: VariableStore, name: []const u8) bool {
    const value = variables.map.get(name) orelse return false;
    return value.exported;
}

pub fn count(variables: VariableStore) usize {
    return variables.map.count();
}

pub fn iterator(variables: *const VariableStore) Iterator {
    return .{ .variables = variables };
}

/// Sets a named shell variable while preserving the previous value if
/// allocation fails.
pub fn set(variables: *VariableStore, name: []const u8, value: []const u8) Error!void {
    if (!isValidName(name)) return error.InvalidName;

    const value_copy = try variables.gpa.dupe(u8, value);
    errdefer variables.gpa.free(value_copy);

    if (variables.map.getEntry(name)) |entry| {
        variables.gpa.free(entry.value_ptr.bytes);
        entry.value_ptr.bytes = value_copy;
        return;
    }

    const name_copy = try variables.gpa.dupe(u8, name);
    errdefer variables.gpa.free(name_copy);
    try variables.map.putNoClobber(variables.gpa, name_copy, .{ .bytes = value_copy });
}

/// Changes whether a variable is included in the child process environment.
/// Exporting an unset name creates it with an empty value; clearing an unset
/// name is a no-op.
pub fn setExported(variables: *VariableStore, name: []const u8, exported: bool) Error!void {
    if (!isValidName(name)) return error.InvalidName;
    if (variables.map.getEntry(name)) |entry| {
        entry.value_ptr.exported = exported;
        return;
    }
    if (!exported) return;
    try variables.set(name, "");
    variables.map.getEntry(name).?.value_ptr.exported = true;
}

pub fn unset(variables: *VariableStore, name: []const u8) bool {
    const index = variables.map.getIndex(name) orelse return false;
    const owned_name = variables.map.keys()[index];
    const owned_value = variables.map.values()[index].bytes;
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

test "variable store iterates in insertion order" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("first", "one");
    try variables.set("second", "two");

    var iterator_value = variables.iterator();
    const first = iterator_value.next().?;
    const second = iterator_value.next().?;
    try std.testing.expectEqualStrings("first", first.name);
    try std.testing.expectEqualStrings("one", first.value);
    try std.testing.expectEqualStrings("second", second.name);
    try std.testing.expectEqualStrings("two", second.value);
    try std.testing.expect(iterator_value.next() == null);
}

test "variable store preserves export attributes across assignment" {
    var variables = VariableStore.init(std.testing.allocator);
    defer variables.deinit();
    try variables.set("name", "first");
    try std.testing.expect(!variables.isExported("name"));

    try variables.setExported("name", true);
    try variables.set("name", "second");
    try std.testing.expect(variables.isExported("name"));
    try std.testing.expectEqualStrings("second", variables.get("name").?);

    try variables.setExported("name", false);
    try std.testing.expect(!variables.isExported("name"));
    try variables.setExported("missing", false);
    try std.testing.expect(variables.get("missing") == null);
    try variables.setExported("created", true);
    try std.testing.expectEqualStrings("", variables.get("created").?);
    try std.testing.expect(variables.isExported("created"));
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
    try variables.setExported("third", true);
}

test {
    std.testing.refAllDecls(@This());
}
