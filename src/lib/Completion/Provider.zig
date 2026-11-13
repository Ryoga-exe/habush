//! Synchronous completion providers. Requests are borrowed for one call; the
//! collector copies candidate bytes, so a provider may reuse temporary storage.
//! Native callbacks cooperate with the scan budget. A Wasm adapter must also
//! enforce its own execution/memory budget before calling Collector.add.
//! This Zig contract is not a guest ABI: an adapter serializes approved context
//! and candidate data, never Session pointers or internal source/AST layouts.
const std = @import("std");
const Completion = @import("../Completion.zig");
const Provider = @This();

userdata: ?*anyopaque = null,
complete: *const fn (?*anyopaque, Request, *Collector) Error!void,

pub const Error = std.mem.Allocator.Error || error{ Canceled, Unavailable, InvalidCandidate };

pub const Request = struct {
    context: Completion,
    /// Trusted host context for resolving call-scoped resources; not guest input.
    cwd: ?[]const u8 = null,
    /// Literal, unexpanded prefix before the cursor. Borrowed like context.source.
    prefix: []const u8,
};

pub const Candidate = struct {
    /// Unquoted word value, never shell source. Only Completion.makeEdit turns
    /// this into an edit. NUL is rejected; all other bytes remain unchanged.
    value: []const u8,
    /// Optional presentation text, never inserted. Renderers must escape control
    /// bytes and invalid UTF-8 in both label and value before terminal output.
    label: ?[]const u8 = null,
    kind: enum { command, file, directory, other } = .other,
};

pub const Limits = struct {
    candidates: usize = 128,
    bytes: usize = 64 * 1024,
    /// Counts entries examined, including nonmatching names and PATH directories.
    scanned: usize = 4096,
};

pub const Result = struct {
    /// Still borrows the request's exact source. Candidate bytes are owned.
    context: Completion,
    candidates: []const Candidate,
    truncated: bool,
    incomplete: bool,

    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        for (result.candidates) |candidate| {
            gpa.free(candidate.value);
            if (candidate.label) |label| gpa.free(label);
        }
        gpa.free(result.candidates);
        result.* = undefined;
    }

    /// A partial result must never turn an apparently unique match into an edit.
    pub fn unique(result: Result) ?Candidate {
        if (result.truncated or result.incomplete or result.candidates.len != 1) return null;
        return result.candidates[0];
    }

    pub fn makeEdit(result: Result, gpa: std.mem.Allocator, index: usize, source: []const u8, revision: u64) !Completion.Edit {
        if (index >= result.candidates.len) return error.InvalidCandidate;
        return Completion.makeEdit(gpa, result.context, source, revision, result.candidates[index].value);
    }
};

pub const Collector = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    candidates: std.ArrayList(Candidate) = .empty,
    bytes: usize = 0,
    scanned: usize = 0,
    truncated: bool = false,

    /// A successful provider can replace fallback candidates for this context.
    exclusive: bool = false,

    /// Call before examining an entry. False asks the provider to stop work.
    pub fn step(collector: *Collector) bool {
        if (collector.scanned == collector.limits.scanned) {
            collector.truncated = true;
            return false;
        }
        collector.scanned += 1;
        return true;
    }

    /// Deduplicates by insertion value, preserving the first provider's label.
    /// False means the output budget is exhausted; no bytes are retained.
    pub fn add(collector: *Collector, candidate: Candidate) Error!bool {
        if (std.mem.indexOfScalar(u8, candidate.value, 0) != null) return error.InvalidCandidate;
        for (collector.candidates.items) |existing|
            if (std.mem.eql(u8, existing.value, candidate.value)) return true;
        const size = std.math.add(usize, candidate.value.len, if (candidate.label) |label| label.len else 0) catch {
            collector.truncated = true;
            return false;
        };
        if (collector.candidates.items.len == collector.limits.candidates or size > collector.limits.bytes -| collector.bytes) {
            collector.truncated = true;
            return false;
        }
        const value = try collector.gpa.dupe(u8, candidate.value);
        errdefer collector.gpa.free(value);
        const label = if (candidate.label) |text| try collector.gpa.dupe(u8, text) else null;
        errdefer if (label) |text| collector.gpa.free(text);
        try collector.candidates.append(collector.gpa, .{ .value = value, .label = label, .kind = candidate.kind });
        collector.bytes += size;
        return true;
    }

    fn deinit(collector: *Collector) void {
        for (collector.candidates.items) |candidate| {
            collector.gpa.free(candidate.value);
            if (candidate.label) |label| collector.gpa.free(label);
        }
        collector.candidates.deinit(collector.gpa);
    }
};

/// Provider errors leave a visibly incomplete result; cancellation and allocation
/// failures propagate. Nothing here reads Session state or executes shell code.
pub fn collect(gpa: std.mem.Allocator, request: Request, providers: []const Provider, limits: Limits) (std.mem.Allocator.Error || error{Canceled})!Result {
    var collector: Collector = .{ .gpa = gpa, .limits = limits };
    errdefer collector.deinit();
    var incomplete = false;
    for (providers) |provider| {
        provider.complete(provider.userdata, request, &collector) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.Unavailable, error.InvalidCandidate => {
                incomplete = true;
                collector.exclusive = false;
            },
        };
        if (collector.truncated or collector.exclusive) break;
    }
    return .{
        .context = request.context,
        .candidates = try collector.candidates.toOwnedSlice(gpa),
        .truncated = collector.truncated,
        .incomplete = incomplete,
    };
}

test "providers own and deduplicate values, bound results, and reject stale insertion" {
    const TestProvider = struct {
        fn complete(_: ?*anyopaque, _: Request, collector: *Collector) Error!void {
            var value = [_]u8{ 'a', '\'', '$', '(', 'x', ')' };
            _ = try collector.add(.{ .value = &value, .label = "label\x1b" });
            @memset(&value, '!');
            _ = try collector.add(.{ .value = "a'$(x)" });
        }
    };
    const context = try Completion.inspect("a", 1, 4);
    const providers = [_]Provider{.{ .complete = TestProvider.complete }};
    var result = try collect(std.testing.allocator, .{ .context = context, .prefix = "a" }, &providers, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a'$(x)", result.unique().?.value);
    try std.testing.expectEqualStrings("label\x1b", result.unique().?.label.?);
    var edit = try result.makeEdit(std.testing.allocator, 0, "a", 4);
    defer edit.deinit(std.testing.allocator);
    // The real parser and expander must recover exactly one literal argument;
    // an accidental command substitution would require an unavailable callback.
    const source = try std.testing.allocator.dupeSentinel(u8, edit.text, 0);
    defer std.testing.allocator.free(source);
    var tree = try @import("../Ast.zig").parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var hir = try @import("../AstGen.zig").generate(std.testing.allocator, tree);
    defer hir.deinit(std.testing.allocator);
    const command = hir.listItem(hir.root().?, 0).command;
    const args = try @import("../Expander.zig").init(std.testing.allocator).expandArgument(hir, hir.simpleCommandParts(command)[0]);
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings(result.candidates[0].value, args[0]);
    try std.testing.expectError(error.StaleContext, result.makeEdit(std.testing.allocator, 0, "a", 5));
    try std.testing.expectError(error.StaleContext, result.makeEdit(std.testing.allocator, 0, "b", 4));
    var bounded = try collect(std.testing.allocator, .{ .context = context, .prefix = "a" }, &providers, .{ .bytes = 1 });
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expect(bounded.truncated and bounded.unique() == null);
}

test "scan exhaustion and failed providers cannot produce a unique edit" {
    const TestProvider = struct {
        fn complete(_: ?*anyopaque, _: Request, collector: *Collector) Error!void {
            if (!collector.step()) return;
            _ = try collector.add(.{ .value = "one" });
            if (!collector.step()) return;
            collector.exclusive = true;
            return error.Unavailable;
        }

        fn fallback(_: ?*anyopaque, _: Request, collector: *Collector) Error!void {
            _ = try collector.add(.{ .value = "two" });
        }
    };
    const context = try Completion.inspect("", 0, 0);
    const providers = [_]Provider{ .{ .complete = TestProvider.complete }, .{ .complete = TestProvider.fallback } };
    for ([_]Limits{ .{ .scanned = 1 }, .{} }) |limits| {
        var result = try collect(std.testing.allocator, .{ .context = context, .prefix = "" }, &providers, limits);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.unique() == null);
        try std.testing.expect(result.truncated or result.incomplete);
        if (result.incomplete) try std.testing.expectEqual(@as(usize, 2), result.candidates.len);
    }
}
