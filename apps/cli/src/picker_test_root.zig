//! Isolation root for the cross-UI model picker (issue #16, delivery slice P1).
//!
//! Proves the picker *builds* standalone. The rule that it may reach only the
//! provider kernel and the terminal theme — and never `App`, the transport, or
//! a provider client — is enforced by `zig build subsystem:boundary`, because a
//! root under `src/` cannot enforce it: every file below `src/` is importable
//! from here.

const std = @import("std");

pub const model_picker = @import("repl/model_picker.zig");
pub const model_picker_view = @import("repl/model_picker_view.zig");

test {
    std.testing.refAllDecls(@This());
}
