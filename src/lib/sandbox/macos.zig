//! Profile generation for the explicitly selected macOS Seatbelt launcher.
//!
//! sandbox-exec is deprecated and optional. This adapter deliberately supports
//! bundled rights instead of claiming a mapping for every portable operation.

const std = @import("std");
const builtin = @import("builtin");
const SandboxBackend = @import("../SandboxBackend.zig");
const SandboxPolicy = @import("../SandboxPolicy.zig");

const max_profile_bytes = 32 * 1024;

pub fn prepare(
    gpa: std.mem.Allocator,
    io: std.Io,
    policy: SandboxPolicy,
) SandboxBackend.Error!SandboxBackend.Preparation {
    return prepareProfile(gpa, io, policy) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

fn prepareProfile(
    gpa: std.mem.Allocator,
    io: std.Io,
    policy: SandboxPolicy,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!SandboxBackend.Preparation {
    var profile: std.Io.Writer.Allocating = .init(gpa);
    defer profile.deinit();
    const writer = &profile.writer;
    var unsupported: SandboxBackend.Unsupported = .{};

    // Only requested filesystem/network operations are restricted. This is
    // neither a complete process isolation profile nor an IPC/syscall policy.
    try writer.writeAll("(version 1)\n(allow default)\n");
    switch (policy.file_system) {
        .unrestricted => {},
        .allow => |rules| {
            try writer.writeAll(
                "(deny file-read*)\n(deny file-write*)\n" ++
                    "(deny file-map-executable)\n(deny process-exec)\n",
            );
            for (rules) |rule| {
                if (rule.path[0] != '/') {
                    unsupported.relative_paths = true;
                    continue;
                }
                if (!safePath(rule.path)) {
                    unsupported.path_encoding = true;
                    continue;
                }
                if (!supportedAccess(rule.access)) {
                    unsupported.filesystem_access = true;
                    continue;
                }
                // Seatbelt matches canonical paths. For example /etc is a
                // symlink to /private/etc on macOS. No string-prefix ACL is
                // used here; the resulting rules are enforced by the kernel.
                const path = std.Io.Dir.realPathFileAbsoluteAlloc(io, rule.path, gpa) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        unsupported.unavailable_paths = true;
                        continue;
                    },
                };
                defer gpa.free(path);
                if (!safePath(path)) {
                    unsupported.path_encoding = true;
                    continue;
                }
                if (rule.access.read)
                    try writeRule(writer, "file-read*", rule.scope, path);
                if (rule.access.execute)
                    try writeRule(writer, "process-exec file-map-executable", rule.scope, path);
                if (rule.access.write)
                    try writeRule(writer, "file-write*", rule.scope, path);
                if (profile.written().len > max_profile_bytes) {
                    unsupported.profile_size = true;
                    return .{ .rejected = .{ .coverage = .partial, .unsupported = unsupported } };
                }
            }
        },
    }
    switch (policy.network) {
        .unrestricted => {},
        .allow => |rules| if (rules.len == 0) {
            try writer.writeAll("(deny network*)\n");
        } else {
            // Port-specific TCP/UDP rules need a separately verified mapping.
            // Best effort leaves this category unrestricted and says so.
            unsupported.network_rules = true;
        },
    }

    const assessment: SandboxBackend.Assessment = .{
        .coverage = if (unsupported.any()) .partial else .complete,
        .unsupported = unsupported,
    };
    if (policy.enforcement == .required and unsupported.any())
        return .{ .rejected = assessment };
    return .{ .ready = .{
        .profile = try profile.toOwnedSlice(),
        .assessment = assessment,
    } };
}

fn supportedAccess(access: SandboxPolicy.FileSystemAccess) bool {
    const all_write = access.write and access.create and access.remove and
        access.rename and access.change_metadata;
    const any_write = access.write or access.create or access.remove or
        access.rename or access.change_metadata;
    return access.read == access.enumerate and all_write == any_write and access._ == 0;
}

fn safePath(path: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn writeRule(
    writer: *std.Io.Writer,
    operations: []const u8,
    scope: SandboxPolicy.PathScope,
    path: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("(allow {s} ({s} ", .{
        operations,
        switch (scope) {
            .exact => "literal",
            .subtree => "subpath",
        },
    });
    try writeQuoted(writer, path);
    try writer.writeAll("))\n");
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

test "profile strings quote metacharacters and reject control bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeQuoted(&out.writer, "/tmp/\") (allow default) ; \\ 日本語");
    try std.testing.expectEqualStrings("\"/tmp/\\\") (allow default) ; \\\\ 日本語\"", out.written());
    try std.testing.expect(safePath("/tmp/\"quoted\\path"));
    for ([_][]const u8{ "/tmp/\x00", "/tmp/\x07", "/tmp/\x1b", "/tmp/\n", "/tmp/\xff" }) |path|
        try std.testing.expect(!safePath(path));
}

test "required rejects unsupported grants and best effort reports its subset" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const backend: SandboxBackend = .{ .kind = .macos_seatbelt };
    var policy: SandboxPolicy = .{
        .file_system = .{ .allow = &.{.{ .path = "/", .access = .{ .read = true } }} },
        .network = .{ .allow = &.{.{
            .protocol = .tcp,
            .operation = .connect,
            .ports = .{ .first = 443, .last = 443 },
        }} },
    };
    var required = try backend.prepare(gpa, std.testing.io, policy);
    defer required.deinit(gpa);
    try std.testing.expect(required == .rejected);
    try std.testing.expect(required.rejected.unsupported.filesystem_access);
    try std.testing.expect(required.rejected.unsupported.network_rules);

    policy.enforcement = .best_effort;
    var partial = try backend.prepare(gpa, std.testing.io, policy);
    defer partial.deinit(gpa);
    try std.testing.expect(partial == .ready);
    try std.testing.expectEqual(.partial, partial.ready.assessment.coverage);
    try std.testing.expect(std.mem.indexOf(u8, partial.ready.profile, "(allow file-read*") == null);
    try std.testing.expect(std.mem.indexOf(u8, partial.ready.profile, "(deny file-read*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, partial.ready.profile, "network") == null);
}

test "relative and unavailable paths cannot silently become broad grants" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var result = try (SandboxBackend{ .kind = .macos_seatbelt }).prepare(std.testing.allocator, std.testing.io, .{
        .file_system = .{ .allow = &.{
            .{ .path = "relative", .access = read_execute },
            .{ .path = "/definitely/missing/habush-sandbox-rule", .access = read_execute },
        } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .rejected);
    try std.testing.expect(result.rejected.unsupported.relative_paths);
    try std.testing.expect(result.rejected.unsupported.unavailable_paths);
}

const read_execute: SandboxPolicy.FileSystemAccess = .{
    .read = true,
    .enumerate = true,
    .execute = true,
};

const read_write_execute: SandboxPolicy.FileSystemAccess = .{
    .read = true,
    .enumerate = true,
    .execute = true,
    .write = true,
    .create = true,
    .remove = true,
    .rename = true,
    .change_metadata = true,
};

fn runProfile(profile: []const u8, arguments: []const []const u8) !std.process.RunResult {
    const gpa = std.testing.allocator;
    const argv = try gpa.alloc([]const u8, arguments.len + 3);
    defer gpa.free(argv);
    argv[0] = "/usr/bin/sandbox-exec";
    argv[1] = "-p";
    argv[2] = profile;
    @memcpy(argv[3..], arguments);
    return std.process.run(gpa, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    });
}

fn freeRunResult(result: std.process.RunResult) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "native profile enforces read and write boundaries including a quoted path" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "allowed\";()", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "secret" });
    try tmp.dir.writeFile(io, .{ .sub_path = "allowed\";()/readable", .data = "allowed" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const allowed = try std.fs.path.join(gpa, &.{ root, "allowed\";()" });
    defer gpa.free(allowed);
    const secret = try std.fs.path.join(gpa, &.{ root, "secret" });
    defer gpa.free(secret);
    const readable = try std.fs.path.join(gpa, &.{ allowed, "readable" });
    defer gpa.free(readable);
    const denied_output = try std.fs.path.join(gpa, &.{ root, "denied-output" });
    defer gpa.free(denied_output);
    const allowed_output = try std.fs.path.join(gpa, &.{ allowed, "output" });
    defer gpa.free(allowed_output);
    var prepared = try (SandboxBackend{ .kind = .macos_seatbelt }).prepare(gpa, io, .{
        .file_system = .{ .allow = &.{
            .{ .path = "/", .scope = .exact, .access = read_execute },
            .{ .path = "/bin", .access = read_execute },
            .{ .path = "/usr", .access = read_execute },
            .{ .path = "/System", .access = read_execute },
            .{ .path = allowed, .access = read_write_execute },
        } },
    });
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared == .ready);
    try std.testing.expectEqual(.complete, prepared.ready.assessment.coverage);
    const profile = prepared.ready.profile;

    const read_allowed = try runProfile(profile, &.{ "/bin/cat", readable });
    defer freeRunResult(read_allowed);
    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, read_allowed.term);
    try std.testing.expectEqualStrings("allowed", read_allowed.stdout);

    const read_denied = try runProfile(profile, &.{ "/bin/cat", secret });
    defer freeRunResult(read_denied);
    try std.testing.expect(read_denied.term == .exited and read_denied.term.exited != 0);
    try std.testing.expectEqualStrings("", read_denied.stdout);

    const write_denied = try runProfile(profile, &.{ "/usr/bin/touch", denied_output });
    defer freeRunResult(write_denied);
    try std.testing.expect(write_denied.term == .exited and write_denied.term.exited != 0);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "denied-output", .{}));

    const write_allowed = try runProfile(profile, &.{ "/usr/bin/touch", allowed_output });
    defer freeRunResult(write_allowed);
    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, write_allowed.term);
    _ = try tmp.dir.statFile(io, "allowed\";()/output", .{});
}

test "native network denial blocks an otherwise listening localhost port" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(port);
    const args: []const []const u8 = &.{ "/usr/bin/nc", "-z", "-w", "1", "127.0.0.1", port };
    const baseline = try runProfile("(version 1)(allow default)", args);
    defer freeRunResult(baseline);
    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, baseline.term);

    var prepared = try (SandboxBackend{ .kind = .macos_seatbelt }).prepare(std.testing.allocator, io, .{
        .network = .{ .allow = &.{} },
    });
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(prepared == .ready);
    const blocked = try runProfile(prepared.ready.profile, args);
    defer freeRunResult(blocked);
    try std.testing.expect(blocked.term == .exited and blocked.term.exited != 0);
}

test "profile preparation releases allocations on every failure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareWithAllocator, .{});
}

fn prepareWithAllocator(gpa: std.mem.Allocator) !void {
    var prepared = try (SandboxBackend{ .kind = .macos_seatbelt }).prepare(gpa, std.testing.io, .{
        .file_system = .{ .allow = &.{.{ .path = "/", .access = read_execute }} },
    });
    defer prepared.deinit(gpa);
}
