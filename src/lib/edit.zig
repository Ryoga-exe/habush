//! Editing state independent of a shell language or terminal.
pub const Buffer = @import("edit/Buffer.zig");
pub const Completion = @import("edit/Completion.zig");
pub const History = @import("edit/History.zig");
pub const Keybind = @import("edit/Keybind.zig");
pub const Editor = @import("edit/Editor.zig");
pub const Prompt = @import("edit/Prompt.zig");
pub const Diagnostic = @import("edit/Diagnostic.zig");
pub const unicode = @import("edit/unicode.zig");

test {
    _ = Buffer;
    _ = Completion;
    _ = History;
    _ = Keybind;
    _ = Editor;
    _ = Prompt;
    _ = Diagnostic;
    _ = unicode;
}
