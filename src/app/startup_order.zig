//! The startup order (#486; #485, #499, #527): which of five levels decides
//! the provider a start uses, first that applies wins. `decide` reads only
//! facts gathered beforehand, so the start (`main`) and `metacodes login
//! status` take the same decision, the one the start applies and the other
//! shows.
//!
//!   1. a provider or an offer named at start: `--provider`, `--offer`,
//!      `METACODES_PROVIDER` in the environment;
//!   2. the default stored with `/model` (config.json `global_selection`),
//!      while its provider has a credential;
//!   3. a Metask sign-in: a key the historical path reads (`--api-key`,
//!      `METASK_API_KEY` in the environment or in `.env`, a key or an older
//!      sign-in in `auth.json`), else the Metask session (`oauth/metask.json`);
//!   4. the provider `<state root>/.env` configures: its `METACODES_PROVIDER`,
//!      else the one provider whose key it holds;
//!   5. nothing: the interactive TUI opens without a model, anything else
//!      stops.

const std = @import("std");
const state_env = @import("state_env.zig");

/// Level 2, judged before it is applied (#485).
pub const StoredDefault = union(enum) {
    /// No `global_selection` is stored.
    none,
    /// config.json cannot be read: the start says so when it consults it,
    /// and the levels below decide.
    unreadable,
    /// Stored, and its provider has a credential (or it does not resolve,
    /// which the start reports as it always has). Its name
    /// (`DeepSeek · deepseek-v4-pro`) when it resolves.
    usable: ?[]const u8,
    /// Stored, but its provider has no credential: passed over. Its name.
    lacks_credential: []const u8,

    /// Whether the start consults it (`applyPersistedGlobalSelection`).
    pub fn consulted(self: StoredDefault) bool {
        return self == .usable or self == .unreadable;
    }
};

pub const Facts = struct {
    /// Level 1: a provider or an offer named by a flag or the environment.
    named: bool,
    /// Level 2; `.none` when level 1 named one, which is not judged then.
    stored_default: StoredDefault,
    /// Level 3, the historical path: a key that signs Metask in, or a login
    /// stored in `auth.json` (one that cannot be read counts, so the start
    /// says why rather than quietly using another provider).
    metask_key: bool,
    /// Level 3: the historical path was asked for (`--api-key`, or
    /// `METASK_API_KEY` under `api_key_first`), by a variable that is set
    /// even if empty. The session is not used then; the file's provider is.
    metask_key_requested: bool,
    /// Level 3: the Metask session (`oauth/metask.json`), which the browser
    /// sign-in and the device code store.
    metask_session: bool,
    /// Level 4.
    local: state_env.Choice,
};

pub const Decision = enum {
    named,
    stored_default,
    metask_key,
    metask_session,
    local_provider,
    /// The file holds keys of several providers and names none: nothing is
    /// chosen, and the start lists them.
    local_unchosen,
    nothing,

    /// The level that decided, 1 to 5. A file that names no provider among
    /// several decided nothing: level 5.
    pub fn level(self: Decision) u8 {
        return switch (self) {
            .named => 1,
            .stored_default => 2,
            .metask_key, .metask_session => 3,
            .local_provider => 4,
            .local_unchosen, .nothing => 5,
        };
    }
};

/// The level that decides, first that applies wins.
pub fn decide(read: Facts) Decision {
    if (read.named) return .named;
    if (read.stored_default == .usable) return .stored_default;
    if (read.metask_key) return .metask_key;
    if (read.metask_session and !read.metask_key_requested) return .metask_session;
    return switch (read.local) {
        .provider => .local_provider,
        .several => .local_unchosen,
        .none => .nothing,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn factsWith(overrides: anytype) Facts {
    var value: Facts = .{
        .named = false,
        .stored_default = .none,
        .metask_key = false,
        .metask_key_requested = false,
        .metask_session = false,
        .local = .none,
    };
    inline for (std.meta.fields(@TypeOf(overrides))) |field| @field(value, field.name) = @field(overrides, field.name);
    return value;
}

const deepseek_file: state_env.Choice = .{ .provider = .{ .name = "deepseek", .named = false } };

test "every level outranks the ones below it" {
    const everything = factsWith(.{
        .named = true,
        .stored_default = StoredDefault{ .usable = "DeepSeek · deepseek-v4-pro" },
        .metask_key = true,
        .metask_session = true,
        .local = deepseek_file,
    });
    try testing.expectEqual(Decision.named, decide(everything));
    var below = everything;
    below.named = false;
    try testing.expectEqual(Decision.stored_default, decide(below));
    below.stored_default = .none;
    try testing.expectEqual(Decision.metask_key, decide(below));
    below.metask_key = false;
    try testing.expectEqual(Decision.metask_session, decide(below));
    below.metask_session = false;
    try testing.expectEqual(Decision.local_provider, decide(below));
    below.local = .none;
    try testing.expectEqual(Decision.nothing, decide(below));
}

test "a stored default without a credential, or unreadable, is passed over" {
    try testing.expectEqual(Decision.metask_session, decide(factsWith(.{
        .stored_default = StoredDefault{ .lacks_credential = "DeepSeek · deepseek-v4-pro" },
        .metask_session = true,
    })));
    try testing.expectEqual(Decision.local_provider, decide(factsWith(.{ .stored_default = .unreadable, .local = deepseek_file })));
    const unreadable: StoredDefault = .unreadable;
    try testing.expect(unreadable.consulted());
    try testing.expect(!(StoredDefault{ .lacks_credential = "x" }).consulted());
}

test "asking for the historical path sets the session aside, but not the file's provider" {
    // `METASK_API_KEY=` (empty) under api_key_first signs nothing in.
    try testing.expectEqual(Decision.local_provider, decide(factsWith(.{
        .metask_key_requested = true,
        .metask_session = true,
        .local = deepseek_file,
    })));
}

test "a file with several providers' keys and no name decides nothing" {
    const several: state_env.Choice = .{ .several = &.{ "deepseek", "kimi" } };
    const decision = decide(factsWith(.{ .local = several }));
    try testing.expectEqual(Decision.local_unchosen, decision);
    try testing.expectEqual(@as(u8, 5), decision.level());
    try testing.expectEqual(@as(u8, 3), Decision.metask_session.level());
}
