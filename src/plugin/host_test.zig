const std = @import("std");
const c = @import("wasmtime");
const Host = @import("Host.zig");
const command = @import("command.zig");
const completion = @import("completion.zig");
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

const fixture =
    \\(module
    \\ (import "habush" "write" (func $write (param i32 i32 i32) (result i32)))
    \\ (import "habush" "read" (func $read (param i32 i32 i32) (result i32)))
    \\ (import "habush" "option" (func $option (param i32 i32 i32 i32) (result i32)))
    \\ (import "habush" "read_file" (func $read_file (param i32 i32 i32 i32) (result i32)))
    \\ (import "habush" "capabilities" (func $capabilities (result i32)))
    \\ (memory (export "memory") 1)
    \\ (data (i32.const 0) "\07choice")
    \\ (data (i32.const 32) "\01\00\00\00\08\00\00\00a b'$(x)")
    \\ (data (i32.const 128) "symbol")
    \\ (data (i32.const 512) "\02\00\00\00\03\00\00\00000\04\00\00\00safe")
    \\ (func (export "habush_version") (result i32) i32.const 0)
    \\ (func (export "habush_alloc") (param i32) (result i32) i32.const 4096)
    \\ (func (export "command") (param i32 i32) (result i64)
    \\   i32.const 1 local.get 0 local.get 1 call $write drop
    \\   i64.const 4294967296)
    \\ (func (export "complete") (param i32 i32) (result i64)
    \\   i64.const 25769803777)
    \\ (func (export "option") (param i32 i32) (result i64) (local $n i32) (local $out i32)
    \\   local.get 0 i32.load local.set $out
    \\   i32.const 128 i32.const 6 local.get $out i32.const 64 call $option local.set $n
    \\   local.get $n i32.const 0 i32.lt_s if (result i64) i64.const 0 else
    \\     local.get $n i64.extend_i32_u i64.const 32 i64.shl local.get $out i64.extend_i32_u i64.or end)
    \\ (func (export "read_file") (param i32 i32) (result i64) (local $n i32)
    \\   local.get 0 local.get 1 i32.const 1024 i32.const 64 call $read_file local.set $n
    \\   local.get $n i32.const 0 i32.lt_s if
    \\     i32.const 1024 local.get $n i32.store i32.const 4 local.set $n end
    \\   local.get $n i64.extend_i32_u i64.const 32 i64.shl i64.const 1024 i64.or)
    \\ (func (export "bad_file_pointer") (param i32 i32) (result i64)
    \\   local.get 0 local.get 1 i32.const 65535 i32.const 64 call $read_file drop i64.const 0)
    \\ (func (export "capabilities") (param i32 i32) (result i64)
    \\   i32.const 1024 call $capabilities i32.store8 i64.const 4294968320)
    \\ (func (export "redacted_prompt") (param i32 i32) (result i64)
    \\   local.get 0 i32.load offset=9 if unreachable end
    \\   local.get 0 i32.load offset=13 if unreachable end
    \\   i64.const 19 i64.const 32 i64.shl i64.const 512 i64.or)
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

fn expectFileStatus(module: *Host.Module, path: []const u8, scope: Host.Scope, expected: i32) !void {
    const bytes = try module.invoke(std.testing.allocator, "read_file", path, scope);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 4), bytes.len);
    try std.testing.expectEqual(expected, std.mem.readInt(i32, bytes[0..4], .little));
}

test "declared file reads require grants and parent scope, redact context, and reject special files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "allowed" });
    var host = try Host.init(io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    module.declared = .{ .fs_read = true };
    module.granted = .{ .fs_read = true };
    const scope: Host.Scope = .{ .capabilities = .{ .permissions = .{ .fs_read = true }, .directory = tmp.dir } };
    try std.testing.expectError(error.InvalidResponse, module.invoke(gpa, "bad_file_pointer", "file", scope));
    var limited = scope;
    limited.limits.input_bytes = 63;
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "read_file", "file", limited));
    const bytes = try module.invoke(gpa, "read_file", "file", scope);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("allowed", bytes);
    const mask = try module.invoke(gpa, "capabilities", "", scope);
    defer gpa.free(mask);
    try std.testing.expectEqualSlices(u8, &.{8}, mask);
    try expectFileStatus(&module, "../outside", scope, -3);
    try expectFileStatus(&module, "missing", scope, -1);
    try tmp.dir.createDir(io, "directory", .default_dir);
    try expectFileStatus(&module, "directory", scope, -2);
    var narrowed = scope;
    narrowed.capabilities = scope.capabilities.narrow(.{}).narrow(.all);
    try expectFileStatus(&module, "file", narrowed, -3);
    try expectFileStatus(&module, "file", .{}, -3);
    try std.testing.expectError(error.PermissionDenied, completion.collect(&module, gpa, "spin", "", &.{}, scope, 128));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const prompt = try @import("prompt.zig").render(&module, arena.allocator(), "redacted_prompt", .{ .cwd = "/private", .status = 7 }, .{});
    try std.testing.expectEqualStrings("safe", prompt.spans[0].text);
    module.granted = .{};
    try expectFileStatus(&module, "file", scope, -3);
    module.granted = .{ .fs_read = true };
    module.declared = .{};
    try expectFileStatus(&module, "file", scope, -3);
    module.declared = .{ .fs_read = true };
    const directory_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(directory_path);
    const absolute_file = try std.fs.path.join(gpa, &.{ directory_path, "file" });
    defer gpa.free(absolute_file);
    const absolute_bytes = try module.invoke(gpa, "read_file", absolute_file, scope);
    defer gpa.free(absolute_bytes);
    try std.testing.expectEqualStrings("allowed", absolute_bytes);
    const fifo_path = try std.fs.path.join(gpa, &.{ directory_path, "pipe" });
    defer gpa.free(fifo_path);
    const fifo_z = try gpa.dupeSentinel(u8, fifo_path, 0);
    defer gpa.free(fifo_z);
    if (mkfifo(fifo_z, 0o600) != 0) return error.CreateFifoFailed;
    var timed = scope;
    try expectFileStatus(&module, "pipe", timed, -3);
    timed.limits.timeout = .fromMilliseconds(0);
    try std.testing.expectError(error.Timeout, module.invoke(gpa, "read_file", "file", timed));
    var unsupported = try load(&host,
        \\(module (import "habush" "write_file" (func)))
    );
    defer unsupported.deinit();
    try std.testing.expectError(error.InstantiationFailed, unsupported.invoke(gpa, "unused", "", scope));
}

test "cwd read roots follow trusted call context and ancestor-only grants retain their mask" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "first/sub");
    try tmp.dir.createDirPath(io, "second");
    try tmp.dir.writeFile(io, .{ .sub_path = "first/file", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second/file", .data = "second" });
    var host = try Host.init(io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    const first = try tmp.dir.realPathFileAlloc(io, "first", gpa);
    defer gpa.free(first);
    const second = try tmp.dir.realPathFileAlloc(io, "second", gpa);
    defer gpa.free(second);
    var scope: Host.Scope = .{ .read_cwd = true, .capabilities = .{ .permissions = .{ .fs_read = true }, .cwd = first } };
    const one = try module.invoke(gpa, "read_file", "file", scope);
    defer gpa.free(one);
    try std.testing.expectEqualStrings("first", one);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.symLink(io, "first", "alias", .{ .is_directory = true });
    const alias = try gpa.print("{s}/alias", .{root});
    defer gpa.free(alias);
    const alias_file = try gpa.print("{s}/file", .{alias});
    defer gpa.free(alias_file);
    scope.capabilities.cwd = alias;
    const aliased = try module.invoke(gpa, "read_file", alias_file, scope);
    defer gpa.free(aliased);
    try std.testing.expectEqualStrings("first", aliased);
    scope.capabilities.cwd = second;
    const two = try module.invoke(gpa, "read_file", "file", scope);
    defer gpa.free(two);
    try std.testing.expectEqualStrings("second", two);
    try expectFileStatus(&module, "../first/file", scope, -3);
    scope.capabilities.cwd = null;
    try expectFileStatus(&module, "file", scope, -3);
    scope.read_cwd = false;
    const sub = try gpa.print("{s}/sub", .{first});
    defer gpa.free(sub);
    scope.capabilities.cwd = sub;
    scope.capabilities.ancestor_files = .{ .within = tmp.dir, .files = &.{"file"} };
    const mask = try module.invoke(gpa, "capabilities", "", scope);
    defer gpa.free(mask);
    try std.testing.expectEqualSlices(u8, &.{8}, mask);
    const parent_file = try gpa.print("{s}/file", .{first});
    defer gpa.free(parent_file);
    const parent = try module.invoke(gpa, "read_file", parent_file, scope);
    defer gpa.free(parent);
    try std.testing.expectEqualStrings("first", parent);
    scope.capabilities = scope.capabilities.narrow(.{});
    try expectFileStatus(&module, parent_file, scope, -3);
}

test "plugin options are call-local, bounded, and validate guest memory" {
    const gpa = std.testing.allocator;
    var host = try Host.init(std.testing.io);
    defer host.deinit();
    var module = try load(&host, fixture);
    defer module.deinit();
    const scope: Host.Scope = .{ .options = &.{.{ "symbol", "日本>" }} };
    const request = &[_]u8{ 0, 1, 0, 0 };
    const value = try module.invoke(gpa, "option", request, scope);
    defer gpa.free(value);
    try std.testing.expectEqualStrings("日本>", value);
    const missing = try module.invoke(gpa, "option", request, .{});
    defer gpa.free(missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    try std.testing.expectError(error.InvalidResponse, module.invoke(gpa, "option", &.{ 255, 255, 0, 0 }, scope));
    const long: [4096]u8 = @splat('x');
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "option", request, .{ .options = &.{.{ "symbol", long[0..65] }} }));
    try std.testing.expectError(error.LimitExceeded, module.invoke(gpa, "option", request, .{ .options = &.{.{ "symbol", &long }} }));
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
