//! Host side of `KgClient.Autostart`: bring this install's TinyKG service up
//! when a session needs it, so nobody has to remember `metacodes kgd`.
//!
//! The client calls `start` when the local service is unconfigured or refuses
//! connections. This module then, under one cross-process lock per state
//! root:
//!
//! 1. provisions the service the way `metacodes kg install` does when the
//!    default `<state root>/kg/daemon.json` does not exist yet, choosing the
//!    default port when it is free and a free one otherwise (several installs
//!    on one machine must not collide);
//! 2. starts `<this executable> --state-dir <root> kgd` as a background
//!    service (own session, no terminal, output appended to
//!    `<state root>/kg/kgd.log`), unless something already listens there;
//! 3. waits until the configured port accepts connections.
//!
//! It stays out of the way of everything it does not own: an explicit
//! `METACODES_KG_URL`/`_API_KEY`/`_EXPECTED_BUILD_ID` service, a non-loopback
//! URL, a `METACODES_KG_CONFIG` file that does not exist (that one fails
//! closed in the client), and `METACODES_KG_AUTOSTART=0`.
//!
//! The started service stays up until the machine restarts or someone stops
//! it. It does not exit when idle: a write that met a service which had just
//! exited would have to be treated as possibly committed, and the transport
//! deliberately fences every later write after such an outcome.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const pfs = platform.fs;
const net = platform.net;
const log = @import("../util/log.zig");
const time = @import("../util/time.zig");
const KgClient = @import("../kg/client.zig").KgClient;
const kgd_install = @import("../kg/kgd/install.zig");

pub const ENV_DISABLE = "METACODES_KG_AUTOSTART";
/// How long a start may take before the session gives up and degrades: the
/// service discovers its identity and opens the store before it binds.
const READY_WAIT_MS: u64 = 20_000;
/// A lock older than this belongs to a start that died with it held.
const LOCK_STALE_S: i64 = 60;

pub const Autostart = struct {
    allocator: std.mem.Allocator,
    state_root: []u8,
    executable: []u8,
    mutex: platform.sync.Mutex = .{},

    /// Null when this process cannot name its own executable.
    pub fn create(allocator: std.mem.Allocator, state_root: []const u8) ?*Autostart {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe = platform.paths.selfExeRealPath(&exe_buf) orelse return null;
        const self = allocator.create(Autostart) catch return null;
        const root_copy = allocator.dupe(u8, state_root) catch {
            allocator.destroy(self);
            return null;
        };
        const exe_copy = allocator.dupe(u8, exe) catch {
            allocator.free(root_copy);
            allocator.destroy(self);
            return null;
        };
        self.* = .{ .allocator = allocator, .state_root = root_copy, .executable = exe_copy };
        return self;
    }

    pub fn destroy(self: *Autostart) void {
        self.allocator.free(self.state_root);
        self.allocator.free(self.executable);
        self.allocator.destroy(self);
    }

    pub fn hook(self: *Autostart) KgClient.Autostart {
        return .{ .ctx = self, .start = startThunk };
    }

    fn startThunk(ctx: *anyopaque) bool {
        const self: *Autostart = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.start() catch |err| {
            log.warn("kg", "TinyKG service autostart failed: {s}", .{@errorName(err)});
            return false;
        };
    }

    fn start(self: *Autostart) !bool {
        if (!enabled()) return false;
        if (envSet("METACODES_KG_URL") or envSet("METACODES_KG_API_KEY") or envSet("METACODES_KG_EXPECTED_BUILD_ID")) return false;
        const a = self.allocator;
        const custom_config = std.c.getenv("METACODES_KG_CONFIG") != null;
        const config_path = try KgClient.resolveDaemonConfigPath(a, self.state_root);
        defer a.free(config_path);
        const config_dir = std.fs.path.dirname(config_path) orelse return false;

        var lock = (try Lock.acquire(a, config_dir)) orelse {
            // Another session is starting it: wait for the same port.
            const port = configuredPort(a, config_path) orelse return false;
            return waitAccepting(port);
        };
        defer lock.release();

        if (!fileExists(a, config_path)) {
            // A configuration the user named must exist; only the default is
            // ours to create.
            if (custom_config) return false;
            var outcome = kgd_install.run(a, self.state_root, .{ .port = choosePort() }) catch |err| {
                log.warn("kg", "TinyKG service provisioning failed: {s}", .{@errorName(err)});
                return false;
            };
            defer outcome.deinit(a);
            log.info("kg", "TinyKG service provisioned: {s} at {s}", .{ outcome.config_path, outcome.url });
        }

        const port = configuredPort(a, config_path) orelse return false;
        if (accepting(port)) return true;

        const log_path = try std.fs.path.joinZ(a, &.{ config_dir, "kgd.log" });
        defer a.free(log_path);
        const log_fd = pfs.open(log_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (log_fd < 0) return error.LogUnavailable;
        defer pfs.close(log_fd);

        const exe_z = try a.dupeZ(u8, self.executable);
        defer a.free(exe_z);
        const root_z = try a.dupeZ(u8, self.state_root);
        defer a.free(root_z);
        const config_z = try a.dupeZ(u8, config_path);
        defer a.free(config_z);
        const argv_default = [_]?[*:0]const u8{ exe_z.ptr, "--state-dir", root_z.ptr, "kgd", null };
        const argv_custom = [_]?[*:0]const u8{ exe_z.ptr, "--state-dir", root_z.ptr, "kgd", "--config", config_z.ptr, null };
        const argv: []const ?[*:0]const u8 = if (custom_config) &argv_custom else &argv_default;
        try platform.process.spawnService(argv, log_fd);
        log.info("kg", "TinyKG service started on port {d} (log {s})", .{ port, log_path });
        return waitAccepting(port);
    }
};

/// Whether a CLI session would start the service for a client degraded this
/// way: `doctor` then shows a stopped service as normal rather than a fault.
pub fn wouldStart(kind: @import("../kg/client.zig").DegradedKind) bool {
    if (!enabled()) return false;
    if (envSet("METACODES_KG_URL") or envSet("METACODES_KG_API_KEY") or envSet("METACODES_KG_EXPECTED_BUILD_ID")) return false;
    return switch (kind) {
        .daemon_unreachable => true,
        .unconfigured => std.c.getenv("METACODES_KG_CONFIG") == null,
        else => false,
    };
}

fn enabled() bool {
    const raw = std.c.getenv(ENV_DISABLE) orelse return true;
    return !disables(std.mem.span(raw));
}

fn disables(value: []const u8) bool {
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "off");
}

fn envSet(name: [*:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    return std.mem.span(raw).len != 0;
}

fn fileExists(a: std.mem.Allocator, path: []const u8) bool {
    const z = a.dupeZ(u8, path) catch return false;
    defer a.free(z);
    return pfs.exists(z.ptr);
}

/// The loopback port the configuration names; null for anything else, which
/// is not a service this host may start.
fn configuredPort(a: std.mem.Allocator, config_path: []const u8) ?u16 {
    var parsed = KgClient.loadDaemonConfig(a, config_path) catch return null;
    defer parsed.deinit();
    const url = parsed.value.url;
    if (!std.mem.startsWith(u8, url, "http://127.0.0.1:")) return null;
    const port = kgd_install.portOfUrl(url) orelse return null;
    return if (port == 0) null else port;
}

/// The default port when nothing holds it, else one the kernel hands out.
fn choosePort() u16 {
    if (net.listenLoopback(kgd_install.DEFAULT_PORT, 1)) |listener| {
        net.closeSocket(listener.sock);
        return kgd_install.DEFAULT_PORT;
    } else |_| {}
    if (net.listenLoopback(0, 1)) |listener| {
        const port = listener.port;
        net.closeSocket(listener.sock);
        return port;
    } else |_| {}
    return kgd_install.DEFAULT_PORT;
}

/// Whether the service listens on `port`. Where the listener table answers
/// (Windows) nothing connects: a refused loopback connect costs ~2 s there,
/// and a connect-and-close probe hands the single-threaded service an empty
/// connection to retire.
fn accepting(port: u16) bool {
    switch (net.loopbackListenState(port)) {
        .listening => return true,
        .not_listening => return false,
        .unknown => {},
    }
    const sock = net.connectLoopback(port) catch return false;
    net.closeSocket(sock);
    return true;
}

fn waitAccepting(port: u16) bool {
    var waited: u64 = 0;
    while (waited < READY_WAIT_MS) : (waited += 100) {
        if (accepting(port)) return true;
        time.sleepMs(100);
    }
    return accepting(port);
}

/// One start per state root at a time, across processes: an exclusive file
/// holding its creation time. A lock older than `LOCK_STALE_S` is taken over.
const Lock = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,

    fn acquire(a: std.mem.Allocator, dir: []const u8) !?Lock {
        @import("../util/fs.zig").mkdirParents(dir) catch {};
        const path = try std.fs.path.joinZ(a, &.{ dir, "kgd.autostart.lock" });
        errdefer a.free(path);
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
            if (fd >= 0) {
                var stamp_buf: [32]u8 = undefined;
                const stamp = std.fmt.bufPrint(&stamp_buf, "{d}\n", .{time.nowUnix()}) catch "";
                _ = pfs.write(fd, stamp);
                pfs.close(fd);
                return .{ .allocator = a, .path = path };
            }
            if (!stale(a, path)) break;
            pfs.unlinkPath(path.ptr) catch {};
        }
        a.free(path);
        return null;
    }

    fn stale(a: std.mem.Allocator, path: [:0]const u8) bool {
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) return true;
        defer pfs.close(fd);
        var buf: [32]u8 = undefined;
        const n = pfs.read(fd, &buf);
        _ = a;
        if (n <= 0) return true;
        const created = std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..@intCast(n)], " \r\n"), 10) catch return true;
        return time.nowUnix() - created > LOCK_STALE_S;
    }

    fn release(self: *Lock) void {
        pfs.unlinkPath(self.path.ptr) catch {};
        self.allocator.free(self.path);
    }
};

const testing = std.testing;

test "kg autostart: METACODES_KG_AUTOSTART=0/false/off disables, anything else does not" {
    for ([_][]const u8{ "0", "false", "OFF", "Off" }) |value| try testing.expect(disables(value));
    for ([_][]const u8{ "1", "", "true", "on", "yes" }) |value| try testing.expect(!disables(value));
}

test "kg autostart: readiness costs no refused connect and hands the service no empty connection" {
    const listener = try net.listenLoopback(0, 4);
    var open = true;
    defer if (open) net.closeSocket(listener.sock);
    try testing.expect(accepting(listener.port));
    // Windows reads the listener table; POSIX still connects (and a refused
    // connect costs nothing there).
    if (builtin.os.tag == .windows) try testing.expect(!net.pollReadable(listener.sock, 0));

    net.closeSocket(listener.sock);
    open = false;
    const started_ms = time.nowMs();
    try testing.expect(!accepting(listener.port));
    // One refused loopback connect alone takes ~2 s on Windows.
    try testing.expect(time.nowMs() - started_ms < 1_000);
}

test "kg autostart: only a loopback daemon.json names a port this host may start" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    const write = struct {
        fn config(dir: std.Io.Dir, url: []const u8) !void {
            var body_buf: [512]u8 = undefined;
            const body = try std.fmt.bufPrint(&body_buf, "{{\"url\":\"{s}\",\"api_key\":\"{s}\",\"expected_build_id\":\"sha256:{s}\"}}\n", .{ url, "k" ** 64, "0" ** 64 });
            try dir.writeFile(testing.io, .{ .sub_path = "daemon.json", .data = body });
        }
    };
    const path = try std.fs.path.joinZ(a, &.{ root, "daemon.json" });
    defer a.free(path);
    try write.config(tmp.dir, "http://127.0.0.1:8811");
    _ = pfs.chmod(path.ptr, 0o600);
    try testing.expectEqual(@as(?u16, 8811), configuredPort(a, path));
    try write.config(tmp.dir, "http://10.0.0.5:8811");
    _ = pfs.chmod(path.ptr, 0o600);
    try testing.expectEqual(@as(?u16, null), configuredPort(a, path));
}

test "kg autostart: the start lock is exclusive and a stale one is taken over" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    var first = (try Lock.acquire(a, root)) orelse return error.TestExpectedLock;
    try testing.expect((try Lock.acquire(a, root)) == null);
    first.release();
    var again = (try Lock.acquire(a, root)) orelse return error.TestExpectedLock;
    again.release();

    // A lock left by a start that died long ago.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kgd.autostart.lock", .data = "1000\n" });
    var taken = (try Lock.acquire(a, root)) orelse return error.TestExpectedStaleTakeover;
    taken.release();
}
