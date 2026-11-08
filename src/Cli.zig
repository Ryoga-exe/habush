//! Command-line startup selection; script arguments stop application parsing.
const std = @import("std");
const Cli = @This();

invocation: Invocation = .stream,
config_path: ?[]const u8 = null,
no_config: bool = false,
no_rc: bool = false,

pub const Invocation = union(enum) {
    stream,
    command: []const u8,
    script: struct { path: []const u8, arguments: []const [:0]const u8 },
};

pub const usage = "habush [--config path | --no-config] [--no-rc] [-c command | script [argument ...]]";

pub fn parse(args: []const [:0]const u8) ?Cli {
    var result: Cli = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--no-config")) {
            if (result.no_config or result.config_path != null) return null;
            result.no_config = true;
        } else if (std.mem.eql(u8, arg, "--no-rc")) {
            if (result.no_rc) return null;
            result.no_rc = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (result.config_path != null or result.no_config or index + 1 >= args.len) return null;
            index += 1;
            if (args[index].len == 0) return null;
            result.config_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            if (result.config_path != null or result.no_config or arg.len == "--config=".len) return null;
            result.config_path = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (index + 2 != args.len) return null;
            result.invocation = .{ .command = args[index + 1] };
            return result;
        } else if (std.mem.eql(u8, arg, "--")) {
            if (index + 1 < args.len)
                result.invocation = .{ .script = .{ .path = args[index + 1], .arguments = args[index + 2 ..] } };
            return result;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return null;
        } else {
            result.invocation = .{ .script = .{ .path = arg, .arguments = args[index + 1 ..] } };
            return result;
        }
    }
    return result;
}

test "startup flags preserve script arguments and explicit command selection" {
    const parsed = parse(&.{ "habush", "--config=alternate.json", "--no-rc", "script.hb", "--no-config" }).?;
    try std.testing.expectEqualStrings("alternate.json", parsed.config_path.?);
    try std.testing.expect(parsed.no_rc);
    try std.testing.expectEqualStrings("--no-config", parsed.invocation.script.arguments[0]);
    const command = parse(&.{ "habush", "--no-config", "-c", "exit 3" }).?;
    try std.testing.expect(command.no_config);
    try std.testing.expectEqualStrings("exit 3", command.invocation.command);
    try std.testing.expectEqualStrings("-script", parse(&.{ "habush", "--", "-script" }).?.invocation.script.path);
    try std.testing.expect(parse(&.{ "habush", "--config" }) == null);
    try std.testing.expect(parse(&.{ "habush", "--config", "x", "--no-config" }) == null);
    try std.testing.expect(parse(&.{ "habush", "--config=" }) == null);
    try std.testing.expect(parse(&.{ "habush", "-c", "exit 0", "extra" }) == null);
}
