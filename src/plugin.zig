//! Optional Wasm execution; independent of shell semantics and editing.
pub const Host = @import("plugin/Host.zig");
pub const command = @import("plugin/command.zig");
pub const completion = @import("plugin/completion.zig");

test {
    _ = Host;
    _ = command;
    _ = completion;
}
