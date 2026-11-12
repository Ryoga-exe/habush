//! Terminal keys and editing actions. Configuration order decides overrides.
const std = @import("std");
const Keybind = @This();

key: Key,
action: Action,

pub const Spec = struct { key: []const u8, action: Action };
pub const Action = enum {
    accept_line,
    interrupt,
    eof_or_delete,
    cursor_start,
    cursor_end,
    cursor_left,
    cursor_right,
    backspace,
    delete,
    kill_to_end,
    kill_to_start,
    undo,
    complete,
    complete_previous,
    clear_screen,
    history_previous,
    history_next,
    history_search_previous,
    history_search_next,
    dismiss_completion,
    ignore,
    unbind,
};

pub const Key = enum(u16) {
    up = 256,
    down,
    left,
    right,
    home,
    end,
    delete,
    backtab,
    _,

    pub fn fromByte(byte: u8) Key {
        return @fromBackingInt(@intCast(switch (byte) {
            10 => 13,
            8 => 127,
            else => byte,
        }));
    }

    pub fn parse(source: []const u8) error{InvalidKeybind}!Key {
        if (std.StaticStringMap(Key).initComptime(.{
            .{ "up", .up },             .{ "down", .down },      .{ "left", .left },              .{ "right", .right },
            .{ "home", .home },         .{ "end", .end },        .{ "delete", .delete },          .{ "backtab", .backtab },
            .{ "enter", fromByte(13) }, .{ "tab", fromByte(9) }, .{ "backspace", fromByte(127) }, .{ "escape", fromByte(27) },
            .{ "space", fromByte(32) },
        }).get(source)) |key| return key;
        if (source.len == 1 and std.ascii.isPrint(source[0])) return fromByte(source[0]);
        if (std.mem.startsWith(u8, source, "ctrl+")) {
            const name = source[5..];
            if (std.mem.eql(u8, name, "space")) return fromByte(0);
            if (name.len == 1) {
                const byte = std.ascii.toUpper(name[0]);
                if (byte >= '@' and byte <= '_') return fromByte(byte & 31);
                if (byte == '?') return fromByte(127);
            }
        }
        return error.InvalidKeybind;
    }

    /// Sequence following ESC; bracketed paste remains a terminal protocol.
    pub fn fromEscape(sequence: []const u8) ?Key {
        return std.StaticStringMap(Key).initComptime(.{
            .{ "[A", .up },    .{ "OA", .up },    .{ "[B", .down },    .{ "OB", .down },
            .{ "[C", .right }, .{ "OC", .right }, .{ "[D", .left },    .{ "OD", .left },
            .{ "[H", .home },  .{ "OH", .home },  .{ "[1~", .home },   .{ "[F", .end },
            .{ "OF", .end },   .{ "[4~", .end },  .{ "[3~", .delete }, .{ "[Z", .backtab },
        }).get(sequence);
    }
};

pub fn compile(gpa: std.mem.Allocator, specs: []const Spec) ![]Keybind {
    const bindings = try gpa.alloc(Keybind, specs.len);
    errdefer gpa.free(bindings);
    for (bindings, specs) |*binding, spec|
        binding.* = .{ .key = try Key.parse(spec.key), .action = spec.action };
    return bindings;
}

pub fn lookup(bindings: []const Keybind, key: Key) ?Action {
    var index = bindings.len;
    while (index != 0) {
        index -= 1;
        const binding = bindings[index];
        if (binding.key == key) return if (binding.action == .unbind) null else binding.action;
    }
    return switch (@backingInt(key)) {
        1 => .cursor_start,
        2 => .cursor_left,
        3 => .interrupt,
        4 => .eof_or_delete,
        5 => .cursor_end,
        6 => .cursor_right,
        9 => .complete,
        11 => .kill_to_end,
        12 => .clear_screen,
        13 => .accept_line,
        14 => .history_next,
        16 => .history_previous,
        21 => .kill_to_start,
        27 => .dismiss_completion,
        31 => .undo,
        127 => .backspace,
        @backingInt(Key.up) => .history_previous,
        @backingInt(Key.down) => .history_next,
        @backingInt(Key.left) => .cursor_left,
        @backingInt(Key.right) => .cursor_right,
        @backingInt(Key.home) => .cursor_start,
        @backingInt(Key.end) => .cursor_end,
        @backingInt(Key.delete) => .delete,
        @backingInt(Key.backtab) => .complete_previous,
        else => null,
    };
}

test "key normalization, override order, and unbinding defaults" {
    const gpa = std.testing.allocator;
    const bindings = try compile(gpa, &.{
        .{ .key = "ctrl+L", .action = .ignore },
        .{ .key = "ctrl+l", .action = .complete },
        .{ .key = "tab", .action = .unbind },
        .{ .key = "up", .action = .history_search_previous },
    });
    defer gpa.free(bindings);
    try std.testing.expectEqual(Action.complete, lookup(bindings, Key.fromByte(12)).?);
    try std.testing.expectEqual(Action.clear_screen, lookup(&.{}, Key.fromByte(12)).?);
    try std.testing.expectEqual(Action.history_previous, lookup(&.{}, Key.fromEscape("OA").?).?);
    try std.testing.expectEqual(Action.history_search_previous, lookup(bindings, .up).?);
    try std.testing.expect(lookup(bindings, Key.fromByte(9)) == null);
    try std.testing.expectEqual(try Key.parse("enter"), try Key.parse("ctrl+j"));
    try std.testing.expectEqual(try Key.parse("backspace"), try Key.parse("ctrl+h"));
    try std.testing.expectEqual(Key.fromByte(0), try Key.parse("ctrl+space"));
    for ([_][]const u8{ "", "ctrl+1", "super+a", "ctrl+shift+a", "あ", "unknown" }) |invalid|
        try std.testing.expectError(error.InvalidKeybind, Key.parse(invalid));
}
