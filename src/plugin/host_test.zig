const std = @import("std");
const c = @import("wasmtime");
const Host = @import("Host.zig");
const command = @import("command.zig");
const completion = @import("completion.zig");

const fixture =
    \\(module
    \\ (import "habush" "write" (func $write (param i32 i32 i32) (result i32)))
    \\ (import "habush" "read" (func $read (param i32 i32 i32) (result i32)))
    \\ (memory (export "memory") 1)
    \\ (data (i32.const 0) "\07choice")
    \\ (data (i32.const 32) "\01\00\00\00\08\00\00\00a b'$(x)")
    \\ (func (export "habush_version") (result i32) i32.const 0)
    \\ (func (export "habush_alloc") (param i32) (result i32) i32.const 4096)
    \\ (func (export "command") (param i32 i32) (result i64)
    \\   i32.const 1 local.get 0 local.get 1 call $write drop
    \\   i64.const 4294967296)
    \\ (func (export "complete") (param i32 i32) (result i64)
    \\   i64.const 25769803777)
    \\ (func (export "candidates") (param i32 i32) (result i64)
    \\   i64.const 68719476768)
    \\ (func (export "read_echo") (param i32 i32) (result i64) (local $n i32)
    \\   i32.const 0 i32.const 1024 i32.const 32 call $read local.set $n
    \\   i32.const 1 i32.const 1024 local.get $n call $write drop
    \\   i64.const 4294967296)
    \\ (func (export "run") (param i32 i32) (result i64)
    \\   local.get 0 i32.load i32.const 2 i32.ne if unreachable end
    \\   i32.const 1 local.get 0 i32.const 16 i32.add
    \\   local.get 0 i32.const 12 i32.add i32.load call $write drop
    \\   i64.const 4294967296)
    \\ (func (export "spin") (param i32 i32) (result i64)
    \\   (loop $again br $again) i64.const 0)
    \\ (func (export "spinning") (param i32 i32) (result i64)
    \\   i32.const 1 i32.const 0 i32.const 1 call $write drop
    \\   (loop $again br $again) i64.const 0)
    \\ (func (export "trap") (param i32 i32) (result i64) unreachable)
    \\ (func (export "bad_pointer") (param i32 i32) (result i64) i64.const 8589934591)
    \\ (func (export "oversized") (param i32 i32) (result i64) i64.const 281479271677952)
    \\ (func (export "bad_type") (param i32 i32) (result i32) i32.const 0)
    \\ (func (export "grow") (param i32 i32) (result i64)
    \\   i32.const 1 memory.grow i32.const -1 i32.ne if unreachable end
    \\   i64.const 0))
;

fn load(host: *Host, wat: []const u8) !Host.Module {
    var wasm: c.wasm_byte_vec_t = undefined;
    if (c.wasmtime_wat2wasm(wat.ptr, wat.len, &wasm)) |failure| {
        c.wasmtime_error_delete(failure);
        return error.InvalidFixture;
    }
    defer c.wasm_byte_vec_delete(&wasm);
    return host.load(wasm.data[0..wasm.size]);
}

test "one module serves command and completion with call-scoped streams" {
    const gpa = std.testing.allocator;
    var host = try Host.init(std.testing.io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const status = try module.invoke(gpa, "command", "hello\n", .{ .stdout = &output.writer });
    defer gpa.free(status);
    try std.testing.expectEqualSlices(u8, &.{7}, status);
    try std.testing.expectEqualStrings("hello\n", output.written());
    const choices = try module.invoke(gpa, "complete", "ch", .{});
    defer gpa.free(choices);
    try std.testing.expectEqualStrings("choice", choices);
    try std.testing.expectError(error.PermissionDenied, module.invoke(gpa, "command", "denied", .{}));
    try std.testing.expectEqualStrings("hello\n", output.written());
    const again = try module.invoke(gpa, "command", "again", .{ .stdout = &output.writer });
    defer gpa.free(again);
    try std.testing.expectEqualStrings("hello\nagain", output.written());
    output.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 7), try command.run(&module, gpa, "run", &.{ "demo", "a b" }, .{ .stdout = &output.writer }));
    try std.testing.expectEqualStrings("a b", output.written());
    var candidates = try completion.collect(&module, gpa, "candidates", "a", &.{"demo"}, .{}, 128);
    defer candidates.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), candidates.values.len);
    try std.testing.expectEqualStrings("a b'$(x)", candidates.values[0]);
    try std.testing.expectError(error.InvalidResponse, command.run(&module, gpa, "complete", &.{"demo"}, .{}));
    try std.testing.expectError(error.LimitExceeded, completion.collect(&module, gpa, "candidates", "a", &.{"demo"}, .{}, 0));
    var input: std.Io.Reader = .fixed("data");
    input.vtable = std.Io.Reader.failing.vtable;
    output.clearRetainingCapacity();
    const read_reply = try module.invoke(gpa, "read_echo", "", .{ .stdin = &input, .stdout = &output.writer });
    defer gpa.free(read_reply);
    try std.testing.expectEqualStrings("data", output.written());
    try std.testing.expectEqual(@as(usize, 0), input.bufferedLen());
    try std.testing.expectError(error.PermissionDenied, module.invoke(gpa, "read_echo", "", .{ .stdout = &output.writer }));
    input = .fixed("data");
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "read_echo", "", .{ .stdin = &input, .limits = .{ .input_bytes = 1 } }));
    try std.testing.expectEqual(@as(usize, 4), input.bufferedLen());
}

test "guest failure, memory bounds and budgets do not poison the module" {
    const gpa = std.testing.allocator;
    var host = try Host.init(std.testing.io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    try std.testing.expectError(error.InvalidModule, host.load("not wasm"));
    for ([_]struct { []const u8, Host.Error }{
        .{ "trap", error.Trap },
        .{ "spin", error.FuelExhausted },
        .{ "bad_pointer", error.InvalidResponse },
        .{ "oversized", error.LimitExceeded },
        .{ "bad_type", error.InvalidAbi },
        .{ "missing", error.InvalidAbi },
    }) |case| try std.testing.expectError(case[1], module.invoke(gpa, case[0], "", .{ .limits = .{ .fuel = 1_000_000, .timeout = .fromSeconds(2) } }));
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "complete", "long", .{ .limits = .{ .request_bytes = 1 } }));
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "command", "long", .{ .stdout = &output.writer, .limits = .{ .output_bytes = 1 } }));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    const limited = try module.invoke(gpa, "grow", "", .{ .limits = .{ .memory_bytes = 65536 } });
    defer gpa.free(limited);
    try std.testing.expectError(error.InstantiationFailed, module.invoke(gpa, "complete", "", .{ .limits = .{ .memory_bytes = 1 } }));
    const choices = try module.invoke(gpa, "complete", "", .{});
    defer gpa.free(choices);
    try std.testing.expectEqualStrings("choice", choices);
}

const Progress = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    entered: std.atomic.Value(bool) = .init(false),

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const progress: *Progress = @fieldParentPtr("writer", writer);
        progress.entered.store(true, .release);
        return std.Io.Writer.countSplat(data, splat);
    }
};

fn spin(module: *const Host.Module, progress: *Progress) ![]u8 {
    return module.invoke(std.testing.allocator, "spinning", "", .{
        .stdout = &progress.writer,
        .limits = .{ .fuel = std.math.maxInt(u64), .timeout = .fromSeconds(5) },
    });
}

test "epochs enforce deadlines and cancel a running guest, including initialization" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = try Host.init(io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    try std.testing.expectError(error.Timeout, module.invoke(gpa, "spin", "", .{ .limits = .{ .fuel = std.math.maxInt(u64), .timeout = .fromMilliseconds(15) } }));
    var progress: Progress = .{};
    var task = try io.concurrent(spin, .{ &module, &progress });
    defer {
        const leftover: ?[]u8 = task.cancel(io) catch null;
        if (leftover) |bytes| gpa.free(bytes);
    }
    for (0..1000) |_| {
        if (progress.entered.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(progress.entered.load(.acquire));
    try std.testing.expectError(error.Canceled, task.cancel(io));
    var startup = try load(&host,
        \\(module
        \\ (func $start (loop $again br $again))
        \\ (start $start))
    );
    defer startup.deinit();
    try std.testing.expectError(error.Timeout, startup.invoke(gpa, "unused", "", .{ .limits = .{ .fuel = std.math.maxInt(u64), .timeout = .fromMilliseconds(15) } }));
    const choices = try module.invoke(gpa, "complete", "", .{});
    defer gpa.free(choices);
    try std.testing.expectEqualStrings("choice", choices);
}
