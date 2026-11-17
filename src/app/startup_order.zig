//! The startup order (#486; #485, #499, #527, #489): which of seven levels
//! decides the provider a start uses, first that applies wins. `decide`
//! reads only facts gathered beforehand, so the start (`main`) and
//! `metacodes login status` take the same decision, the one the start
//! applies and the other shows.
//!
//!   1. a provider or an offer named at start: `--provider`, `--offer`,
//!      `METACODES_PROVIDER` in the environment;
//!   2. a preset named at start: `--preset`, `METACODES_PRESET` in the
//!      environment (config.json `presets`, #489);
//!   3. the preset the working directory remembers (config.json
//!      `directory_presets`, keyed by the git worktree root, else the working
//!      directory; `presets.zig`);
//!   4. the default stored with `/model` (config.json `global_selection`),
//!      while its provider has a credential;
//!   5. a Metask sign-in: a key the historical path reads (`--api-key`,
//!      `METASK_API_KEY` in the environment or in `.env`, a key or an older
//!      sign-in in `auth.json`), else the Metask session (`oauth/metask.json`);
//!   6. `<state root>/.env`: its `METACODES_PRESET`, else its
//!      `METACODES_PROVIDER`, else the one provider whose key it holds;
//!   7. nothing: the interactive TUI opens without a model, anything else
//!      stops.
//!
//! A preset (levels 2, 3 and 6) names its route as level 1 would, so one
//! whose provider has no credential is not replaced by another: the TUI
//! opens without a model, anything else stops. A preset config.json does not
//! define decides nothing; the start reports it (`unknownPresets`).

const std = @import("std");
const state_env = @import("state_env.zig");

/// How many levels there are; `login status` says "Level N of `levels`".
pub const levels: u8 = 7;

/// A preset a level names (#489), judged against config.json.
pub const Preset = union(enum) {
    /// The level names none.
    none,
    /// config.json defines it.
    found: Found,
    /// config.json does not define it, or cannot be read: the level decides
    /// nothing, and the start says so. The name.
    unknown: []const u8,

    pub const Found = struct {
        name: []const u8,
        /// Its route (`House relay · relay-model`) and that route's provider
        /// id, when it resolves; `login status` shows them. Null otherwise,
        /// and then the start reports why it does not resolve.
        label: ?[]const u8 = null,
        provider: ?[]const u8 = null,
    };
};

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
    /// Level 2: `--preset`, else `METACODES_PRESET` in the environment.
    preset: Preset = .none,
    /// Level 3: the preset the working directory remembers.
    directory_preset: Preset = .none,
    /// Level 4; `.none` when a level above decides, which is not judged
    /// then.
    stored_default: StoredDefault,
    /// Level 5, the historical path: a key that signs Metask in, or a login
    /// stored in `auth.json` (one that cannot be read counts, so the start
    /// says why rather than quietly using another provider).
    metask_key: bool,
    /// Level 5: the historical path was asked for (`--api-key`, or
    /// `METASK_API_KEY` under `api_key_first`), by a variable that is set
    /// even if empty. The session is not used then; the file's provider is.
    metask_key_requested: bool,
    /// Level 5: the Metask session (`oauth/metask.json`), which the browser
    /// sign-in and the device code store.
    metask_session: bool,
    /// Level 6: `METACODES_PRESET` in `.env`, which comes before the
    /// provider the file configures.
    local_preset: Preset = .none,
    /// Level 6.
    local: state_env.Choice,

    /// Whether a level above the stored default decides: the start judges
    /// that default only otherwise.
    pub fn decidedAboveDefault(self: Facts) bool {
        return self.named or self.preset == .found or self.directory_preset == .found;
    }
};

pub const Decision = enum {
    named,
    preset,
    directory_preset,
    stored_default,
    metask_key,
    metask_session,
    local_preset,
    local_provider,
    /// The file holds keys of several providers and names none: nothing is
    /// chosen, and the start lists them.
    local_unchosen,
    nothing,

    /// The level that decided, 1 to `levels`. A file that names no provider
    /// among several decided nothing: the last level.
    pub fn level(self: Decision) u8 {
        return switch (self) {
            .named => 1,
            .preset => 2,
            .directory_preset => 3,
            .stored_default => 4,
            .metask_key, .metask_session => 5,
            .local_preset, .local_provider => 6,
            .local_unchosen, .nothing => 7,
        };
    }

    /// Whether a preset decided (levels 2, 3, or `.env`'s at 6).
    pub fn byPreset(self: Decision) bool {
        return self == .preset or self == .directory_preset or self == .local_preset;
    }
};

/// The level that decides, first that applies wins.
pub fn decide(read: Facts) Decision {
    if (read.named) return .named;
    if (read.preset == .found) return .preset;
    if (read.directory_preset == .found) return .directory_preset;
    if (read.stored_default == .usable) return .stored_default;
    if (read.metask_key) return .metask_key;
    if (read.metask_session and !read.metask_key_requested) return .metask_session;
    if (read.local_preset == .found) return .local_preset;
    return switch (read.local) {
        .provider => .local_provider,
        .several => .local_unchosen,
        .none => .nothing,
    };
}

/// The presets config.json does not define that the start must report
/// (#489), by the level that names them: the one named at start always (it
/// was asked for by name, whatever decides), the directory's and the file's
/// when their level is reached. Null where there is nothing to report.
pub const Unknown = struct {
    named: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    local: ?[]const u8 = null,

    pub fn any(self: Unknown) bool {
        return self.named != null or self.directory != null or self.local != null;
    }
};

pub fn unknownPresets(read: Facts, decision: Decision) Unknown {
    var out: Unknown = .{};
    if (read.preset == .unknown) out.named = read.preset.unknown;
    if (read.directory_preset == .unknown and decision.level() > 3) out.directory = read.directory_preset.unknown;
    if (read.local_preset == .unknown and decision.level() >= 6) out.local = read.local_preset.unknown;
    return out;
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
    try testing.expectEqual(@as(u8, 7), decision.level());
    try testing.expectEqual(@as(u8, 5), Decision.metask_session.level());
}

// ── presets (#489) ──────────────────────────────────────────────────────────

/// A usable stored default, whatever it records about itself: only that its
/// level applies matters to the order.
fn usableDefault() StoredDefault {
    const Payload = @FieldType(StoredDefault, "usable");
    const payload: Payload = switch (@typeInfo(Payload)) {
        .optional => null,
        else => .{},
    };
    return @unionInit(StoredDefault, "usable", payload);
}

fn found(name: []const u8) Preset {
    return .{ .found = .{ .name = name } };
}

test "a preset named at start, then the directory's, rank below level 1 and above the stored default (#489)" {
    const everything = factsWith(.{
        .named = true,
        .preset = found("a"),
        .directory_preset = found("b"),
        .stored_default = usableDefault(),
        .metask_key = true,
        .metask_session = true,
        .local_preset = found("c"),
        .local = deepseek_file,
    });
    try testing.expectEqual(Decision.named, decide(everything));
    var below = everything;
    below.named = false;
    try testing.expectEqual(Decision.preset, decide(below));
    try testing.expect(below.decidedAboveDefault());
    below.preset = .none;
    try testing.expectEqual(Decision.directory_preset, decide(below));
    try testing.expect(below.decidedAboveDefault());
    below.directory_preset = .none;
    try testing.expect(!below.decidedAboveDefault());
    try testing.expectEqual(Decision.stored_default, decide(below));
    below.stored_default = .none;
    try testing.expectEqual(Decision.metask_key, decide(below));
    below.metask_key = false;
    below.metask_session = false;
    // The file's preset comes before the provider the same file configures.
    try testing.expectEqual(Decision.local_preset, decide(below));
    below.local_preset = .none;
    try testing.expectEqual(Decision.local_provider, decide(below));

    try testing.expectEqual(@as(u8, 2), Decision.preset.level());
    try testing.expectEqual(@as(u8, 3), Decision.directory_preset.level());
    try testing.expectEqual(@as(u8, 4), Decision.stored_default.level());
    try testing.expectEqual(@as(u8, 6), Decision.local_preset.level());
    try testing.expectEqual(Decision.local_provider.level(), Decision.local_preset.level());
    try testing.expectEqual(levels, Decision.nothing.level());
    for ([_]Decision{ .preset, .directory_preset, .local_preset }) |by| try testing.expect(by.byPreset());
    for ([_]Decision{ .named, .stored_default, .metask_session, .local_provider, .nothing }) |by| try testing.expect(!by.byPreset());
}

test "the file's preset, like the file's provider, ranks below a stored default and a Metask sign-in (#489)" {
    try testing.expectEqual(Decision.metask_session, decide(factsWith(.{ .metask_session = true, .local_preset = found("c") })));
    try testing.expectEqual(Decision.metask_key, decide(factsWith(.{ .metask_key = true, .local_preset = found("c") })));
    try testing.expectEqual(Decision.stored_default, decide(factsWith(.{ .stored_default = usableDefault(), .local_preset = found("c") })));
    // Asking for the historical path sets the session aside, not the file.
    try testing.expectEqual(Decision.local_preset, decide(factsWith(.{
        .metask_key_requested = true,
        .metask_session = true,
        .local_preset = found("c"),
    })));
}

test "an unknown preset decides nothing, and the start reports it once its level is reached (#489)" {
    // Named at start: the directory's preset decides instead, and the name is
    // reported; so it is when level 1 decides, since it was asked for.
    var read = factsWith(.{ .preset = Preset{ .unknown = "typo" }, .directory_preset = found("b") });
    var decision = decide(read);
    try testing.expectEqual(Decision.directory_preset, decision);
    try testing.expectEqualStrings("typo", unknownPresets(read, decision).named.?);
    read.named = true;
    decision = decide(read);
    try testing.expectEqual(Decision.named, decision);
    try testing.expectEqualStrings("typo", unknownPresets(read, decision).named.?);

    // The directory's: not consulted while level 2 decides; reported when
    // the levels below it decide.
    read = factsWith(.{ .preset = found("a"), .directory_preset = Preset{ .unknown = "gone" } });
    decision = decide(read);
    try testing.expectEqual(Decision.preset, decision);
    try testing.expect(!unknownPresets(read, decision).any());
    read.preset = .none;
    try testing.expect(!read.decidedAboveDefault());
    decision = decide(read);
    try testing.expectEqual(Decision.nothing, decision);
    try testing.expectEqualStrings("gone", unknownPresets(read, decision).directory.?);

    // The file's: not consulted while a sign-in decides; once the file's
    // level is reached it is reported, and the provider the file configures
    // decides.
    read = factsWith(.{ .metask_session = true, .local_preset = Preset{ .unknown = "x" }, .local = deepseek_file });
    decision = decide(read);
    try testing.expectEqual(Decision.metask_session, decision);
    try testing.expect(unknownPresets(read, decision).local == null);
    read.metask_session = false;
    decision = decide(read);
    try testing.expectEqual(Decision.local_provider, decision);
    try testing.expectEqualStrings("x", unknownPresets(read, decision).local.?);
}
