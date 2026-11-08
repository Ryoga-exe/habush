//! Application settings and user-directory discovery. Configuration I/O stays
//! in the CLI; libhabush Sessions receive already chosen runtime services.
const std = @import("std");
const builtin = @import("builtin");
const Config = @This();

version: u32 = 1,
line_edit: Mode = .auto,
shell_integration: Mode = .auto,
load_rc: bool = true,
/// Shared by native providers and future adapters; guest execution budgets
/// remain the plugin host's responsibility.
completion_limits: @import("habush").Completion.Provider.Limits = .{},

pub const Mode = enum { auto, on, off };
pub const max_file_bytes = 64 * 1024;
pub const max_rc_bytes = 1024 * 1024;

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(Config, gpa, source, .{});
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedConfigVersion;
    return parsed.value;
}

pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(source);
    return parse(gpa, source);
}

/// Environment overrides only affect application presentation. They are not
/// re-read from the mutable shell variable store during a running session.
pub fn withEnvironment(config: Config, environ: *const std.process.Environ.Map) !Config {
    var result = config;
    if (nonempty(environ.get("HABUSH_LINE_EDIT"))) |value|
        result.line_edit = std.meta.stringToEnum(Mode, value) orelse return error.InvalidLineEditSetting;
    if (nonempty(environ.get("HABUSH_SHELL_INTEGRATION"))) |value|
        result.shell_integration = std.meta.stringToEnum(Mode, value) orelse return error.InvalidShellIntegrationSetting;
    return result;
}

pub fn lineEditEnabled(config: Config, interactive: bool, term: ?[]const u8) bool {
    if (!interactive or builtin.os.tag == .windows or config.line_edit == .off) return false;
    if (config.line_edit == .on) return true;
    const value = nonempty(term) orelse return false;
    return !std.mem.eql(u8, value, "dumb");
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

/// Only user-specific XDG bases are selected; system-wide search directories
/// and runtime sockets are separate future features. Discovery creates no files.
pub const Paths = struct {
    home: ?[]u8 = null,
    config: ?[]u8 = null,
    cache: ?[]u8 = null,
    data: ?[]u8 = null,
    state: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !Paths {
        var paths: Paths = .{};
        errdefer paths.deinit(gpa);
        const home = absoluteEnvironment(environ.get("HOME")) orelse if (builtin.os.tag == .windows)
            absoluteEnvironment(environ.get("USERPROFILE"))
        else
            null;
        paths.home = if (home) |value| try gpa.dupe(u8, value) else null;
        paths.config = try directory(gpa, environ.get("XDG_CONFIG_HOME"), home, .config);
        paths.cache = try directory(gpa, environ.get("XDG_CACHE_HOME"), home, .cache);
        paths.data = try directory(gpa, environ.get("XDG_DATA_HOME"), home, .data);
        paths.state = try directory(gpa, environ.get("XDG_STATE_HOME"), home, .state);
        return paths;
    }

    pub fn deinit(paths: *Paths, gpa: std.mem.Allocator) void {
        inline for (.{ "home", "config", "cache", "data", "state" }) |field|
            if (@field(paths, field)) |path| gpa.free(path);
        paths.* = undefined;
    }

    pub fn configFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const directory_path = paths.config orelse return null;
        return try std.fs.path.join(gpa, &.{ directory_path, "config.json" });
    }

    pub fn rcFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const directory_path = paths.config orelse return null;
        return try std.fs.path.join(gpa, &.{ directory_path, "rc.hb" });
    }

    pub fn legacyRcFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const home = paths.home orelse return null;
        return try std.fs.path.join(gpa, &.{ home, ".habushrc" });
    }
};

fn absoluteEnvironment(value: ?[]const u8) ?[]const u8 {
    const path = nonempty(value) orelse return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (!isAbsolute(builtin.os.tag == .windows, path)) return null;
    return path;
}

fn isAbsolute(comptime windows: bool, path: []const u8) bool {
    if (!windows) return std.fs.path.isAbsolutePosix(path);
    // std's isAbsoluteWindows also accepts paths rooted on the current drive,
    // such as \config. They still depend on that drive, so are not XDG bases.
    const parsed = std.fs.path.parsePathWindows(u8, path);
    return parsed.kind != .rooted and std.fs.path.isAbsoluteWindows(path);
}

const Directory = enum { config, cache, data, state };

fn directory(gpa: std.mem.Allocator, candidate: ?[]const u8, home: ?[]const u8, kind: Directory) !?[]u8 {
    if (absoluteEnvironment(candidate)) |base|
        return try std.fs.path.join(gpa, &.{ base, "habush" });
    const base = home orelse return null;
    return switch (kind) {
        .config => try std.fs.path.join(gpa, &.{ base, ".config", "habush" }),
        .cache => try std.fs.path.join(gpa, &.{ base, ".cache", "habush" }),
        .data => try std.fs.path.join(gpa, &.{ base, ".local", "share", "habush" }),
        .state => try std.fs.path.join(gpa, &.{ base, ".local", "state", "habush" }),
    };
}

test "typed JSON and environment overrides reject invalid or ambiguous settings" {
    const config = try parse(std.testing.allocator, "{\"line_edit\":\"off\",\"load_rc\":false}");
    try std.testing.expectEqual(Mode.off, config.line_edit);
    try std.testing.expect(!config.load_rc);
    const bounded = try parse(std.testing.allocator, "{\"completion_limits\":{\"candidates\":8,\"bytes\":4096,\"scanned\":256}}");
    try std.testing.expectEqual(@as(usize, 8), bounded.completion_limits.candidates);
    try std.testing.expectError(error.UnknownField, parse(std.testing.allocator, "{\"line_edti\":\"off\"}"));
    try std.testing.expectError(error.DuplicateField, parse(std.testing.allocator, "{\"load_rc\":true,\"load_rc\":false}"));
    try std.testing.expectError(error.UnsupportedConfigVersion, parse(std.testing.allocator, "{\"version\":2}"));
    try std.testing.expectError(error.InvalidEnumTag, parse(std.testing.allocator, "{\"line_edit\":\"maybe\"}"));
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HABUSH_LINE_EDIT", "on");
    try environ.put("HABUSH_SHELL_INTEGRATION", "off");
    const overridden = try config.withEnvironment(&environ);
    try std.testing.expectEqual(Mode.on, overridden.line_edit);
    try std.testing.expectEqual(Mode.off, overridden.shell_integration);
    try environ.put("HABUSH_LINE_EDIT", "");
    try std.testing.expectEqual(Mode.off, (try config.withEnvironment(&environ)).line_edit);
    try environ.put("HABUSH_LINE_EDIT", "maybe");
    try std.testing.expectError(error.InvalidLineEditSetting, config.withEnvironment(&environ));
    try std.testing.expect(!config.lineEditEnabled(false, "xterm"));
}

test "XDG bases require absolute paths and use HOME fallbacks without creating directories" {
    const home = if (builtin.os.tag == .windows) "C:\\Users\\example" else "/home/example";
    const data = if (builtin.os.tag == .windows) "D:\\data" else "/data";
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("XDG_CONFIG_HOME", "relative");
    try environ.put("XDG_CACHE_HOME", "");
    try environ.put("XDG_DATA_HOME", data);
    var paths = try Paths.init(std.testing.allocator, &environ);
    defer paths.deinit(std.testing.allocator);
    const expected_config = try std.fs.path.join(std.testing.allocator, &.{ home, ".config", "habush" });
    defer std.testing.allocator.free(expected_config);
    const expected_data = try std.fs.path.join(std.testing.allocator, &.{ data, "habush" });
    defer std.testing.allocator.free(expected_data);
    try std.testing.expectEqualStrings(expected_config, paths.config.?);
    try std.testing.expectEqualStrings(expected_data, paths.data.?);
    try std.testing.expect(!isAbsolute(true, "\\config"));
    try std.testing.expect(!isAbsolute(true, "C:config"));
    try std.testing.expect(isAbsolute(true, "C:\\config"));
    try std.testing.expect(isAbsolute(true, "\\\\server\\share\\config"));
    const overrides = .{
        .{ .key = "XDG_CONFIG_HOME", .field = "config" },
        .{ .key = "XDG_CACHE_HOME", .field = "cache" },
        .{ .key = "XDG_DATA_HOME", .field = "data" },
        .{ .key = "XDG_STATE_HOME", .field = "state" },
    };
    var explicit: std.process.Environ.Map = .init(std.testing.allocator);
    defer explicit.deinit();
    inline for (overrides) |entry| {
        const value = try std.fs.path.join(std.testing.allocator, &.{ home, "xdg", entry.field });
        defer std.testing.allocator.free(value);
        try explicit.put(entry.key, value);
    }
    var explicit_paths = try Paths.init(std.testing.allocator, &explicit);
    defer explicit_paths.deinit(std.testing.allocator);
    inline for (overrides) |entry| {
        const expected = try std.fs.path.join(std.testing.allocator, &.{ home, "xdg", entry.field, "habush" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, @field(explicit_paths, entry.field).?);
    }
    try environ.put("HOME", "relative");
    var without_home = try Paths.init(std.testing.allocator, &environ);
    defer without_home.deinit(std.testing.allocator);
    try std.testing.expect(without_home.config == null);
    try std.testing.expect(without_home.cache == null);
    try std.testing.expect(without_home.state == null);
    try std.testing.expectEqualStrings(expected_data, without_home.data.?);
}

test "XDG discovery preserves ownership on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn exercise(gpa: std.mem.Allocator) !void {
            var environ: std.process.Environ.Map = .init(std.testing.allocator);
            defer environ.deinit();
            try environ.put("HOME", if (builtin.os.tag == .windows) "C:\\Users\\example" else "/home/example");
            var paths = try Paths.init(gpa, &environ);
            defer paths.deinit(gpa);
            const file = (try paths.configFile(gpa)).?;
            defer gpa.free(file);
            const rc = (try paths.rcFile(gpa)).?;
            defer gpa.free(rc);
        }
    }.exercise, .{});
}
