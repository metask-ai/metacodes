//! Isolation root for the cross-UI model picker (issue #16, delivery slice P1).
//!
//! The picker is a client of the control plane, and this root proves it: it
//! reaches the provider kernel and the terminal theme, and nothing else. If the
//! picker ever grows a dependency on `App`, the transport, or a provider
//! client, this step stops compiling — which is the same guarantee
//! `test:provider` gives from the other side of the boundary.

const std = @import("std");

pub const model_picker = @import("repl/model_picker.zig");
pub const model_picker_view = @import("repl/model_picker_view.zig");

test {
    std.testing.refAllDecls(@This());
}
