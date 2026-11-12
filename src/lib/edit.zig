//! Editing state independent of a shell language or terminal.
pub const Buffer = @import("edit/Buffer.zig");
pub const Completion = @import("edit/Completion.zig");

test {
    _ = Buffer;
    _ = Completion;
}
