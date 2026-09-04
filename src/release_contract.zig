//! Contract numbers the release manifest carries (#80, #47 stage 5), kept in a
//! file with no imports so `scripts/release_manifest.zig` (a host tool built
//! outside the app module graph) and the app read the same constants.
//!
//! `CLI_SURFACE_VERSION` is the flag surface documented in doc/API.md ("CLI
//! surface"): it changes only with a documented breaking change to the flags
//! or subcommands. `CONFIG_SCHEMA_VERSION` is the `schema_version` of
//! `~/.metacodes/config.json`; `app/config.zig` re-exports it.

pub const CLI_SURFACE_VERSION: u32 = 1;
pub const CONFIG_SCHEMA_VERSION: u32 = 1;
