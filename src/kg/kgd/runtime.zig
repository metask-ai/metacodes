//! Wiring for `metacodes kgd`: read the configuration the sessions read,
//! resolve the staged executables, serve until interrupted, then take the
//! daemon down with us.
//!
//! Everything the service and its clients must agree on lives in one file that
//! both sides read through the same strict loader: the port, the key, and the
//! Store. A flag can override the Store for one run, but nothing is remembered
//! only in the operator's head.

const std = @import("std");
const platform_signal = @import("platform").signal;
const log = @import("../../util/log.zig");
const server_mod = @import("server.zig");
const install_mod = @import("install.zig");
const KgClient = @import("../client.zig").KgClient;

pub const Error = error{
    NoHome,
    ConfigUnreadable,
    ConfigUnsafe,
    ConfigInvalid,
    BinariesMissing,
    OutOfMemory,
};

pub const Config = struct {
    config_path: []u8,
    store_path: []u8,
    cli_path: []u8,
    daemon_path: []u8,
    api_key: []u8,
    port: u16,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.store_path);
        allocator.free(self.cli_path);
        allocator.free(self.daemon_path);
        // The key is a credential: do not leave it in freed memory.
        @memset(self.api_key, 0);
        allocator.free(self.api_key);
    }
};

pub const LoadOptions = struct {
    /// Explicit `--config`. Otherwise `METACODES_KG_CONFIG` or the default,
    /// resolved by the same function the client uses.
    config_path: ?[]const u8 = null,
    store_override: ?[]const u8 = null,
};

pub fn loadConfig(allocator: std.mem.Allocator, home: []const u8, options: LoadOptions) Error!Config {
    if (home.len == 0 and options.config_path == null) return Error.NoHome;
    const config_path = if (options.config_path) |given|
        allocator.dupe(u8, given) catch return Error.OutOfMemory
    else
        KgClient.resolveDaemonConfigPath(allocator, home) catch return Error.OutOfMemory;
    errdefer allocator.free(config_path);

    // Read exactly as a session does: regular file, no symlink, owner-only.
    // A service that served from a configuration its clients refuse would be
    // handing the API key to anyone who could write that file.
    var parsed = KgClient.loadDaemonConfig(allocator, config_path) catch |err| return switch (err) {
        error.ConfigUnsafe => Error.ConfigUnsafe,
        error.FileNotFound => Error.ConfigUnreadable,
        else => Error.ConfigInvalid,
    };
    defer parsed.deinit();
    if (parsed.value.api_key.len == 0) return Error.ConfigInvalid;
    const port = install_mod.portOfUrl(parsed.value.url) orelse return Error.ConfigInvalid;
    if (port == 0) return Error.ConfigInvalid;

    var cli = (KgClient.resolveTinykgBinary(allocator, .{ .home = home, .domain = "" }) catch null) orelse
        return Error.BinariesMissing;
    errdefer cli.deinit(allocator);
    var daemon = (KgClient.resolveTinykgdBinary(allocator, .{ .home = home, .domain = "" }) catch null) orelse
        return Error.BinariesMissing;
    errdefer daemon.deinit(allocator);

    const store_path = try resolveStore(allocator, config_path, parsed.value.store, options.store_override);
    errdefer allocator.free(store_path);
    const owned_key = allocator.dupe(u8, parsed.value.api_key) catch return Error.OutOfMemory;

    return .{
        .config_path = config_path,
        .store_path = store_path,
        .cli_path = cli.path,
        .daemon_path = daemon.path,
        .api_key = owned_key,
        .port = port,
    };
}

/// A `--store` flag for this run, else what the configuration records, else the
/// default beside the configuration. The last case is what an older file
/// written before the field existed falls back to.
fn resolveStore(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    recorded: ?[]const u8,
    override: ?[]const u8,
) Error![]u8 {
    const dir = std.fs.path.dirname(config_path) orelse ".";
    if (override) |given| return beside(allocator, dir, given);
    if (recorded) |value| {
        // A hand-edited relative path resolves against the configuration that
        // records it, never against whatever directory the service happens to
        // be started from.
        if (value.len > 0) return beside(allocator, dir, value);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, install_mod.STORE_NAME }) catch Error.OutOfMemory;
}

fn beside(allocator: std.mem.Allocator, dir: []const u8, path: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path) catch Error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, path }) catch Error.OutOfMemory;
}

/// The interrupt handler needs a way to reach the running supervisor, and a
/// signal handler cannot take arguments. One process runs one supervisor.
var active: ?*server_mod.Supervisor = null;

fn onInterrupt() void {
    if (active) |supervisor| supervisor.stop();
}

pub fn serve(allocator: std.mem.Allocator, config: Config) u8 {
    // Markdown is staged beside the configuration, not beside the store: the
    // store can be anywhere the operator pointed, including a shared directory,
    // while the configuration directory is the one `kg install` created 0700.
    const staging = std.fmt.allocPrint(allocator, "{s}/import", .{
        std.fs.path.dirname(config.config_path) orelse ".",
    }) catch {
        std.debug.print("error: out of memory preparing the TinyKG service\n", .{});
        return 1;
    };
    defer allocator.free(staging);
    const supervisor = server_mod.Supervisor.start(allocator, .{
        .store_path = config.store_path,
        .cli_path = config.cli_path,
        .daemon_path = config.daemon_path,
        .api_key = config.api_key,
        .port = config.port,
        .staging_dir = staging,
    }) catch |err| {
        std.debug.print("error: cannot start the TinyKG service ({s}){s}\n", .{ @errorName(err), hint(err) });
        return 1;
    };
    active = supervisor;
    defer {
        active = null;
        supervisor.deinit();
    }
    platform_signal.installInterrupt(onInterrupt);
    std.debug.print("TinyKG service on http://127.0.0.1:{d}\n  store:  {s}\n  config: {s}\nCtrl+C to stop.\n", .{
        supervisor.port(),
        config.store_path,
        config.config_path,
    });
    supervisor.serveForever();
    // A wedged daemon takes the service down rather than queueing every later
    // request behind a read that will never return; say so, because the
    // operator has to start it again.
    if (supervisor.daemonWedged()) {
        std.debug.print("error: tinykgd stopped answering; the service exited. Start it again with `metacodes kgd`.\n", .{});
        return 1;
    }
    log.info("kgd", "stopped", .{});
    return 0;
}

fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.ListenFailed => "; the configured port is already in use, stop the other service or re-run `metacodes kg install --port <free port>`",
        error.DaemonUnavailable => "; another process already owns this store, or the staged tinykgd cannot run here",
        error.StoreContractUnreadable => "; the store is missing or its format does not match this TinyKG build",
        error.IdentityUnavailable => "; the staged TinyKG executables could not be read or identified",
        else => "",
    };
}

const testing = std.testing;

test "KgdRuntime: a relative store resolves against the configuration, not the working directory" {
    const a = testing.allocator;
    // `kgd` is started from anywhere; a recorded relative path must still name
    // the store the configuration meant, or the service would quietly init a
    // different one next to wherever the operator happened to be standing.
    const recorded = try resolveStore(a, "/home/x/.metacodes/kg/daemon.json", "scratch.kg.v2", null);
    defer a.free(recorded);
    try testing.expectEqualStrings("/home/x/.metacodes/kg/scratch.kg.v2", recorded);

    const flag = try resolveStore(a, "/home/x/.metacodes/kg/daemon.json", null, "scratch.kg.v2");
    defer a.free(flag);
    try testing.expectEqualStrings("/home/x/.metacodes/kg/scratch.kg.v2", flag);
}

test "KgdRuntime: the store comes from the flag, then the file, then the default" {
    const a = testing.allocator;
    const from_flag = try resolveStore(a, "/home/x/.metacodes/kg/daemon.json", "/recorded", "/flag");
    defer a.free(from_flag);
    try testing.expectEqualStrings("/flag", from_flag);

    const from_file = try resolveStore(a, "/home/x/.metacodes/kg/daemon.json", "/recorded", null);
    defer a.free(from_file);
    try testing.expectEqualStrings("/recorded", from_file);

    // A configuration written before the field existed still resolves, beside
    // itself rather than beside some other installation's.
    const legacy = try resolveStore(a, "/home/x/.metacodes/kg/daemon.json", null, null);
    defer a.free(legacy);
    try testing.expectEqualStrings("/home/x/.metacodes/kg/" ++ install_mod.STORE_NAME, legacy);

    const empty = try resolveStore(a, "/elsewhere/daemon.json", "", null);
    defer a.free(empty);
    try testing.expectEqualStrings("/elsewhere/" ++ install_mod.STORE_NAME, empty);
}
