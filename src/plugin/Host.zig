//! Core Wasm ABI v0. The embedding application owns modules and call scopes.
//! No WASI is linked. The only import is call-scoped stdout/stderr writing.
const std = @import("std");
const c = @import("wasmtime");
const Host = @This();

io: std.Io,
engine: *c.wasm_engine_t,
ticker: std.Io.Future(void),

pub const Error = std.mem.Allocator.Error || error{
    Canceled,
    Timeout,
    LimitExceeded,
    FuelExhausted,
    InvalidModule,
    InvalidAbi,
    InstantiationFailed,
    InvalidResponse,
    InvalidRequest,
    PermissionDenied,
    WriteFailed,
    Trap,
};

pub const Limits = struct {
    fuel: u64 = 10_000_000,
    memory_bytes: u32 = 16 * 1024 * 1024,
    request_bytes: u32 = 64 * 1024,
    response_bytes: u32 = 64 * 1024,
    output_bytes: u32 = 1024 * 1024,
    timeout: ?std.Io.Duration = .fromMilliseconds(100),
};

/// A writer is an explicit grant for this call, not a process-global stream.
/// Borrowed writers must stay alive and obey cancellation for the whole call.
pub const Scope = struct {
    limits: Limits = .{},
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
};

pub fn init(io: std.Io) (std.Io.ConcurrentError || error{OutOfMemory})!Host {
    const config = c.wasm_config_new() orelse return error.OutOfMemory;
    c.wasmtime_config_consume_fuel_set(config, true);
    c.wasmtime_config_epoch_interruption_set(config, true);
    c.wasmtime_config_wasm_threads_set(config, false);
    c.wasmtime_config_wasm_memory64_set(config, false);
    const engine = c.wasm_engine_new_with_config(config) orelse return error.OutOfMemory;
    errdefer c.wasm_engine_delete(engine);
    return .{ .io = io, .engine = engine, .ticker = try io.concurrent(tick, .{ io, engine }) };
}

/// All modules and calls must have ended before destroying their host.
pub fn deinit(host: *Host) void {
    host.ticker.cancel(host.io);
    c.wasm_engine_delete(host.engine);
    host.* = undefined;
}

fn tick(io: std.Io, engine: *c.wasm_engine_t) void {
    while (true) {
        io.sleep(.fromMilliseconds(5), .awake) catch return;
        c.wasmtime_engine_increment_epoch(engine);
    }
}

/// Compilation does not instantiate the guest or run its start function.
/// Compile time/RSS are separate from the per-call limits below.
pub fn load(host: *Host, bytes: []const u8) Error!Module {
    if (bytes.len > 4 * 1024 * 1024) return error.LimitExceeded;
    try host.io.checkCancel();
    var module: ?*c.wasmtime_module_t = null;
    if (c.wasmtime_module_new(host.engine, bytes.ptr, bytes.len, &module)) |failure| {
        c.wasmtime_error_delete(failure);
        return error.InvalidModule;
    }
    errdefer c.wasmtime_module_delete(module.?);
    try host.io.checkCancel();
    return .{ .host = host, .module = module.? };
}

pub const Module = struct {
    host: *Host,
    module: *c.wasmtime_module_t,

    /// Calls borrow the module. The caller joins them before deinit/unload.
    pub fn deinit(module: *Module) void {
        c.wasmtime_module_delete(module.module);
        module.* = undefined;
    }

    /// v0: version()->i32, alloc(i32)->i32, entry(i32,i32)->i64.
    /// The entry's result packs response pointer in low32, byte length in high32.
    /// Replies are copied before destroying the fresh instance, including on trap.
    pub fn invoke(module: *const Module, gpa: std.mem.Allocator, entry: []const u8, request: []const u8, scope: Scope) Error![]u8 {
        const host = module.host;
        try host.io.checkCancel();
        if (request.len > scope.limits.request_bytes) return error.LimitExceeded;
        var call: Call = .{
            .io = host.io,
            .scope = scope,
            .deadline = if (scope.limits.timeout) |duration| std.Io.Timestamp.now(host.io, .awake).addDuration(duration) else null,
        };
        const store = c.wasmtime_store_new(host.engine, null, null) orelse return error.OutOfMemory;
        defer c.wasmtime_store_delete(store);
        const context = c.wasmtime_store_context(store).?;
        c.wasmtime_store_limiter(store, scope.limits.memory_bytes, 1024, 1, 1, 1);
        if (c.wasmtime_context_set_fuel(context, scope.limits.fuel)) |failure| {
            c.wasmtime_error_delete(failure);
            return error.InvalidAbi;
        }
        c.wasmtime_store_epoch_deadline_callback(store, epoch, &call, null);
        c.wasmtime_context_set_epoch_deadline(context, 1);
        const linker = c.wasmtime_linker_new(host.engine) orelse return error.OutOfMemory;
        defer c.wasmtime_linker_delete(linker);
        try defineWrite(linker, &call);
        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_linker_instantiate(linker, context, module.module, &instance, &trap);
        try call.check(failure, trap, error.InstantiationFailed);
        if (try call.function(context, &instance, "habush_version", &.{}, c.WASMTIME_I32) != 0) return error.InvalidAbi;
        const pointer = try call.function(context, &instance, "habush_alloc", &.{i32Value(@intCast(request.len))}, c.WASMTIME_I32);
        const input = try instanceBytes(context, &instance, @intCast(pointer), request.len);
        @memcpy(input, request);
        const response_range = try call.function(context, &instance, entry, &.{ i32Value(@intCast(pointer)), i32Value(@intCast(request.len)) }, c.WASMTIME_I64);
        const length: u32 = @truncate(response_range >> 32);
        if (length > scope.limits.response_bytes) return error.LimitExceeded;
        const response = try instanceBytes(context, &instance, @truncate(response_range), length);
        try call.checkpoint();
        return gpa.dupe(u8, response);
    }
};

const Call = struct {
    io: std.Io,
    scope: Scope,
    deadline: ?std.Io.Timestamp,
    failure: ?Error = null,
    written: usize = 0,

    fn checkpoint(call: *Call) Error!void {
        try call.io.checkCancel();
        if (call.deadline) |deadline|
            if (std.Io.Timestamp.now(call.io, .awake).nanoseconds >= deadline.nanoseconds) return error.Timeout;
    }

    fn check(call: *Call, failure: ?*c.wasmtime_error_t, trap: ?*c.wasm_trap_t, fallback: Error) Error!void {
        defer if (failure) |value| c.wasmtime_error_delete(value);
        defer if (trap) |value| c.wasm_trap_delete(value);
        if (call.failure) |value| return value;
        try call.checkpoint();
        if (trap) |value| {
            var code: c.wasmtime_trap_code_t = undefined;
            if (c.wasmtime_trap_code(value, &code) and code == c.WASMTIME_TRAP_CODE_OUT_OF_FUEL) return error.FuelExhausted;
            return error.Trap;
        }
        if (failure != null) return fallback;
    }

    fn function(call: *Call, context: *c.wasmtime_context_t, instance: *const c.wasmtime_instance_t, name: []const u8, args: []const c.wasmtime_val_t, kind: u8) Error!u64 {
        var exported: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(context, instance, name.ptr, name.len, &exported)) return error.InvalidAbi;
        defer c.wasmtime_extern_delete(&exported);
        if (exported.kind != c.WASMTIME_EXTERN_FUNC) return error.InvalidAbi;
        var result: c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_func_call(context, &exported.of.func, args.ptr, args.len, &result, 1, &trap);
        defer if (failure == null and trap == null) c.wasmtime_val_unroot(&result);
        try call.check(failure, trap, error.InvalidAbi);
        if (result.kind != kind) return error.InvalidAbi;
        return if (kind == c.WASMTIME_I32) @as(u32, @bitCast(result.of.i32)) else @as(u64, @bitCast(result.of.i64));
    }
};

fn epoch(_: ?*const c.wasmtime_context_t, data: ?*anyopaque, delta: [*c]u64, update: [*c]c.wasmtime_update_deadline_kind_t) callconv(.c) ?*c.wasmtime_error_t {
    const call: *Call = @ptrCast(@alignCast(data.?));
    call.checkpoint() catch |err| {
        call.failure = err;
        return c.wasmtime_error_new("habush: plugin call stopped");
    };
    delta.* = 1;
    update.* = c.WASMTIME_UPDATE_DEADLINE_CONTINUE;
    return null;
}

fn i32Value(value: u32) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = @bitCast(value) } };
}

fn memoryBytes(context: *c.wasmtime_context_t, memory: *const c.wasmtime_memory_t, start: u32, length: usize) Error![]u8 {
    const size = c.wasmtime_memory_data_size(context, memory);
    if (start > size or length > size - start) return error.InvalidResponse;
    return c.wasmtime_memory_data(context, memory)[start..][0..length];
}

fn instanceBytes(context: *c.wasmtime_context_t, instance: *const c.wasmtime_instance_t, start: u32, length: usize) Error![]u8 {
    var exported: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(context, instance, "memory", 6, &exported)) return error.InvalidAbi;
    defer c.wasmtime_extern_delete(&exported);
    if (exported.kind != c.WASMTIME_EXTERN_MEMORY) return error.InvalidAbi;
    return memoryBytes(context, &exported.of.memory, start, length);
}

fn defineWrite(linker: *c.wasmtime_linker_t, call: *Call) Error!void {
    var parameters: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_uninitialized(&parameters, 3);
    for (0..3) |index| parameters.data[index] = c.wasm_valtype_new(c.WASM_I32);
    var results: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_uninitialized(&results, 1);
    results.data[0] = c.wasm_valtype_new(c.WASM_I32);
    const signature = c.wasm_functype_new(&parameters, &results) orelse return error.OutOfMemory;
    defer c.wasm_functype_delete(signature);
    if (c.wasmtime_linker_define_func(linker, "habush", 6, "write", 5, signature, write, call, null)) |failure| {
        c.wasmtime_error_delete(failure);
        return error.InvalidAbi;
    }
}

fn write(data: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, _: usize, results: [*c]c.wasmtime_val_t, _: usize) callconv(.c) ?*c.wasm_trap_t {
    const call: *Call = @ptrCast(@alignCast(data.?));
    const length = writeBytes(call, caller.?, @bitCast(args[0].of.i32), @bitCast(args[1].of.i32), @bitCast(args[2].of.i32)) catch |err| {
        call.failure = err;
        return c.wasmtime_trap_new("habush: plugin write failed", 27);
    };
    results[0] = i32Value(length);
    return null;
}

fn writeBytes(call: *Call, caller: *c.wasmtime_caller_t, descriptor: u32, pointer: u32, length: u32) Error!u32 {
    try call.checkpoint();
    const writer = (switch (descriptor) {
        1 => call.scope.stdout,
        2 => call.scope.stderr,
        else => null,
    }) orelse return error.PermissionDenied;
    if (length > call.scope.limits.output_bytes -| call.written) return error.LimitExceeded;
    var exported: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", 6, &exported)) return error.InvalidAbi;
    defer c.wasmtime_extern_delete(&exported);
    if (exported.kind != c.WASMTIME_EXTERN_MEMORY) return error.InvalidAbi;
    const bytes = try memoryBytes(c.wasmtime_caller_context(caller).?, &exported.of.memory, pointer, length);
    try writer.writeAll(bytes);
    call.written += length;
    return length;
}

test {
    _ = @import("host_test.zig");
}
