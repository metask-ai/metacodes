//! Host wiring for the System-One advisor: configuration and an
//! address-stable client/advisor pair.
//!
//! Configured in the install's `<state root>/config.json`, under `jev`:
//!
//!     "jev": { "url": "http://host:10420", "mode": "shadow", "timeout_ms": 2500,
//!              "model": "metask-jev-4b", "decisions": ["scoped_recall"] }
//!
//! Each `METACODES_JEV_*` variable overrides its field (the env-over-file rule
//! of the rest of the configuration; evaluation harnesses inject them per arm).
//! Off by default: no `url` from either source means no advisor. A `url`
//! installs it in `shadow` mode — the judge is asked and journaled while every
//! host decision keeps its deterministic baseline; `mode: "advisory"` lets the
//! documented consumer policies use the answers; `decisions` narrows it to a
//! subset of its surfaces (default: all). A malformed setting, from either
//! source, disables the advisor with a warning instead of guessing: an advisor
//! is never worth failing a session over.

const std = @import("std");
const client_mod = @import("client.zig");
const advisor_mod = @import("advisor.zig");
const log = @import("../util/log.zig");

pub const ENV_URL = "METACODES_JEV_URL";
pub const ENV_MODE = "METACODES_JEV_MODE";
pub const ENV_TIMEOUT_MS = "METACODES_JEV_TIMEOUT_MS";
pub const ENV_MODEL = "METACODES_JEV_MODEL";
pub const ENV_DECISIONS = "METACODES_JEV_DECISIONS";

pub const Settings = struct {
    origin: []const u8,
    mode: advisor_mod.Mode = .shadow,
    timeout_ms: u32 = client_mod.DEFAULT_TIMEOUT_MS,
    expected_model: ?[]const u8 = null,
    surfaces: advisor_mod.Surfaces = .initFull(),
};

pub const SettingsError = error{ InvalidMode, InvalidTimeout, InvalidDecisions };

/// Pure interpretation of the five variables; a null or blank URL means the
/// advisor is not configured. Borrowed slices stay borrowed.
pub fn parseSettings(
    url: ?[]const u8,
    mode: ?[]const u8,
    timeout_ms: ?[]const u8,
    model: ?[]const u8,
    decisions: ?[]const u8,
) SettingsError!?Settings {
    const origin = std.mem.trim(u8, url orelse return null, " \t\r\n");
    if (origin.len == 0) return null;
    var settings: Settings = .{ .origin = origin };
    if (mode) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        settings.mode = std.meta.stringToEnum(advisor_mod.Mode, value) orelse return error.InvalidMode;
    }
    if (timeout_ms) |raw| {
        const value = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return error.InvalidTimeout;
        if (value < client_mod.MIN_TIMEOUT_MS or value > client_mod.MAX_TIMEOUT_MS) return error.InvalidTimeout;
        settings.timeout_ms = value;
    }
    if (model) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len > 0) settings.expected_model = value;
    }
    if (decisions) |raw| settings.surfaces = try parseSurfaces(raw);
    return settings;
}

/// A comma-separated, non-empty subset of `advisor.Surface` names. An empty
/// list is refused rather than read as "none": that is what leaving
/// METACODES_JEV_URL unset means.
fn parseSurfaces(raw: []const u8) SettingsError!advisor_mod.Surfaces {
    var surfaces: advisor_mod.Surfaces = .initEmpty();
    var names = std.mem.splitScalar(u8, raw, ',');
    while (names.next()) |name| {
        const value = std.mem.trim(u8, name, " \t\r\n");
        surfaces.insert(std.meta.stringToEnum(advisor_mod.Surface, value) orelse return error.InvalidDecisions);
    }
    if (surfaces.count() == 0) return error.InvalidDecisions;
    return surfaces;
}

pub fn settingsFromEnv() SettingsError!?Settings {
    return parseSettings(envGet(ENV_URL), envGet(ENV_MODE), envGet(ENV_TIMEOUT_MS), envGet(ENV_MODEL), envGet(ENV_DECISIONS));
}

/// The five settings as text, the shape both sources reduce to.
pub const Raw = struct {
    url: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    timeout_ms: ?[]const u8 = null,
    model: ?[]const u8 = null,
    decisions: ?[]const u8 = null,

    /// `self` with every field `over` sets replacing it.
    pub fn overlay(self: Raw, over: Raw) Raw {
        return .{
            .url = over.url orelse self.url,
            .mode = over.mode orelse self.mode,
            .timeout_ms = over.timeout_ms orelse self.timeout_ms,
            .model = over.model orelse self.model,
            .decisions = over.decisions orelse self.decisions,
        };
    }

    fn any(self: Raw) bool {
        return self.url != null or self.mode != null or self.timeout_ms != null or self.model != null or self.decisions != null;
    }
};

pub const CONFIG_KEY = "jev";
const MAX_CONFIG_BYTES: usize = 1 << 20;

pub const FileError = error{ OutOfMemory, ConfigUnreadable, ConfigNotJson, InvalidJevSection };

/// The `jev` object of `<state root>/config.json` (`.{}` when the file or the
/// key is absent). Strings live in `arena`. Values keep the env's text shape:
/// `timeout_ms` a JSON integer, `decisions` an array of names (or the same
/// comma-separated string the variable takes). An unknown key in the section
/// is refused, so a misspelt `timeout` cannot pass for the default.
pub fn rawFromFile(arena: std.mem.Allocator, io: std.Io, state_root: []const u8) FileError!Raw {
    if (state_root.len == 0) return .{};
    const path = std.fmt.allocPrint(arena, "{s}/config.json", .{state_root}) catch return error.OutOfMemory;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigUnreadable,
    };
    return rawFromJson(arena, bytes);
}

pub fn rawFromJson(arena: std.mem.Allocator, bytes: []const u8) FileError!Raw {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigNotJson,
    };
    if (parsed != .object) return error.ConfigNotJson;
    const section = parsed.object.get(CONFIG_KEY) orelse return .{};
    if (section == .null) return .{};
    if (section != .object) return error.InvalidJevSection;
    var raw: Raw = .{};
    var it = section.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "url")) {
            raw.url = try stringField(value);
        } else if (std.mem.eql(u8, key, "mode")) {
            raw.mode = try stringField(value);
        } else if (std.mem.eql(u8, key, "model")) {
            raw.model = try stringField(value);
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            raw.timeout_ms = switch (value) {
                .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch return error.OutOfMemory,
                .null => null,
                else => return error.InvalidJevSection,
            };
        } else if (std.mem.eql(u8, key, "decisions")) {
            raw.decisions = switch (value) {
                .string => |text| text,
                .array => |items| blk: {
                    var joined: std.ArrayList(u8) = .empty;
                    for (items.items, 0..) |item, index| {
                        if (item != .string) return error.InvalidJevSection;
                        if (index > 0) joined.append(arena, ',') catch return error.OutOfMemory;
                        joined.appendSlice(arena, item.string) catch return error.OutOfMemory;
                    }
                    break :blk joined.items;
                },
                .null => null,
                else => return error.InvalidJevSection,
            };
        } else return error.InvalidJevSection;
    }
    return raw;
}

fn stringField(value: std.json.Value) FileError!?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => error.InvalidJevSection,
    };
}

pub fn rawFromEnv() Raw {
    return .{
        .url = envGet(ENV_URL),
        .mode = envGet(ENV_MODE),
        .timeout_ms = envGet(ENV_TIMEOUT_MS),
        .model = envGet(ENV_MODEL),
        .decisions = envGet(ENV_DECISIONS),
    };
}

/// Where the effective configuration came from, for `doctor` and the log.
pub const Source = enum { none, file, env, file_and_env };

pub fn sourceOf(file: Raw, env: Raw) Source {
    if (file.any() and env.any()) return .file_and_env;
    if (env.any()) return .env;
    if (file.any()) return .file;
    return .none;
}

pub fn parseRaw(raw: Raw) SettingsError!?Settings {
    return parseSettings(raw.url, raw.mode, raw.timeout_ms, raw.model, raw.decisions);
}

fn envGet(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

/// Heap-pinned so `advisor.client` stays valid for the runtime's lifetime.
pub const Runtime = struct {
    client: client_mod.Client,
    advisor: advisor_mod.Advisor,
    /// Owned copy of the home directory redacted from outgoing state.
    home: []u8,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        settings: Settings,
        home: []const u8,
    ) (client_mod.ConfigError || error{OutOfMemory})!*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const home_copy = try allocator.dupe(u8, home);
        errdefer allocator.free(home_copy);
        self.* = .{
            .client = try client_mod.Client.init(allocator, io, .{
                .origin = settings.origin,
                .timeout_ms = settings.timeout_ms,
                .expected_model = settings.expected_model,
            }),
            .advisor = undefined,
            .home = home_copy,
        };
        self.advisor = .{ .client = &self.client, .mode = settings.mode, .home = self.home, .surfaces = settings.surfaces };
        return self;
    }

    pub fn destroy(self: *Runtime, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.home);
        allocator.destroy(self);
    }
};

/// Build the configured runtime from `<state root>/config.json` with the
/// `METACODES_JEV_*` overrides, or null when unconfigured or invalid. Every
/// refusal is logged once with its reason; none is fatal.
pub fn load(allocator: std.mem.Allocator, io: std.Io, home: []const u8, state_root: []const u8) ?*Runtime {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit(); // the client copies what it keeps
    const file = rawFromFile(arena_state.allocator(), io, state_root) catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} in {s}/config.json (\"{s}\")", .{ @errorName(err), state_root, CONFIG_KEY });
        return null;
    };
    const env = rawFromEnv();
    const source = sourceOf(file, env);
    const settings = (parseRaw(file.overlay(env)) catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} (config.json \"{s}\" or METACODES_JEV_*)", .{ @errorName(err), CONFIG_KEY });
        return null;
    }) orelse return null;
    const runtime = Runtime.create(allocator, io, settings, home) catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} for url {s}", .{ @errorName(err), settings.origin });
        return null;
    };
    log.info("jev", "System-One advisor enabled mode={s} timeout_ms={d} source={s}", .{ @tagName(settings.mode), settings.timeout_ms, @tagName(source) });
    return runtime;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseSettings: unset or blank URL means no advisor" {
    try testing.expect((try parseSettings(null, "advisory", null, null, null)) == null);
    try testing.expect((try parseSettings("  ", null, null, null, null)) == null);
}

test "parseSettings: shadow is the default mode and every field is honored" {
    const defaults = (try parseSettings("http://127.0.0.1:10420", null, null, null, null)).?;
    try testing.expectEqual(advisor_mod.Mode.shadow, defaults.mode);
    try testing.expectEqual(client_mod.DEFAULT_TIMEOUT_MS, defaults.timeout_ms);
    try testing.expect(defaults.expected_model == null);
    try testing.expectEqual(@as(usize, 4), defaults.surfaces.count());

    const explicit = (try parseSettings(" http://h:1 ", "advisory", "800", "metask-jev-4b", " scoped_recall ,memory_relation")).?;
    try testing.expectEqualStrings("http://h:1", explicit.origin);
    try testing.expectEqual(advisor_mod.Mode.advisory, explicit.mode);
    try testing.expectEqual(@as(u32, 800), explicit.timeout_ms);
    try testing.expectEqualStrings("metask-jev-4b", explicit.expected_model.?);
    try testing.expect(explicit.surfaces.contains(.scoped_recall));
    try testing.expect(explicit.surfaces.contains(.memory_relation));
    try testing.expect(!explicit.surfaces.contains(.recall_evidence));
    try testing.expect(!explicit.surfaces.contains(.enumeration_intent));
}

test "parseSettings: malformed mode, timeout or decisions are refused, not guessed" {
    try testing.expectError(error.InvalidMode, parseSettings("http://h", "enforced", null, null, null));
    try testing.expectError(error.InvalidTimeout, parseSettings("http://h", null, "fast", null, null));
    try testing.expectError(error.InvalidTimeout, parseSettings("http://h", null, "5", null, null));
    try testing.expectError(error.InvalidDecisions, parseSettings("http://h", null, null, null, "scoped_recall,routing"));
    try testing.expectError(error.InvalidDecisions, parseSettings("http://h", null, null, null, ""));
    try testing.expectError(error.InvalidDecisions, parseSettings("http://h", null, null, null, "scoped_recall,"));
}

test "config file: the jev section reads into the env's shape, unknown keys refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const full = try rawFromJson(a,
        \\{"model":"glm","mcp_servers":[],"jev":{"url":"http://127.0.0.1:10420","mode":"advisory",
        \\ "timeout_ms":800,"model":"metask-jev-4b","decisions":["scoped_recall","memory_relation"]}}
    );
    try testing.expectEqualStrings("http://127.0.0.1:10420", full.url.?);
    try testing.expectEqualStrings("advisory", full.mode.?);
    try testing.expectEqualStrings("800", full.timeout_ms.?);
    try testing.expectEqualStrings("metask-jev-4b", full.model.?);
    try testing.expectEqualStrings("scoped_recall,memory_relation", full.decisions.?);
    const settings = (try parseRaw(full)).?;
    try testing.expectEqual(advisor_mod.Mode.advisory, settings.mode);
    try testing.expectEqual(@as(u32, 800), settings.timeout_ms);
    try testing.expectEqual(@as(usize, 2), settings.surfaces.count());

    // No section, or a null one: no advisor.
    try testing.expect((try parseRaw(try rawFromJson(a, "{\"model\":\"glm\"}"))) == null);
    try testing.expect((try parseRaw(try rawFromJson(a, "{\"jev\":null}"))) == null);
    // A comma string for decisions is the variable's form and is accepted too.
    try testing.expectEqualStrings("scoped_recall", (try rawFromJson(a, "{\"jev\":{\"decisions\":\"scoped_recall\"}}")).decisions.?);
    // Misspelt or mistyped fields are refused rather than defaulted.
    try testing.expectError(error.InvalidJevSection, rawFromJson(a, "{\"jev\":{\"url\":\"http://h:1\",\"timeout\":800}}"));
    try testing.expectError(error.InvalidJevSection, rawFromJson(a, "{\"jev\":{\"timeout_ms\":\"800\"}}"));
    try testing.expectError(error.InvalidJevSection, rawFromJson(a, "{\"jev\":{\"decisions\":[\"scoped_recall\",3]}}"));
    try testing.expectError(error.InvalidJevSection, rawFromJson(a, "{\"jev\":\"http://h:1\"}"));
    try testing.expectError(error.ConfigNotJson, rawFromJson(a, "not json"));
    // Values the file carries are validated by the same rules as the env's.
    try testing.expectError(error.InvalidTimeout, parseRaw(try rawFromJson(a, "{\"jev\":{\"url\":\"http://h:1\",\"timeout_ms\":5}}")));
}

test "config file: each METACODES_JEV_* overrides its own field only" {
    const file: Raw = .{ .url = "http://file:1", .mode = "advisory", .timeout_ms = "800", .model = "file-model", .decisions = "scoped_recall" };
    const env: Raw = .{ .mode = "shadow", .timeout_ms = "1200" };
    const merged = file.overlay(env);
    try testing.expectEqualStrings("http://file:1", merged.url.?);
    try testing.expectEqualStrings("shadow", merged.mode.?);
    try testing.expectEqualStrings("1200", merged.timeout_ms.?);
    try testing.expectEqualStrings("file-model", merged.model.?);
    try testing.expectEqualStrings("scoped_recall", merged.decisions.?);
    try testing.expectEqual(Source.file_and_env, sourceOf(file, env));
    try testing.expectEqual(Source.file, sourceOf(file, .{}));
    try testing.expectEqual(Source.env, sourceOf(.{}, env));
    try testing.expectEqual(Source.none, sourceOf(.{}, .{}));
    // The env alone still configures it, as before.
    try testing.expectEqualStrings("http://env:2", (try parseRaw((Raw{}).overlay(.{ .url = "http://env:2" }))).?.origin);
}

test "Runtime pins the advisor to its own client, home copy and surfaces" {
    const runtime = try Runtime.create(testing.allocator, testing.io, .{ .origin = "http://127.0.0.1:9", .mode = .advisory, .surfaces = .initOne(.scoped_recall) }, "/Users/alice");
    defer runtime.destroy(testing.allocator);
    try testing.expect(runtime.advisor.client == &runtime.client);
    try testing.expect(runtime.advisor.actuates());
    try testing.expectEqualStrings("/Users/alice", runtime.advisor.home);
    try testing.expect(runtime.advisor.advises(.scoped_recall));
    try testing.expect(!runtime.advisor.advises(.recall_evidence));
}
