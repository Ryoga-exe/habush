//! Owned shell function definitions for one runtime session.

const std = @import("std");
const FunctionStore = @This();
const Hir = @import("Hir.zig");
const VariableStore = @import("VariableStore.zig");

gpa: std.mem.Allocator,
map: std.StringArrayHashMapUnmanaged(Definition) = .empty,

pub const Error = std.mem.Allocator.Error || error{InvalidName};

pub const Definition = struct {
    hir: Hir,
    body: Hir.Inst.Index,

    pub fn deinit(definition: *Definition, gpa: std.mem.Allocator) void {
        definition.hir.deinit(gpa);
        definition.* = undefined;
    }

    pub fn clone(
        definition: Definition,
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!Definition {
        return .{
            .hir = try definition.hir.clone(gpa),
            .body = definition.body,
        };
    }
};

pub fn init(gpa: std.mem.Allocator) FunctionStore {
    return .{ .gpa = gpa };
}

pub fn deinit(functions: *FunctionStore) void {
    for (functions.map.keys(), functions.map.values()) |name, *definition| {
        functions.gpa.free(name);
        definition.deinit(functions.gpa);
    }
    functions.map.deinit(functions.gpa);
    functions.* = undefined;
}

pub fn clone(functions: FunctionStore, gpa: std.mem.Allocator) std.mem.Allocator.Error!FunctionStore {
    var copy = FunctionStore.init(gpa);
    errdefer copy.deinit();
    for (functions.map.keys(), functions.map.values()) |name, definition|
        copy.set(name, definition.hir, definition.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => unreachable,
        };
    return copy;
}

pub fn contains(functions: FunctionStore, name: []const u8) bool {
    return functions.map.contains(name);
}

/// Returns an owned snapshot that remains valid if the stored definition is
/// replaced while its body is executing.
pub fn cloneDefinition(
    functions: FunctionStore,
    name: []const u8,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!?Definition {
    const definition = functions.map.get(name) orelse return null;
    return try definition.clone(gpa);
}

/// Stores a definition while preserving the previous one if allocation fails.
pub fn set(
    functions: *FunctionStore,
    name: []const u8,
    hir: Hir,
    body: Hir.Inst.Index,
) Error!void {
    if (!VariableStore.isValidName(name)) return error.InvalidName;

    var definition = Definition{
        .hir = try hir.clone(functions.gpa),
        .body = body,
    };
    errdefer definition.deinit(functions.gpa);

    if (functions.map.getPtr(name)) |previous| {
        previous.deinit(functions.gpa);
        previous.* = definition;
        return;
    }

    const name_copy = try functions.gpa.dupe(u8, name);
    errdefer functions.gpa.free(name_copy);
    try functions.map.putNoClobber(functions.gpa, name_copy, definition);
}

test "function store owns, replaces, and snapshots definitions" {
    var first = try generate("build() { value=first; }");
    defer first.deinit(std.testing.allocator);
    var second = try generate("build() { value=second; }");
    defer second.deinit(std.testing.allocator);
    var functions = FunctionStore.init(std.testing.allocator);
    defer functions.deinit();

    const first_definition = first.functionDefinition(firstCommand(first));
    try functions.set(first_definition.name, first, first_definition.body);
    var snapshot = (try functions.cloneDefinition("build", std.testing.allocator)).?;
    defer snapshot.deinit(std.testing.allocator);

    const second_definition = second.functionDefinition(firstCommand(second));
    try functions.set(second_definition.name, second, second_definition.body);

    try std.testing.expectEqualStrings("first", assignmentValue(snapshot));
    var replacement = (try functions.cloneDefinition("build", std.testing.allocator)).?;
    defer replacement.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", assignmentValue(replacement));
    try std.testing.expect(functions.contains("build"));
    try std.testing.expect(!(functions.contains("missing")));
}

test "function store rejects invalid names" {
    var hir = try generate("build() { true; }");
    defer hir.deinit(std.testing.allocator);
    const definition = hir.functionDefinition(firstCommand(hir));
    var functions = FunctionStore.init(std.testing.allocator);
    defer functions.deinit();

    try std.testing.expectError(
        error.InvalidName,
        functions.set("not-valid", hir, definition.body),
    );
}

test "function store handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        storeWithAllocator,
        .{},
    );
}

fn generate(source: [:0]const u8) !Hir {
    const Ast = @import("Ast.zig");
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    return @import("AstGen.zig").generate(std.testing.allocator, tree);
}

fn firstCommand(hir: Hir) Hir.Inst.Index {
    return hir.listItem(hir.root().?, 0).command;
}

fn assignmentValue(definition: Definition) []const u8 {
    const body = definition.hir.groupedCommand(definition.body).body;
    const command = definition.hir.listItem(body, 0).command;
    const assignment = definition.hir.assignment(definition.hir.simpleCommandParts(command)[0]);
    return definition.hir.wordPart(definition.hir.wordParts(assignment.value)[0]);
}

fn storeWithAllocator(gpa: std.mem.Allocator) !void {
    var hir = try generate("build() { value=first; }");
    defer hir.deinit(std.testing.allocator);
    const definition = hir.functionDefinition(firstCommand(hir));
    var functions = FunctionStore.init(gpa);
    defer functions.deinit();
    try functions.set(definition.name, hir, definition.body);
    var copy = try functions.clone(gpa);
    defer copy.deinit();
    var snapshot = (try copy.cloneDefinition("build", gpa)).?;
    defer snapshot.deinit(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
