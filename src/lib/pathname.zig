//! Language-side pathname expansion over host directory snapshots.

const std = @import("std");
const Host = @import("Host.zig");
const CommandPlan = @import("CommandPlan.zig");
const Pattern = @import("Pattern.zig");

/// Null preserves the original field, both without active metacharacters and
/// when no path matches. Results retain relative/absolute spelling and use
/// deterministic byte ordering, without changing the process locale or cwd.
pub fn expand(gpa: std.mem.Allocator, host: Host, cwd: CommandPlan.WorkingDirectory, pattern: Pattern) Host.Error!?[]const []const u8 {
    if (!pattern.hasMeta()) return null;
    const Candidate = struct { path: []const u8, start: usize, matching: bool };
    var pending: std.ArrayList(Candidate) = .empty;
    defer {
        for (pending.items) |candidate| gpa.free(candidate.path);
        pending.deinit(gpa);
    }
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |path| gpa.free(path);
        results.deinit(gpa);
    }
    const initial = try gpa.dupe(u8, "");
    pending.append(gpa, .{ .path = initial, .start = 0, .matching = false }) catch |err| {
        gpa.free(initial);
        return err;
    };
    while (pending.pop()) |candidate| {
        defer gpa.free(candidate.path);
        var end = candidate.start;
        while (end < pattern.bytes.len and !std.fs.path.isSep(pattern.bytes[end])) end += 1;
        var next = end;
        while (next < pattern.bytes.len and std.fs.path.isSep(pattern.bytes[next])) next += 1;
        const component: Pattern = .{
            .bytes = pattern.bytes[candidate.start..end],
            .quoted = if (pattern.quoted.len == 0) &.{} else pattern.quoted[candidate.start..end],
        };
        if (!candidate.matching and !component.hasMeta()) {
            const path = try std.mem.concat(gpa, u8, &.{ candidate.path, pattern.bytes[candidate.start..next] });
            errdefer gpa.free(path);
            if (next == pattern.bytes.len) {
                try results.append(gpa, path);
            } else try pending.append(gpa, .{ .path = path, .start = next, .matching = false });
            continue;
        }
        const directory = (try host.readDirectory(gpa, cwd, if (candidate.path.len == 0) "." else candidate.path)) orelse continue;
        defer directory.deinit(gpa);
        const dot_component = std.mem.eql(u8, component.bytes, ".") or std.mem.eql(u8, component.bytes, "..");
        const names: []const []const u8 = if (dot_component) &.{component.bytes} else directory.names;
        for (names) |name| {
            if (!dot_component and (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))) continue;
            if (name.len != 0 and name[0] == '.' and (component.bytes.len == 0 or component.bytes[0] != '.')) continue;
            if (!component.matches(name)) continue;
            const path = try std.mem.concat(gpa, u8, &.{ candidate.path, name, pattern.bytes[end..next] });
            var transferred = false;
            defer if (!transferred) gpa.free(path);
            if (next == pattern.bytes.len) {
                if (next != end) {
                    const child = (try host.readDirectory(gpa, cwd, path)) orelse continue;
                    child.deinit(gpa);
                }
                try results.append(gpa, path);
            } else try pending.append(gpa, .{ .path = path, .start = next, .matching = true });
            transferred = true;
        }
    }
    if (results.items.len == 0) {
        results.deinit(gpa);
        return null;
    }
    std.mem.sort([]const u8, results.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return try results.toOwnedSlice(gpa);
}
