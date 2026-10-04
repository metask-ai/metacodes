//! Host wiring for the System-One advisor: configuration and an
//! address-stable client/advisor pair.
//!
//! Three layers, each field taken from the highest one that sets it:
//!
//! 1. The built-in default (`BUILTIN_DEFAULT`), when the host asks for it.
//!    The CLI does; library embedders and in-process tests do not, so a host
//!    that never opted in never sends a session's state anywhere.
//! 2. The install's `<state root>/config.json`, under `jev`:
//!
//!        "jev": { "url": "http://host:10420", "mode": "shadow", "timeout_ms": 2500,
//!                 "model": "metask-jev-4b", "decisions": ["scoped_recall"] }
//!
//! 3. Each `METACODES_JEV_*` variable (the env-over-file rule of the rest of
//!    the configuration; evaluation harnesses inject them per arm).
//!
//! An empty or `off` `url` from any layer means no advisor: `"jev": false`,
//! `"jev": {"url": "off"}` or `METACODES_JEV_URL=off` turn the default off. A `url`
//! installs it in `shadow` mode unless the layers say otherwise — the judge is
//! asked and journaled while every host decision keeps its deterministic
//! baseline; `mode: "advisory"` lets the documented consumer policies use the
//! answers; `decisions` narrows it to a subset of its surfaces (default: all,
//! except that the built-in default advises `scoped_recall` only).
//! A malformed setting, from any source, disables the advisor with a warning
//! instead of guessing: an advisor is never worth failing a session over.

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

/// Pure interpretation of the five variables; a null, blank or `off` URL means
/// the advisor is not configured (`off` because an empty variable cannot be
/// set everywhere: PowerShell deletes it). Borrowed slices stay borrowed.
pub fn parseSettings(
    url: ?[]const u8,
    mode: ?[]const u8,
    timeout_ms: ?[]const u8,
    model: ?[]const u8,
    decisions: ?[]const u8,
) SettingsError!?Settings {
    const origin = std.mem.trim(u8, url orelse return null, " \t\r\n");
    if (origin.len == 0 or std.ascii.eqlIgnoreCase(origin, "off")) return null;
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

/// The service the CLI uses when neither config.json nor the environment
/// names one: the team's metask-jev-4b on the Kunshan GPU host. Plain HTTP
/// over the public network — the state it judges (a redacted window of the
/// session) travels unencrypted; point `url` elsewhere, or empty it, to stop
/// that.
///
/// Only `scoped_recall` is advised: it is the one surface the paired pilots
/// found worth having (doc/JEV_SYSTEM_ONE.md §7). The `KgRecall` annotation
/// cancelled the recall gate's gain in verified evidence, the relation judge
/// was never consulted, and the enumeration judge never crossed its threshold,
/// while each consultation is a synchronous round trip. `decisions` from
/// config.json or the environment still replaces this list.
pub const BUILTIN_DEFAULT: Raw = .{
    .url = "http://58.211.6.133:10420",
    .mode = "advisory",
    .model = "metask-jev-4b",
    .decisions = "scoped_recall",
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
    switch (section) {
        .null => return .{},
        // `false` is the short form of `{"url": "off"}`: no advisor, default or not.
        .bool => |on| return if (on) error.InvalidJevSection else .{ .url = "" },
        .object => {},
        else => return error.InvalidJevSection,
    }
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

/// Where the effective configuration came from, for `doctor` and the log:
/// the layers above the built-in default that set anything, or `default`
/// when only it applies.
pub const Source = enum { none, default, file, env, file_and_env };

pub fn sourceOf(builtin: Raw, file: Raw, env: Raw) Source {
    if (file.any() and env.any()) return .file_and_env;
    if (env.any()) return .env;
    if (file.any()) return .file;
    if (builtin.any()) return .default;
    return .none;
}

/// The effective configuration, judged without contacting the service.
pub const Resolution = union(enum) {
    /// No url from any layer.
    off: Source,
    on: struct { settings: Settings, source: Source },
    /// config.json unreadable or malformed, or a value refused.
    invalid: struct { err: ResolveError, source: Source },
};

pub const ResolveError = FileError || SettingsError;

/// Layer `env` over the state root's config.json over the built-in default
/// (when `builtin_default`). The default is one service — its mode and model
/// pin describe that service — so it applies only while no layer names a
/// `url`: a url of one's own starts from the plain defaults (shadow, no model
/// pin), while a layer that only tunes the mode or timeout tunes the
/// default's. Pure apart from reading the file; strings borrow from `arena`
/// and `env`.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, state_root: []const u8, builtin_default: bool, env: Raw) Resolution {
    const file = rawFromFile(arena, io, state_root) catch |err| return .{ .invalid = .{ .err = err, .source = .file } };
    const upper = file.overlay(env);
    const builtin: Raw = if (builtin_default and upper.url == null) BUILTIN_DEFAULT else .{};
    const source = sourceOf(builtin, file, env);
    const settings = (parseRaw(builtin.overlay(upper)) catch |err|
        return .{ .invalid = .{ .err = err, .source = source } }) orelse return .{ .off = source };
    return .{ .on = .{ .settings = settings, .source = source } };
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

/// Build the configured runtime (see the module comment for the layers), or
/// null when unconfigured or invalid. Every refusal is logged once with its
/// reason; none is fatal.
pub fn load(allocator: std.mem.Allocator, io: std.Io, home: []const u8, state_root: []const u8, builtin_default: bool) ?*Runtime {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit(); // the client copies what it keeps
    const resolved = switch (resolve(arena_state.allocator(), io, state_root, builtin_default, rawFromEnv())) {
        .off => return null,
        .invalid => |invalid| {
            log.warn("jev", "System-One advisor disabled: {s} (source={s}; {s}/config.json \"{s}\" or METACODES_JEV_*)", .{ @errorName(invalid.err), @tagName(invalid.source), state_root, CONFIG_KEY });
            return null;
        },
        .on => |on| on,
    };
    const runtime = Runtime.create(allocator, io, resolved.settings, home) catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} for url {s}", .{ @errorName(err), resolved.settings.origin });
        return null;
    };
    log.info("jev", "System-One advisor enabled mode={s} timeout_ms={d} source={s}", .{ @tagName(resolved.settings.mode), resolved.settings.timeout_ms, @tagName(resolved.source) });
    return runtime;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseSettings: unset or blank URL means no advisor" {
    try testing.expect((try parseSettings(null, "advisory", null, null, null)) == null);
    try testing.expect((try parseSettings("  ", null, null, null, null)) == null);
    try testing.expect((try parseSettings(" OFF ", "advisory", null, null, null)) == null);
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
    try testing.expectEqual(Source.file_and_env, sourceOf(.{}, file, env));
    try testing.expectEqual(Source.file, sourceOf(.{}, file, .{}));
    try testing.expectEqual(Source.env, sourceOf(.{}, .{}, env));
    try testing.expectEqual(Source.none, sourceOf(.{}, .{}, .{}));
    // The env alone still configures it, as before.
    try testing.expectEqualStrings("http://env:2", (try parseRaw((Raw{}).overlay(.{ .url = "http://env:2" }))).?.origin);
}

fn resolveWith(arena: std.mem.Allocator, config_json: ?[]const u8, builtin_default: bool, env: Raw) !Resolution {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    if (config_json) |bytes| try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = bytes });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    return resolve(arena, testing.io, root, builtin_default, env);
}

test "resolve: the built-in default applies only when the host asks, beneath file and env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Nothing configured: the CLI gets the default, an embedder gets nothing.
    const cli = (try resolveWith(a, null, true, .{})).on;
    try testing.expectEqualStrings(BUILTIN_DEFAULT.url.?, cli.settings.origin);
    try testing.expectEqual(advisor_mod.Mode.advisory, cli.settings.mode);
    try testing.expectEqualStrings("metask-jev-4b", cli.settings.expected_model.?);
    try testing.expectEqual(client_mod.DEFAULT_TIMEOUT_MS, cli.settings.timeout_ms);
    try testing.expect(cli.settings.surfaces.eql(.initOne(.scoped_recall)));
    try testing.expectEqual(Source.default, cli.source);
    try testing.expectEqual(Source.none, (try resolveWith(a, null, false, .{})).off);
    // A config.json without the section, or with a null one, keeps the default.
    try testing.expectEqual(Source.default, (try resolveWith(a, "{\"mcp_servers\":{}}", true, .{})).on.source);
    try testing.expectEqual(Source.default, (try resolveWith(a, "{\"jev\":null}", true, .{})).on.source);

    // A field the file sets replaces the default's; the others stay.
    const shadow = (try resolveWith(a, "{\"jev\":{\"mode\":\"shadow\",\"timeout_ms\":4000}}", true, .{})).on;
    try testing.expectEqualStrings(BUILTIN_DEFAULT.url.?, shadow.settings.origin);
    try testing.expectEqual(advisor_mod.Mode.shadow, shadow.settings.mode);
    try testing.expectEqual(@as(u32, 4000), shadow.settings.timeout_ms);
    try testing.expect(shadow.settings.surfaces.eql(.initOne(.scoped_recall)));
    try testing.expectEqual(Source.file, shadow.source);
    // `decisions` from either layer replaces the default's list.
    const file_surfaces = (try resolveWith(a, "{\"jev\":{\"decisions\":[\"scoped_recall\",\"memory_relation\"]}}", true, .{})).on;
    try testing.expectEqualStrings(BUILTIN_DEFAULT.url.?, file_surfaces.settings.origin);
    var scoped_and_relation: advisor_mod.Surfaces = .initOne(.scoped_recall);
    scoped_and_relation.insert(.memory_relation);
    try testing.expect(file_surfaces.settings.surfaces.eql(scoped_and_relation));
    const env_surfaces = (try resolveWith(a, null, true, .{ .decisions = "recall_evidence" })).on;
    try testing.expect(env_surfaces.settings.surfaces.eql(.initOne(.recall_evidence)));
    // ...and the env's replace both.
    const env_url = (try resolveWith(a, "{\"jev\":{\"url\":\"http://file:1\"}}", true, .{ .url = "http://env:2" })).on;
    try testing.expectEqualStrings("http://env:2", env_url.settings.origin);
    try testing.expectEqual(Source.file_and_env, env_url.source);
    // A url of one's own does not inherit the default service's mode or model
    // pin: a different model would be refused on every consultation.
    for ([_]Resolution{
        try resolveWith(a, "{\"jev\":{\"url\":\"http://mine:1\"}}", true, .{}),
        try resolveWith(a, null, true, .{ .url = "http://mine:1" }),
    }) |own| {
        try testing.expectEqualStrings("http://mine:1", own.on.settings.origin);
        try testing.expectEqual(advisor_mod.Mode.shadow, own.on.settings.mode);
        try testing.expect(own.on.settings.expected_model == null);
        try testing.expect(own.on.settings.surfaces.eql(.initFull()));
    }
    // The file alone configures an embedder, as before.
    try testing.expectEqualStrings("http://file:1", (try resolveWith(a, "{\"jev\":{\"url\":\"http://file:1\"}}", false, .{})).on.settings.origin);
}

test "resolve: an empty url from any layer turns the default off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(Source.file, (try resolveWith(a, "{\"jev\":false}", true, .{})).off);
    try testing.expectEqual(Source.file, (try resolveWith(a, "{\"jev\":{\"url\":\"\"}}", true, .{})).off);
    try testing.expectEqual(Source.file, (try resolveWith(a, "{\"jev\":{\"url\":\"off\"}}", true, .{})).off);
    // `METACODES_JEV_URL=off` is what the build's steps export; an empty
    // value, where the shell can set one, means the same.
    try testing.expectEqual(Source.env, (try resolveWith(a, null, true, .{ .url = "off" })).off);
    try testing.expectEqual(Source.env, (try resolveWith(a, null, true, .{ .url = "" })).off);
    // ...and the env can turn it back on over a file that turned it off.
    try testing.expectEqualStrings("http://env:2", (try resolveWith(a, "{\"jev\":false}", true, .{ .url = "http://env:2" })).on.settings.origin);
    // `true` is not a configuration.
    try testing.expectEqual(error.InvalidJevSection, (try resolveWith(a, "{\"jev\":true}", true, .{})).invalid.err);
}

test "resolve: a broken file or value is refused, not replaced by the default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const not_json = (try resolveWith(a, "{", true, .{})).invalid;
    try testing.expectEqual(error.ConfigNotJson, not_json.err);
    try testing.expectEqual(Source.file, not_json.source);
    const misspelt = (try resolveWith(a, "{\"jev\":{\"timeout\":800}}", true, .{})).invalid;
    try testing.expectEqual(error.InvalidJevSection, misspelt.err);
    const bad_mode = (try resolveWith(a, null, true, .{ .mode = "enforced" })).invalid;
    try testing.expectEqual(error.InvalidMode, bad_mode.err);
    try testing.expectEqual(Source.env, bad_mode.source);
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
