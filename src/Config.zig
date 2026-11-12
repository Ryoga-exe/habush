//! Application settings and user-directory discovery. Configuration I/O stays
//! in the CLI; libhabush Sessions receive already chosen runtime services.
const std = @import("std");
const builtin = @import("builtin");
const Config = @This();

version: u32 = 1,
line_edit: Mode = .auto,
shell_integration: Mode = .auto,
load_rc: bool = true,
plugins: []Plugin = &.{},
keybinds: []const @import("habush-edit").Keybind.Spec = &.{},
prompt: ?@import("habush-edit").Prompt = null,
prompt_context: struct { git: bool = false } = .{},
diagnostics: bool = true,
history: History = .{},
/// Shared by completion providers; guest execution budgets
/// remain the plugin host's responsibility.
completion_limits: @import("habush").Completion.Provider.Limits = .{},

pub const Mode = enum { auto, on, off };
pub const History = struct {
    memory: struct { max_entries: usize = 1000, max_bytes: usize = 1024 * 1024 } = .{},
    storage: struct { enabled: bool = true, path: ?[]const u8 = null, max_bytes: usize = 8 * 1024 * 1024 } = .{},
};
pub const Plugin = struct {
    path: []const u8,
    declares: @import("habush").capability.Set = .{},
    grants: @import("habush").capability.Set = .{},
    read_directory: ?[]const u8 = null,
    /// Plugin-defined UTF-8/byte settings; never the app's full configuration.
    options: []const [2][]const u8 = &.{},
    commands: []const Command = &.{},
    completions: []const Completion = &.{},
    prompt: ?struct { entry: []const u8 = "prompt" } = null,
    diagnostics: ?struct { entry: []const u8 = "diagnose" } = null,
    fuel: u64 = 10_000_000,
    memory_bytes: u32 = 16 * 1024 * 1024,
    timeout_ms: u32 = 1000,

    pub const Command = struct {
        name: []const u8,
        entry: []const u8 = "command",
    };

    pub const Completion = struct {
        command: []const u8,
        entry: []const u8 = "complete",
    };
};
pub const max_file_bytes = 64 * 1024;
pub const max_rc_bytes = 1024 * 1024;

pub fn parse(options: std.zon.parse.Options) !Config {
    const config = try std.zon.parse.fromSlice(Config, options);
    if (config.version != 1) return error.UnsupportedConfigVersion;
    if (config.history.memory.max_bytes > @import("HistoryStore.zig").max_file_bytes or
        config.history.storage.max_bytes < 13 or config.history.storage.max_bytes > @import("HistoryStore.zig").max_file_bytes)
        return error.InvalidHistoryConfiguration;
    if (config.history.storage.path) |path| {
        if (!validString(path)) return error.InvalidHistoryConfiguration;
        const name = std.fs.path.basename(path);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            path[path.len - 1] == '/' or path[path.len - 1] == std.fs.path.sep) return error.InvalidHistoryConfiguration;
    }
    if (config.prompt) |prompt| if (!prompt.valid()) return error.InvalidPrompt;
    for (config.keybinds) |binding| _ = try @import("habush-edit").Keybind.Key.parse(binding.key);
    for (config.plugins, 0..) |plugin, plugin_index| {
        const permissions = @import("habush").capability.Set;
        if (!permissions.all.contains(plugin.declares) or !plugin.declares.contains(plugin.grants) or
            plugin.grants.fs_read != (plugin.read_directory != null)) return error.InvalidPluginPermissions;
        if (plugin.read_directory) |root| if (!validString(root)) return error.InvalidPluginPermissions;
        var option_bytes: usize = 0;
        if (plugin.options.len > 32) return error.InvalidPluginOptions;
        for (plugin.options, 0..) |option, index| {
            if (!validString(option[0]) or std.mem.indexOfScalar(u8, option[1], 0) != null) return error.InvalidPluginOptions;
            option_bytes += option[0].len + option[1].len;
            if (option_bytes > 4096) return error.InvalidPluginOptions;
            for (plugin.options[0..index]) |previous|
                if (std.mem.eql(u8, previous[0], option[0])) return error.InvalidPluginOptions;
        }
        if (!validString(plugin.path) or (plugin.commands.len == 0 and plugin.completions.len == 0 and plugin.prompt == null and plugin.diagnostics == null))
            return error.InvalidPluginConfiguration;
        if (plugin.prompt) |prompt| if (!validString(prompt.entry)) return error.InvalidPluginConfiguration;
        if (plugin.diagnostics) |diagnostic| if (!validString(diagnostic.entry)) return error.InvalidPluginConfiguration;
        for (plugin.commands, 0..) |command, command_index| {
            if (!validString(command.name) or std.fs.path.dirname(command.name) != null or
                std.mem.indexOfAny(u8, command.name, "/\\") != null or
                !validString(command.entry)) return error.InvalidPluginConfiguration;
            if (@import("habush").Builtin.lookup(command.name) != null) return error.ReservedPluginCommand;
            for (config.plugins[0 .. plugin_index + 1], 0..) |previous, previous_index| {
                const end = if (previous_index == plugin_index) command_index else previous.commands.len;
                for (previous.commands[0..end]) |registered|
                    if (std.mem.eql(u8, registered.name, command.name)) return error.DuplicatePluginCommand;
            }
        }
        for (plugin.completions) |completion|
            if (!validString(completion.command) or !validString(completion.entry)) return error.InvalidPluginConfiguration;
    }
    return config;
}

fn validString(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn read(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, path: []const u8, diagnostics: *std.Io.Writer) !Config {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_file_bytes), .of(u8), 0);
    defer gpa.free(source);
    var detail: std.zon.parse.Diagnostics = undefined;
    var config = parse(.{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &detail,
    }) catch |err| {
        if (err == error.ParseZon)
            try diagnostics.print("habush: configuration: {f}\n", .{detail.fmt(path)});
        return err;
    };
    for (config.plugins) |*plugin| {
        if (!std.fs.path.isAbsolute(plugin.path))
            plugin.path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(path) orelse ".", plugin.path });
        if (plugin.read_directory) |root| if (!std.fs.path.isAbsolute(root)) {
            const base = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", arena);
            plugin.read_directory = try std.fs.path.join(arena, &.{ base, root });
        };
    }
    if (config.history.storage.path) |history_path| {
        if (!std.fs.path.isAbsolute(history_path)) {
            const base = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", arena);
            config.history.storage.path = try std.fs.path.join(arena, &.{ base, history_path });
        }
    }
    return config;
}

/// Loads the explicit path or config.zon; a missing default uses default values.
/// Returns null after reporting an invalid or unreadable configuration.
/// Parsed strings and plugin declarations live in `arena` until the app exits.
pub fn load(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, paths: Paths, explicit: ?[]const u8, diagnostics: *std.Io.Writer) !?Config {
    const default_path = if (explicit == null) try paths.configFile(gpa) else null;
    defer if (default_path) |path| gpa.free(path);
    const path = explicit orelse default_path orelse return .{};
    return read(gpa, arena, io, path, diagnostics) catch |err| {
        if (err == error.FileNotFound and explicit == null) return .{};
        if (err == error.OutOfMemory or err == error.WriteFailed) return err;
        if (err != error.ParseZon) try reportError(diagnostics, path, err);
        return null;
    };
}

pub fn reportError(writer: *std.Io.Writer, path: ?[]const u8, err: anyerror) std.Io.Writer.Error!void {
    const message = switch (err) {
        error.InvalidLineEditSetting => "HABUSH_LINE_EDIT must be auto, on, or off",
        error.InvalidShellIntegrationSetting => "HABUSH_SHELL_INTEGRATION must be auto, on, or off",
        error.UnsupportedConfigVersion => "unsupported config version",
        error.InvalidKeybind => "unsupported keybinding trigger",
        error.InvalidPrompt => "prompt exceeds display limits or contains NUL",
        error.InvalidHistoryConfiguration => "invalid history path or size (memory at most 64 MiB; storage 13 bytes to 64 MiB)",
        error.InvalidPluginConfiguration => "plugin paths, command names, and entries must be nonempty and valid",
        error.InvalidPluginOptions => "plugin options require unique nonempty keys, no NUL, at most 32 pairs and 4096 bytes",
        error.InvalidPluginPermissions => "plugin grants must fit their declaration; fs_read requires a read_directory grant",
        error.ReservedPluginCommand => "plugin command name is reserved for a builtin",
        error.DuplicatePluginCommand => "duplicate plugin command name",
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        error.StreamTooLong => "config file is too large",
        else => @errorName(err),
    };
    try writer.writeAll("habush: configuration: ");
    if (path) |value| try writer.print("{s}: ", .{value});
    return writer.print("{s}\n", .{message});
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
    if (!interactive or builtin.target.os.tag == .windows or config.line_edit == .off) return false;
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
        const home = absoluteEnvironment(environ.get("HOME")) orelse if (builtin.target.os.tag == .windows)
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
        return try std.fs.path.join(gpa, &.{ directory_path, "config.zon" });
    }

    pub fn rcFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const directory_path = paths.config orelse return null;
        return try std.fs.path.join(gpa, &.{ directory_path, "rc.hb" });
    }

    pub fn historyFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const directory_path = paths.state orelse return null;
        return try std.fs.path.join(gpa, &.{ directory_path, "history" });
    }

    pub fn legacyRcFile(paths: Paths, gpa: std.mem.Allocator) !?[]u8 {
        const home = paths.home orelse return null;
        return try std.fs.path.join(gpa, &.{ home, ".habushrc" });
    }
};

fn absoluteEnvironment(value: ?[]const u8) ?[]const u8 {
    const path = nonempty(value) orelse return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (!isAbsolute(builtin.target.os.tag == .windows, path)) return null;
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

test "environment overrides reject invalid settings" {
    const config: Config = .{ .line_edit = .off, .load_rc = false };
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

test "ZON configuration validates fields and honors explicit paths without JSON fallback" {
    const gpa = std.testing.allocator;
    var storage: std.heap.ArenaAllocator = .init(gpa);
    defer storage.deinit();
    const arena = storage.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_path = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var paths: Paths = .{ .config = try gpa.dupe(u8, directory_path) };
    defer paths.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try std.testing.expectEqualDeep(Config{}, (try load(gpa, arena, io, paths, null, &output.writer)).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"load_rc\":false}" });
    try std.testing.expectEqualDeep(Config{}, (try load(gpa, arena, io, paths, null, &output.writer)).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = ".{ .line_edit = .off, .history = .{ .memory = .{ .max_entries = 7 }, .storage = .{ .path = \"local-history\" } }, .completion_limits = .{ .candidates = 7 }, .keybinds = .{.{ .key = \"ctrl+space\", .action = .complete }} }" });
    const zon = (try load(gpa, arena, io, paths, null, &output.writer)).?;
    try std.testing.expectEqual(Mode.off, zon.line_edit);
    try std.testing.expect(zon.load_rc);
    try std.testing.expectEqual(@as(usize, 7), zon.completion_limits.candidates);
    try std.testing.expectEqual((Config{}).completion_limits.bytes, zon.completion_limits.bytes);
    try std.testing.expectEqualStrings("ctrl+space", zon.keybinds[0].key);
    try std.testing.expectEqual(@as(usize, 7), zon.history.memory.max_entries);
    const history_path = try std.fs.path.join(arena, &.{ directory_path, "local-history" });
    try std.testing.expectEqualStrings(history_path, zon.history.storage.path.?);
    try std.testing.expectEqualStrings("", output.written());

    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data =
        \\.{ .plugins = .{.{ .path = "plugins/demo.wasm", .commands = .{.{ .name = "demo" }}, .completions = .{.{ .command = "git" }} }} }
    });
    const configured = (try load(gpa, arena, io, paths, null, &output.writer)).?;
    const module_path = try std.fs.path.join(arena, &.{ directory_path, "plugins/demo.wasm" });
    try std.testing.expectEqualStrings(module_path, configured.plugins[0].path);
    try std.testing.expectEqualStrings("demo", configured.plugins[0].commands[0].name);
    try std.testing.expectEqualStrings("git", configured.plugins[0].completions[0].command);
    try std.testing.expectEqualStrings("complete", configured.plugins[0].completions[0].entry);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data =
        \\.{ .plugins = .{.{ .path = "only-completion.wasm", .completions = .{.{ .command = "true" }, .{ .command = "/bin/echo" }} }} }
    });
    const completion_only = (try load(gpa, arena, io, paths, null, &output.writer)).?;
    try std.testing.expectEqual(@as(usize, 0), completion_only.plugins[0].commands.len);
    try std.testing.expectEqual(@as(usize, 2), completion_only.plugins[0].completions.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data =
        \\.{ .plugins = .{ .{ .path = "theme.wasm", .prompt = .{}, .options = .{ .{ "symbol", ">" } } }, .{ .path = "diagnostic.wasm", .diagnostics = .{} } } }
    });
    const presentation = (try load(gpa, arena, io, paths, null, &output.writer)).?;
    try std.testing.expectEqualStrings("prompt", presentation.plugins[0].prompt.?.entry);
    try std.testing.expectEqualStrings(">", presentation.plugins[0].options[0][1]);
    try std.testing.expectEqualStrings("diagnose", presentation.plugins[1].diagnostics.?.entry);

    for ([_][]const u8{
        ".{\n    .line_edti = .off,\n}",
        ".{ .load_rc = true, .load_rc = false }",
        ".{ .line_edit = .maybe }",
        ".{ .version = 2 }",
        ".{ .history = .{ .storage = .{ .path = \"bad\\x00\" } } }",
        ".{ .history = .{ .storage = .{ .max_bytes = 0 } } }",
        ".{ .history = .{ .storage = .{ .max_bytes = 67108865 } } }",
        ".{ .history = .{ .storage = .{ .path = \"history/\" } } }",
        ".{ .history = .{ .storage = .{ .path = \".\" } } }",
        ".{ .plugins = .{.{ .path = \"theme.wasm\", .prompt = .{}, .options = .{ .{ \"symbol\", \">\" }, .{ \"symbol\", \"$\" } } }} }",
        ".{ .plugins = .{.{ .path = \"theme.wasm\", .prompt = .{}, .options = .{ .{ \"\", \">\" } } }} }",
        ".{ .plugins = .{.{ .path = \"theme.wasm\", .prompt = .{}, .grants = .{ .context = true } }} }",
        ".{ .plugins = .{.{ .path = \"theme.wasm\", .prompt = .{}, .declares = .{ .fs_read = true }, .grants = .{ .fs_read = true } }} }",
        ".{ .plugins = .{.{ .path = \"theme.wasm\", .prompt = .{ .entry = \"\" } }} }",
        ".{ .plugins = .{.{ .path = \"diagnostic.wasm\", .diagnostics = .{ .entry = \"\" } }} }",
        ".{ .prompt = .{ .spans = .{.{ .text = \"bad\\x00\" }} } }",
        ".{ .keybinds = .{.{ .key = \"super+a\", .action = .complete }} }",
        ".{ .keybinds = .{.{ .key = \"ctrl+l\", .action = .missing }} }",
        ".{ .plugins = .{.{ .path = \"x\", .commands = .{.{ .name = \"true\" }} }} }",
        ".{ .plugins = .{.{ .path = \"x\", .commands = .{.{ .name = \"demo\" }, .{ .name = \"demo\" }} }} }",
        ".{ .plugins = .{.{ .path = \"\", .commands = .{.{ .name = \"demo\" }} }} }",
        ".{ .plugins = .{.{ .path = \"x\" }} }",
        ".{ .plugins = .{.{ .path = \"x\", .completions = .{.{ .command = \"\" }} }} }",
    }, 0..) |invalid, index| {
        output.clearRetainingCapacity();
        try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = invalid });
        try std.testing.expect(try load(gpa, arena, io, paths, null, &output.writer) == null);
        try std.testing.expect(output.written().len > 0);
        if (index == 0)
            try std.testing.expect(std.mem.indexOf(u8, output.written(), "config.zon:2:") != null);
    }

    output.clearRetainingCapacity();
    try tmp.dir.writeFile(io, .{ .sub_path = "custom.conf", .data = ".{ .load_rc = false }" });
    const explicit_path = try std.fs.path.join(gpa, &.{ directory_path, "custom.conf" });
    defer gpa.free(explicit_path);
    try std.testing.expect(!(try load(gpa, arena, io, paths, explicit_path, &output.writer)).?.load_rc);
    try std.testing.expectEqualStrings("", output.written());

    const json_path = try std.fs.path.join(gpa, &.{ directory_path, "config.json" });
    defer gpa.free(json_path);
    try std.testing.expect(try load(gpa, arena, io, paths, json_path, &output.writer) == null);
    try std.testing.expect(output.written().len > 0);

    output.clearRetainingCapacity();
    const missing = try std.fs.path.join(gpa, &.{ directory_path, "missing.zon" });
    defer gpa.free(missing);
    try std.testing.expect(try load(gpa, arena, io, paths, missing, &output.writer) == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "no such file or directory") != null);
}

test "XDG bases require absolute paths and use HOME fallbacks without creating directories" {
    const home = if (builtin.target.os.tag == .windows) "C:\\Users\\example" else "/home/example";
    const data = if (builtin.target.os.tag == .windows) "D:\\data" else "/data";
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
            try environ.put("HOME", if (builtin.target.os.tag == .windows) "C:\\Users\\example" else "/home/example");
            var paths = try Paths.init(gpa, &environ);
            defer paths.deinit(gpa);
            const file = (try paths.configFile(gpa)).?;
            defer gpa.free(file);
            const rc = (try paths.rcFile(gpa)).?;
            defer gpa.free(rc);
        }
    }.exercise, .{});
}
