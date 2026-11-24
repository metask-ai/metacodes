//! Module root for harness binaries that run the installer without the rest
//! of the app graph (`tests/_harness/update_unit_probe.zig`). Rooted in `src/`
//! so `app/install.zig` can reach `util/` as it does in the product.
pub const install = @import("app/install.zig");
pub const state_root = @import("metacodes-internal").util.state_root;
pub const release_source = @import("app/release_source.zig");
