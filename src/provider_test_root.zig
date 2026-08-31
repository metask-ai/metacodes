//! Isolation root for the `src/provider/` subsystem.
//!
//! Rooting a test compilation at `src/` lets the provider modules reach
//! `types.zig`, `util/model.zig`, and the portable `platform` layer while
//! proving the subsystem pulls in nothing heavier: if a provider module ever
//! grows a dependency on the TUI, the transport, or a UI protocol, this root
//! stops compiling.

const std = @import("std");

pub const ids = @import("provider/ids.zig");
pub const offer = @import("provider/offer.zig");
pub const credential = @import("provider/credential.zig");
pub const controls = @import("provider/controls.zig");
pub const profile = @import("provider/profile.zig");
pub const registry = @import("provider/registry.zig");
pub const selection = @import("provider/selection.zig");
pub const config_doc = @import("provider/config_doc.zig");
pub const control_plane = @import("provider/control_plane.zig");
pub const runtime_binding = @import("provider/runtime_binding.zig");
pub const startup = @import("provider/startup.zig");
pub const config_store = @import("provider/config_store.zig");
pub const host = @import("provider/host.zig");
pub const custom_provider = @import("provider/custom_provider.zig");
pub const openrouter = @import("provider/openrouter.zig");
pub const oauth = @import("provider/oauth.zig");

test {
    // This std build has no refAllDeclsRecursive; the explicit re-exports above
    // already cover every module in the subsystem.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(registry.metask);
    std.testing.refAllDecls(registry.openai);
    std.testing.refAllDecls(registry.gemini);
    std.testing.refAllDecls(registry.zai_coding_plan);
}
