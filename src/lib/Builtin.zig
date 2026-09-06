//! Compile-time registry for trusted core shell builtins.

const std = @import("std");
const Builtin = @This();

tag: Tag,
kind: Kind,

pub const Tag = enum {
    @":",
    true,
    false,
};

pub const Kind = enum {
    special,
    regular,
};

pub const Result = struct {
    status: u8,
};

const definitions = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .tag = .@":", .kind = .special } },
    .{ "true", Builtin{ .tag = .true, .kind = .regular } },
    .{ "false", Builtin{ .tag = .false, .kind = .regular } },
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
    try std.testing.expectEqual(Kind.special, lookup(":").?.kind);
    try std.testing.expectEqual(Tag.true, lookup("true").?.tag);
    try std.testing.expectEqual(Kind.regular, lookup("false").?.kind);
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
