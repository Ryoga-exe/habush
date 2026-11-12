//! Editing state independent of a shell language or terminal.
pub const Buffer = @import("edit/Buffer.zig");
pub const Completion = @import("edit/Completion.zig");
pub const History = @import("edit/History.zig");

test {
    _ = Buffer;
    _ = Completion;
    _ = History;
}
