//! Host wiring for the System-One advisor: environment configuration and an
//! address-stable client/advisor pair.
//!
//! Off by default. Setting `METACODES_JEV_URL` installs an advisor in `shadow`
//! mode — the judge is asked and journaled while every host decision keeps its
//! deterministic baseline. `METACODES_JEV_MODE=advisory` lets the documented
//! consumer policies use the answers. A malformed setting disables the advisor
//! with a warning instead of guessing: an advisor is never worth failing a
//! session over.

const std = @import("std");
const client_mod = @import("client.zig");
const advisor_mod = @import("advisor.zig");
const log = @import("../util/log.zig");

pub const ENV_URL = "METACODES_JEV_URL";
pub const ENV_MODE = "METACODES_JEV_MODE";
pub const ENV_TIMEOUT_MS = "METACODES_JEV_TIMEOUT_MS";
pub const ENV_MODEL = "METACODES_JEV_MODEL";

pub const Settings = struct {
    origin: []const u8,
    mode: advisor_mod.Mode = .shadow,
    timeout_ms: u32 = client_mod.DEFAULT_TIMEOUT_MS,
    expected_model: ?[]const u8 = null,
};

pub const SettingsError = error{ InvalidMode, InvalidTimeout };

/// Pure interpretation of the four variables; a null or blank URL means the
/// advisor is not configured. Borrowed slices stay borrowed.
pub fn parseSettings(
    url: ?[]const u8,
    mode: ?[]const u8,
    timeout_ms: ?[]const u8,
    model: ?[]const u8,
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
    return settings;
}

pub fn settingsFromEnv() SettingsError!?Settings {
    return parseSettings(envGet(ENV_URL), envGet(ENV_MODE), envGet(ENV_TIMEOUT_MS), envGet(ENV_MODEL));
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
        self.advisor = .{ .client = &self.client, .mode = settings.mode, .home = self.home };
        return self;
    }

    pub fn destroy(self: *Runtime, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.home);
        allocator.destroy(self);
    }
};

/// Build the configured runtime, or null when unconfigured or invalid. Every
/// refusal is logged once with its reason; none is fatal.
pub fn fromEnv(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ?*Runtime {
    const settings = (settingsFromEnv() catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} ({s}/{s})", .{ @errorName(err), ENV_MODE, ENV_TIMEOUT_MS });
        return null;
    }) orelse return null;
    const runtime = Runtime.create(allocator, io, settings, home) catch |err| {
        log.warn("jev", "System-One advisor disabled: {s} for {s}", .{ @errorName(err), ENV_URL });
        return null;
    };
    log.info("jev", "System-One advisor enabled mode={s} timeout_ms={d}", .{ @tagName(settings.mode), settings.timeout_ms });
    return runtime;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseSettings: unset or blank URL means no advisor" {
    try testing.expect((try parseSettings(null, "advisory", null, null)) == null);
    try testing.expect((try parseSettings("  ", null, null, null)) == null);
}

test "parseSettings: shadow is the default mode and every field is honored" {
    const defaults = (try parseSettings("http://127.0.0.1:10420", null, null, null)).?;
    try testing.expectEqual(advisor_mod.Mode.shadow, defaults.mode);
    try testing.expectEqual(client_mod.DEFAULT_TIMEOUT_MS, defaults.timeout_ms);
    try testing.expect(defaults.expected_model == null);

    const explicit = (try parseSettings(" http://h:1 ", "advisory", "800", "metask-jev-4b")).?;
    try testing.expectEqualStrings("http://h:1", explicit.origin);
    try testing.expectEqual(advisor_mod.Mode.advisory, explicit.mode);
    try testing.expectEqual(@as(u32, 800), explicit.timeout_ms);
    try testing.expectEqualStrings("metask-jev-4b", explicit.expected_model.?);
}

test "parseSettings: malformed mode or timeout is refused, not guessed" {
    try testing.expectError(error.InvalidMode, parseSettings("http://h", "enforced", null, null));
    try testing.expectError(error.InvalidTimeout, parseSettings("http://h", null, "fast", null));
    try testing.expectError(error.InvalidTimeout, parseSettings("http://h", null, "5", null));
}

test "Runtime pins the advisor to its own client and home copy" {
    const runtime = try Runtime.create(testing.allocator, testing.io, .{ .origin = "http://127.0.0.1:9", .mode = .advisory }, "/Users/alice");
    defer runtime.destroy(testing.allocator);
    try testing.expect(runtime.advisor.client == &runtime.client);
    try testing.expect(runtime.advisor.actuates());
    try testing.expectEqualStrings("/Users/alice", runtime.advisor.home);
}
