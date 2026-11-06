//! Opt-in adapters for running shell pipeline stages concurrently.

pub const Host = @import("concurrent/Host.zig");
pub const Resolver = @import("concurrent/Resolver.zig");
pub const Writer = @import("concurrent/Writer.zig");
pub const Allocator = @import("concurrent/Allocator.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
