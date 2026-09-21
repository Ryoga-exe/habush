//! Scalar values shared across the shell runtime boundary.

/// A shell-visible command exit status in the range 0...255.
pub const ExitStatus = u8;

/// A platform-independent numeric operating-system process identifier.
///
/// Native process identifier types are converted at the platform boundary.
pub const ProcessId = enum(u32) {
    _,
};
