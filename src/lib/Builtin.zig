//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();

tag: Tag,
special: bool = false,

pub const Tag = enum {
    @":",
    true,
    false,
};

pub const Result = struct {
    status: u8,
};

const definitions = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .tag = .@":", .special = true } },
    .{ "true", Builtin{ .tag = .true } },
    .{ "false", Builtin{ .tag = .false } },
});

pub fn lookup(name: []const u8) ?Builtin {
    return definitions.get(name);
}

pub fn run(builtin: Builtin, argv: []const []const u8) Result {
    _ = argv;
    return .{ .status = switch (builtin.tag) {
        .@":", .true => 0,
        .false => 1,
    } };
}

test "looks up core builtins by command name" {
    try std.testing.expectEqual(Tag.@":", lookup(":").?.tag);
    try std.testing.expect(lookup(":").?.special);
    try std.testing.expectEqual(Tag.true, lookup("true").?.tag);
    try std.testing.expect(!lookup("false").?.special);
    try std.testing.expect(lookup("missing") == null);
    try std.testing.expect(lookup("./true") == null);
}

test "runs status-only core builtins" {
    try std.testing.expectEqual(@as(u8, 0), lookup(":").?.run(&.{":"}).status);
    try std.testing.expectEqual(@as(u8, 0), lookup("true").?.run(&.{"true"}).status);
    try std.testing.expectEqual(@as(u8, 1), lookup("false").?.run(&.{"false"}).status);
}

test {
    std.testing.refAllDecls(@This());
}
