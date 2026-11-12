//! CLI-owned modules and adapters. Config strings outlive this registry.
const std = @import("std");
const habush = @import("habush");
const wasm = @import("habush-plugin");
const Config = @import("Config.zig");
const Plugins = @This();

gpa: std.mem.Allocator,
io: std.Io,
host: ?wasm.Host = null,
modules: std.ArrayList(wasm.Host.Module) = .empty,
entries: []Entry = &.{},
commands: []habush.Command = &.{},
completions: []Completion = &.{},
loading_path: ?[]const u8 = null,

pub const Completion = struct {
    command: []const u8,
    provider: habush.Completion.Provider,
};

const Entry = struct {
    module: *const wasm.Host.Module,
    entry: []const u8,
    limits: wasm.Host.Limits,
};

/// The registry stays at this address until all Session/input tasks have ended.
pub fn load(plugins: *Plugins, specs: []const Config.Plugin) !void {
    if (specs.len == 0) return;
    plugins.host = try wasm.Host.init(plugins.io);
    var count: usize = 0;
    var completion_count: usize = 0;
    for (specs) |spec| {
        count += spec.commands.len;
        completion_count += spec.completions.len;
    }
    plugins.entries = try plugins.gpa.alloc(Entry, count + completion_count);
    plugins.commands = try plugins.gpa.alloc(habush.Command, count);
    plugins.completions = try plugins.gpa.alloc(Completion, completion_count);
    try plugins.modules.ensureTotalCapacity(plugins.gpa, specs.len);
    var index: usize = 0;
    var command_index: usize = 0;
    var completion_index: usize = 0;
    for (specs) |spec| {
        plugins.loading_path = spec.path;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(plugins.io, spec.path, plugins.gpa, .limited(4 * 1024 * 1024));
        defer plugins.gpa.free(bytes);
        plugins.modules.appendAssumeCapacity(try plugins.host.?.load(bytes));
        const module = &plugins.modules.items[plugins.modules.items.len - 1];
        const limits: wasm.Host.Limits = .{
            .fuel = spec.fuel,
            .memory_bytes = spec.memory_bytes,
            .timeout = .fromMilliseconds(spec.timeout_ms),
        };
        for (spec.commands) |command| {
            plugins.entries[index] = .{
                .module = module,
                .entry = command.entry,
                .limits = limits,
            };
            plugins.commands[command_index] = .{ .name = command.name, .userdata = &plugins.entries[index], .run = run };
            command_index += 1;
            index += 1;
        }
        for (spec.completions) |completion| {
            plugins.entries[index] = .{ .module = module, .entry = completion.entry, .limits = limits };
            plugins.completions[completion_index] = .{
                .command = completion.command,
                .provider = .{ .userdata = &plugins.entries[index], .complete = completeArguments },
            };
            completion_index += 1;
            index += 1;
        }
    }
    plugins.loading_path = null;
}

pub fn deinit(plugins: *Plugins) void {
    plugins.gpa.free(plugins.commands);
    plugins.gpa.free(plugins.completions);
    plugins.gpa.free(plugins.entries);
    for (plugins.modules.items) |*module| module.deinit();
    plugins.modules.deinit(plugins.gpa);
    if (plugins.host) |*host| host.deinit();
    plugins.* = undefined;
}

fn run(userdata: ?*anyopaque, context: habush.Command.Context, argv: []const []const u8) habush.Command.Error!habush.Command.Outcome {
    const entry: *const Entry = @ptrCast(@alignCast(userdata.?));
    const status = wasm.command.run(entry.module, context.gpa, entry.entry, argv, .{
        .limits = entry.limits,
        .stdin = context.io.stdin,
        .stdout = context.io.stdout,
        .stderr = context.io.stderr,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.Timeout => return .{ .failed = .timeout },
        error.LimitExceeded, error.FuelExhausted => return .{ .failed = .limit_exceeded },
        error.PermissionDenied => return .{ .failed = .permission_denied },
        error.ReadFailed, error.WriteFailed => return .{ .failed = .io },
        error.Trap => return .{ .failed = .trap },
        error.InstantiationFailed => return .{ .failed = .unavailable },
        error.InvalidAbi, error.InvalidModule, error.InvalidRequest, error.InvalidResponse => return .{ .failed = .invalid_response },
    };
    return .{ .exited = status };
}

pub fn provider(plugins: *Plugins) habush.Completion.Provider {
    return .{ .userdata = plugins, .complete = completeCommandNames };
}

fn completeCommandNames(userdata: ?*anyopaque, request: habush.Completion.Provider.Request, collector: *habush.Completion.Provider.Collector) habush.Completion.Provider.Error!void {
    const plugins: *Plugins = @ptrCast(@alignCast(userdata.?));
    if (request.context.kind != .command) return;
    for (plugins.commands) |command| {
        if (!collector.step()) return;
        if (std.mem.startsWith(u8, command.name, request.prefix))
            if (!try collector.add(.{ .value = command.name, .kind = .command })) return;
    }
}

fn completeArguments(userdata: ?*anyopaque, request: habush.Completion.Provider.Request, collector: *habush.Completion.Provider.Collector) habush.Completion.Provider.Error!void {
    const entry: *const Entry = @ptrCast(@alignCast(userdata.?));
    if (request.context.kind != .argument) return;
    var scratch: std.heap.ArenaAllocator = .init(collector.gpa);
    defer scratch.deinit();
    const args = request.context.literalArguments(scratch.allocator()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedContext => return,
    };
    if (args.len == 0) return;
    var limits = entry.limits;
    const hundred_ms: std.Io.Duration = .fromMilliseconds(100);
    if (limits.timeout.?.nanoseconds > hundred_ms.nanoseconds) limits.timeout = hundred_ms;
    var result = wasm.completion.collect(entry.module, collector.gpa, entry.entry, request.prefix, args, .{
        .limits = limits,
    }, std.math.cast(u32, collector.limits.candidates) orelse std.math.maxInt(u32)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Unavailable,
    };
    defer result.deinit(collector.gpa);
    for (result.values) |value| {
        if (!collector.step() or !try collector.add(.{ .value = value })) return;
    }
}
