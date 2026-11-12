//! CLI-owned modules and adapters. Config strings outlive this registry.
const std = @import("std");
const habush = @import("habush");
const wasm = @import("habush-plugin");
const Config = @import("Config.zig");
const edit = @import("habush-edit");
const Plugins = @This();

gpa: std.mem.Allocator,
io: std.Io,
host: ?wasm.Host = null,
modules: std.ArrayList(wasm.Host.Module) = .empty,
entries: []Entry = &.{},
commands: []habush.Command = &.{},
completions: []Completion = &.{},
prompt: ?edit.Prompt.Provider = null,
diagnostics: []Entry = &.{},
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
    var prompt_count: usize = 0;
    var diagnostic_count: usize = 0;
    for (specs) |spec| {
        count += spec.commands.len;
        completion_count += spec.completions.len;
        prompt_count += @intFromBool(spec.prompt != null);
        diagnostic_count += @intFromBool(spec.diagnostics != null);
    }
    plugins.entries = try plugins.gpa.alloc(Entry, count + completion_count + prompt_count);
    plugins.diagnostics = try plugins.gpa.alloc(Entry, diagnostic_count);
    plugins.commands = try plugins.gpa.alloc(habush.Command, count);
    plugins.completions = try plugins.gpa.alloc(Completion, completion_count);
    try plugins.modules.ensureTotalCapacity(plugins.gpa, specs.len);
    var index: usize = 0;
    var command_index: usize = 0;
    var completion_index: usize = 0;
    var diagnostic_index: usize = 0;
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
        if (spec.prompt) |prompt| {
            plugins.entries[index] = .{ .module = module, .entry = prompt.entry, .limits = limits };
            plugins.prompt = .{ .userdata = &plugins.entries[index], .render = renderPrompt };
            index += 1;
        }
        if (spec.diagnostics) |diagnostic| {
            plugins.diagnostics[diagnostic_index] = .{ .module = module, .entry = diagnostic.entry, .limits = limits };
            diagnostic_index += 1;
        }
    }
    plugins.loading_path = null;
}

pub fn deinit(plugins: *Plugins) void {
    plugins.gpa.free(plugins.commands);
    plugins.gpa.free(plugins.completions);
    plugins.gpa.free(plugins.entries);
    plugins.gpa.free(plugins.diagnostics);
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

fn uiLimits(entry: Entry) wasm.Host.Limits {
    var limits = entry.limits;
    const budget: std.Io.Duration = .fromMilliseconds(100);
    if (limits.timeout == null or limits.timeout.?.nanoseconds > budget.nanoseconds) limits.timeout = budget;
    return limits;
}

fn renderPrompt(userdata: ?*anyopaque, arena: std.mem.Allocator, context: edit.Prompt.Context) edit.Prompt.Error!edit.Prompt {
    const entry: *const Entry = @ptrCast(@alignCast(userdata.?));
    var limits = uiLimits(entry.*);
    limits.response_bytes = 4096;
    return wasm.prompt.render(entry.module, arena, entry.entry, context, .{ .limits = limits }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unavailable,
    };
}

pub fn diagnosticProvider(plugins: *Plugins) edit.Diagnostic.Provider {
    return .{ .userdata = plugins, .query = diagnose };
}

fn diagnose(userdata: ?*anyopaque, arena: std.mem.Allocator, request: edit.Diagnostic.Request) edit.Diagnostic.Error!edit.Diagnostic.Result {
    const plugins: *Plugins = @ptrCast(@alignCast(userdata.?));
    const deadline = std.Io.Timestamp.now(plugins.io, .awake).addDuration(.fromMilliseconds(100));
    var items: std.ArrayList(edit.Diagnostic) = .empty;
    var bytes: usize = 0;
    providers: for (plugins.diagnostics) |entry| {
        const remaining = deadline.nanoseconds - std.Io.Timestamp.now(plugins.io, .awake).nanoseconds;
        if (remaining <= 0) break;
        var limits = uiLimits(entry);
        limits.timeout.?.nanoseconds = @min(limits.timeout.?.nanoseconds, remaining);
        limits.response_bytes = 8192;
        const result = wasm.diagnostic.collect(entry.module, arena, entry.entry, request, .{ .limits = limits }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        for (result.items) |item| {
            if (items.items.len == edit.Diagnostic.max_items or item.message.len > edit.Diagnostic.max_bytes - bytes) break :providers;
            try items.append(arena, item);
            bytes += item.message.len;
        }
    }
    return .{ .revision = request.revision, .items = items.items };
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
    const limits = uiLimits(entry.*);
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
