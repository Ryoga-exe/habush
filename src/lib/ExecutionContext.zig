//! Owned execution settings shared by commands in one shell session.
//!
//! The standard streams are borrowed; their writers must outlive executions
//! that use this context. Directory and sandbox values are owned by the context.

const std = @import("std");
const CommandPlan = @import("CommandPlan.zig");
const Io = @import("runtime/Io.zig");
const ExecutionContext = @This();

gpa: std.mem.Allocator,
cwd: ?[]u8,
sandbox: CommandPlan.Sandbox,
io: Io,

pub const View = struct {
    cwd: ?[]const u8 = null,
    sandbox: CommandPlan.Sandbox = .inherit,
    io: Io = .{},
};

/// A borrowed mutable context, or a read-only view for one execution.
pub const Ref = union(enum) {
    view: View,
    mutable: *ExecutionContext,

    pub fn get(ref: Ref) View {
        return switch (ref) {
            .view => |value| value,
            .mutable => |context| context.view(),
        };
    }

    pub fn clone(ref: Ref, gpa: std.mem.Allocator) std.mem.Allocator.Error!ExecutionContext {
        return ExecutionContext.init(gpa, ref.get());
    }
};

pub fn init(gpa: std.mem.Allocator, options: View) std.mem.Allocator.Error!ExecutionContext {
    const cwd = if (options.cwd) |path| try gpa.dupe(u8, path) else null;
    errdefer if (cwd) |path| gpa.free(path);
    return .{
        .gpa = gpa,
        .cwd = cwd,
        .sandbox = try options.sandbox.clone(gpa),
        .io = options.io,
    };
}

pub fn clone(context: ExecutionContext) std.mem.Allocator.Error!ExecutionContext {
    return init(context.gpa, context.view());
}

pub fn deinit(context: *ExecutionContext) void {
    if (context.cwd) |cwd| context.gpa.free(cwd);
    context.sandbox.deinit(context.gpa);
    context.* = undefined;
}

pub fn view(context: ExecutionContext) View {
    return .{
        .cwd = context.cwd,
        .sandbox = context.sandbox,
        .io = context.io,
    };
}

pub fn allocator(context: ExecutionContext) std.mem.Allocator {
    return context.gpa;
}

pub fn workingDirectory(context: ExecutionContext) ?[]const u8 {
    return context.cwd;
}

pub fn activeSandbox(context: ExecutionContext) CommandPlan.Sandbox {
    return context.sandbox;
}

pub fn setWorkingDirectory(
    context: *ExecutionContext,
    cwd: ?[]const u8,
) std.mem.Allocator.Error!void {
    const copy = if (cwd) |path| try context.gpa.dupe(u8, path) else null;
    context.replaceWorkingDirectoryOwned(copy);
}

/// Takes ownership of `cwd`. Callers can allocate it before preparing other
/// state, then commit a directory change without further allocation.
pub fn replaceWorkingDirectoryOwned(context: *ExecutionContext, cwd: ?[]u8) void {
    if (context.cwd) |previous| context.gpa.free(previous);
    context.cwd = cwd;
}

pub fn setSandbox(
    context: *ExecutionContext,
    sandbox: CommandPlan.Sandbox,
) std.mem.Allocator.Error!void {
    const copy = try sandbox.clone(context.gpa);
    context.sandbox.deinit(context.gpa);
    context.sandbox = copy;
}

test "execution context owns directory and sandbox while borrowing IO" {
    const SandboxPolicy = @import("SandboxPolicy.zig");
    var cwd = [_]u8{ '/', 'o', 'l', 'd' };
    var allowed = [_]u8{ '/', 'o', 'l', 'd' };
    const rules = [_]SandboxPolicy.PathRule{
        .{ .path = &allowed, .access = .{ .read = true } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var context = try ExecutionContext.init(std.testing.allocator, .{
        .cwd = &cwd,
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &rules } } },
        .io = .{ .stdout = &output.writer },
    });
    defer context.deinit();

    cwd[1] = 'x';
    allowed[1] = 'x';
    try std.testing.expectEqualStrings("/old", context.workingDirectory().?);
    try std.testing.expectEqualStrings(
        "/old",
        context.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expect(context.view().io.stdout.? == &output.writer);

    var copy = try context.clone();
    defer copy.deinit();
    try copy.setWorkingDirectory("/new");
    try copy.setSandbox(.inherit);
    try std.testing.expectEqualStrings("/old", context.workingDirectory().?);
    try std.testing.expectEqualStrings("/new", copy.workingDirectory().?);
    try std.testing.expectEqualStrings(
        "/old",
        context.activeSandbox().restrict.file_system.allow[0].path,
    );
    try std.testing.expect(copy.view().io.stdout.? == &output.writer);

    const mutable_ref: Ref = .{ .mutable = &context };
    const view_ref: Ref = .{ .view = copy.view() };
    try std.testing.expectEqualStrings("/old", mutable_ref.get().cwd.?);
    var cloned_view = try view_ref.clone(std.testing.allocator);
    defer cloned_view.deinit();
    try std.testing.expectEqualStrings("/new", cloned_view.workingDirectory().?);
}

test "execution context updates handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseContextAllocations,
        .{},
    );
}

fn exerciseContextAllocations(gpa: std.mem.Allocator) !void {
    const SandboxPolicy = @import("SandboxPolicy.zig");
    const original_rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/original", .access = .{ .read = true } },
    };
    var context = try ExecutionContext.init(gpa, .{
        .cwd = "/old",
        .sandbox = .{ .restrict = .{ .file_system = .{ .allow = &original_rules } } },
    });
    defer context.deinit();

    var copy = context.clone() catch |err| {
        try std.testing.expectEqualStrings("/old", context.workingDirectory().?);
        try std.testing.expectEqualStrings(
            "/original",
            context.activeSandbox().restrict.file_system.allow[0].path,
        );
        return err;
    };
    defer copy.deinit();

    const replacement_rules = [_]SandboxPolicy.PathRule{
        .{ .path = "/replacement", .access = .{ .read = true, .write = true } },
        .{ .path = "/another", .access = .{ .execute = true } },
    };
    const network_rules = [_]SandboxPolicy.NetworkRule{
        .{ .protocol = .tcp, .operation = .connect, .ports = .{ .first = 80, .last = 80 } },
    };
    context.setSandbox(.{ .restrict = .{
        .file_system = .{ .allow = &replacement_rules },
        .network = .{ .allow = &network_rules },
    } }) catch |err| {
        try std.testing.expectEqualStrings(
            "/original",
            context.activeSandbox().restrict.file_system.allow[0].path,
        );
        return err;
    };
    try std.testing.expectEqualStrings(
        "/original",
        copy.activeSandbox().restrict.file_system.allow[0].path,
    );

    context.setWorkingDirectory("/new") catch |err| {
        try std.testing.expectEqualStrings("/old", context.workingDirectory().?);
        return err;
    };
    try std.testing.expectEqualStrings("/old", copy.workingDirectory().?);

    const owned = gpa.dupe(u8, "/final") catch |err| {
        try std.testing.expectEqualStrings("/new", context.workingDirectory().?);
        return err;
    };
    context.replaceWorkingDirectoryOwned(owned);
    try std.testing.expectEqualStrings("/final", context.workingDirectory().?);
}

test {
    std.testing.refAllDecls(@This());
}
