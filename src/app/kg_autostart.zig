//! Host side of `KgClient.Autostart`: bring this install's TinyKG service up
//! when a session needs it, so nobody has to remember `metacodes kgd`.
//!
//! The client calls `start` when the local service is unconfigured or refuses
//! connections. This module then, under one cross-process lock per state
//! root:
//!
//! 1. provisions the service the way `metacodes kg install` does when the
//!    default `<state root>/kg/daemon.json` does not exist yet, on the port
//!    that configuration prefers (`kgd_install.preferredPort`) when it is free
//!    and a free one otherwise (several installs on one machine must not
//!    collide);
//! 2. asks whatever listens on the configured port for readiness with this
//!    configuration's key. This install's service answers; one that refuses
//!    the key belongs to another state root (or an older key) and is never
//!    taken for ours: the default configuration then moves to a free port
//!    with a new key (the old one was just presented to that service) and
//!    the same store, while a `METACODES_KG_CONFIG` file is left as the user
//!    wrote it and reported;
//! 3. starts `<this executable> --state-dir <root> kgd` as a background
//!    service (own session, no terminal, output appended to
//!    `<state root>/kg/kgd.log`) when nothing listens there;
//! 4. waits until the configured port accepts connections.
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
/// How long the ownership probe waits for a listener to answer.
const PROBE_TIMEOUT_MS: u32 = 2_000;

pub const Autostart = struct {
    allocator: std.mem.Allocator,
    state_root: []u8,
    executable: []u8,
    mutex: platform.sync.Mutex = .{},
    /// How the service is brought up; null spawns `<executable> kgd` as a
    /// background process. Component tests run the same service in-process so
    /// that nothing outlives them.
    launcher: ?Launcher = null,

    pub const Launcher = struct {
        ctx: *anyopaque,
        /// `config_path` is null for the state root's default configuration.
        launch: *const fn (ctx: *anyopaque, state_root: []const u8, config_path: ?[]const u8) anyerror!void,
    };

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
            // Another session is starting it, and may be moving it to another
            // port: wait for it to finish, then judge what the configuration
            // names by then.
            if (!waitUnlocked(a, config_dir)) return false;
            var target = configuredTarget(a, config_path) orelse return false;
            defer target.deinit(a);
            return switch (occupant(target.port, target.api_key)) {
                .ours, .unknown => true,
                .none, .foreign => false,
            };
        };
        defer lock.release();

        if (!fileExists(a, config_path)) {
            // A configuration the user named must exist; only the default is
            // ours to create.
            if (custom_config) return false;
            var outcome = kgd_install.run(a, self.state_root, .{ .port = kgd_install.choosePort(config_path, null) }) catch |err| {
                log.warn("kg", "TinyKG service provisioning failed: {s}", .{@errorName(err)});
                return false;
            };
            defer outcome.deinit(a);
            log.info("kg", "TinyKG service provisioned: {s} at {s}", .{ outcome.config_path, outcome.url });
        }

        var target = configuredTarget(a, config_path) orelse return false;
        defer target.deinit(a);
        var port = target.port;
        switch (occupant(port, target.api_key)) {
            // A listener that does not answer within the probe is most likely
            // this install's service busy with a request: never start a
            // second service over it.
            .ours, .unknown => return true,
            .none => {},
            .foreign => {
                if (custom_config) {
                    log.warn("kg", "TinyKG port {d} named by {s} is held by a service that refuses its key; stop that service or give the configuration a free port (`metacodes kg install --config <path> --port <port>`)", .{ port, config_path });
                    return false;
                }
                const moved = kgd_install.choosePort(config_path, port);
                // The probe, like every request a session made, presented the
                // key to that service: move with a new one.
                var outcome = kgd_install.run(a, self.state_root, .{ .port = moved, .rotate_api_key = true }) catch |err| {
                    log.warn("kg", "TinyKG port {d} is held by another service and moving off it failed: {s}", .{ port, @errorName(err) });
                    return false;
                };
                defer outcome.deinit(a);
                log.warn("kg", "TinyKG port {d} is held by a service that refuses this install's key (another state root's, or one started with an older key); moved this install to {s} with a new key ({s})", .{ port, outcome.url, outcome.config_path });
                port = kgd_install.portOfUrl(outcome.url) orelse return false;
                if (accepting(port)) return false; // taken between the choice and now
            },
        }

        const log_path = try std.fs.path.joinZ(a, &.{ config_dir, "kgd.log" });
        defer a.free(log_path);
        const log_fd = pfs.open(log_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (log_fd < 0) return error.LogUnavailable;
        defer pfs.close(log_fd);

        if (self.launcher) |launcher| {
            try launcher.launch(launcher.ctx, self.state_root, if (custom_config) config_path else null);
        } else {
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
        }
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

/// The loopback port a configuration names and the key its service accepts.
const Target = struct {
    port: u16,
    api_key: []u8,

    fn deinit(self: *Target, a: std.mem.Allocator) void {
        a.free(self.api_key);
    }
};

/// What the configuration names; null for a non-loopback URL, which is not a
/// service this host may start.
fn configuredTarget(a: std.mem.Allocator, config_path: []const u8) ?Target {
    var parsed = KgClient.loadDaemonConfig(a, config_path) catch return null;
    defer parsed.deinit();
    const url = parsed.value.url;
    if (!std.mem.startsWith(u8, url, "http://127.0.0.1:")) return null;
    const port = kgd_install.portOfUrl(url) orelse return null;
    if (port == 0) return null;
    return .{ .port = port, .api_key = a.dupe(u8, parsed.value.api_key) catch return null };
}

/// Who answers on a port, as judged with this configuration's key.
const Occupant = enum {
    /// Nothing listens.
    none,
    /// A service that accepts the key: this install's.
    ours,
    /// A service that refuses the key with 401, or a listener that does not
    /// speak HTTP: never this install's service.
    foreign,
    /// It accepted the connection but did not answer in time.
    unknown,
};

/// An authenticated readiness request, read only to its status line. The
/// service checks the key before it reads any body, so a foreign service does
/// no work for it, and this install's own answers 200, or 503 when degraded.
fn occupant(port: u16, api_key: []const u8) Occupant {
    if (!accepting(port)) return .none;
    for (api_key) |byte| if (byte < 0x21 or byte == 0x7f) return .unknown; // never a header injection
    const sock = net.connectLoopback(port) catch return .none;
    defer net.closeSocket(sock);
    net.setSendTimeoutMs(sock, PROBE_TIMEOUT_MS);
    net.setRecvTimeoutMs(sock, PROBE_TIMEOUT_MS);
    var request_buf: [384]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET /api/ready HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nx-api-key: {s}\r\nConnection: close\r\n\r\n",
        .{ port, api_key },
    ) catch return .unknown;
    var sent: usize = 0;
    while (sent < request.len) {
        const n = net.send(sock, request[sent..]);
        if (n <= 0) return .unknown;
        sent += @intCast(n);
    }
    var reply: [16]u8 = undefined;
    var got: usize = 0;
    while (got < reply.len) {
        const n = net.recv(sock, reply[got..]);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return classifyReply(reply[0..got]);
}

fn classifyReply(reply: []const u8) Occupant {
    if (reply.len == 0) return .unknown;
    // "HTTP/1.1 401 ..." — a status line needs 12 bytes.
    if (reply.len < 12 or !std.mem.startsWith(u8, reply, "HTTP/1.") or reply[8] != ' ') return .foreign;
    const status = std.fmt.parseInt(u16, reply[9..12], 10) catch return .foreign;
    return if (status == 401) .foreign else .ours;
}

/// Until another session's start lock is gone, or the time a start may take.
fn waitUnlocked(a: std.mem.Allocator, dir: []const u8) bool {
    const path = std.fs.path.join(a, &.{ dir, "kgd.autostart.lock" }) catch return false;
    defer a.free(path);
    var waited: u64 = 0;
    while (waited < READY_WAIT_MS + 10_000) : (waited += 100) {
        if (!fileExists(a, path)) return true;
        time.sleepMs(100);
    }
    return false;
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
    var target = configuredTarget(a, path) orelse return error.TestExpectedTarget;
    defer target.deinit(a);
    try testing.expectEqual(@as(u16, 8811), target.port);
    try testing.expectEqualStrings("k" ** 64, target.api_key);
    try write.config(tmp.dir, "http://10.0.0.5:8811");
    _ = pfs.chmod(path.ptr, 0o600);
    try testing.expect(configuredTarget(a, path) == null);
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

test "kg autostart: a reply is judged by its status line, and only 401 or non-HTTP is foreign" {
    try testing.expectEqual(Occupant.ours, classifyReply("HTTP/1.1 200 OK\r\n"));
    try testing.expectEqual(Occupant.ours, classifyReply("HTTP/1.1 503 Service Unavailable\r\n"));
    try testing.expectEqual(Occupant.foreign, classifyReply("HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expectEqual(Occupant.foreign, classifyReply("SSH-2.0-OpenSSH_9.6\r\n"));
    try testing.expectEqual(Occupant.foreign, classifyReply("HTTP/1.1 4"));
    try testing.expectEqual(Occupant.unknown, classifyReply(""));
}

/// One canned reply to the first connection that sends a request; empty
/// connections (the readiness check's connect-and-close) are skipped.
const FakeService = struct {
    listener: net.Listener,
    reply: []const u8,
    seen_key: [80]u8 = undefined,
    seen_key_len: usize = 0,

    fn serve(self: *FakeService) void {
        var connections: u8 = 0;
        while (connections < 4) : (connections += 1) {
            const conn = net.acceptConn(self.listener.sock) orelse return;
            defer net.closeSocket(conn);
            net.setRecvTimeoutMs(conn, 3_000);
            var buf: [1024]u8 = undefined;
            var got: usize = 0;
            while (got < buf.len) {
                const n = net.recv(conn, buf[got..]);
                if (n <= 0) break;
                got += @intCast(n);
                if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") != null) break;
            }
            if (got == 0) continue;
            if (std.mem.indexOf(u8, buf[0..got], "x-api-key: ")) |at| {
                const rest = buf[at + "x-api-key: ".len .. got];
                const key = rest[0 .. std.mem.indexOf(u8, rest, "\r\n") orelse rest.len];
                self.seen_key_len = @min(key.len, self.seen_key.len);
                @memcpy(self.seen_key[0..self.seen_key_len], key[0..self.seen_key_len]);
            }
            if (self.reply.len > 0) {
                _ = net.send(conn, self.reply);
            } else {
                time.sleepMs(PROBE_TIMEOUT_MS + 500); // never answers within the probe
            }
            return;
        }
    }
};

fn probeFake(reply: []const u8) !struct { occupant: Occupant, key: [80]u8, key_len: usize } {
    const listener = try net.listenLoopback(0, 4);
    var fake = FakeService{ .listener = listener, .reply = reply };
    const thread = try std.Thread.spawn(.{}, FakeService.serve, .{&fake});
    const verdict = occupant(listener.port, "k" ** 64);
    thread.join();
    net.closeSocket(listener.sock);
    return .{ .occupant = verdict, .key = fake.seen_key, .key_len = fake.seen_key_len };
}

test "kg autostart: the ownership probe asks with this configuration's key" {
    const refused = try probeFake("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(Occupant.foreign, refused.occupant);
    try testing.expectEqualStrings("k" ** 64, refused.key[0..refused.key_len]);
    const accepted = try probeFake("HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n{\"ok\":true,\"ready\":true,\"degraded\":false}");
    try testing.expectEqual(Occupant.ours, accepted.occupant);
    const other_program = try probeFake("SSH-2.0-OpenSSH_9.6\r\n");
    try testing.expectEqual(Occupant.foreign, other_program.occupant);
    // A listener that does not answer is not declared foreign: it may be this
    // install's own service, busy.
    const silent = try probeFake("");
    try testing.expectEqual(Occupant.unknown, silent.occupant);

    const closed = try net.listenLoopback(0, 1);
    const port = closed.port;
    net.closeSocket(closed.sock);
    try testing.expectEqual(Occupant.none, occupant(port, "k" ** 64));
    // A key that could smuggle a header is never sent.
    const listener = try net.listenLoopback(0, 1);
    defer net.closeSocket(listener.sock);
    try testing.expectEqual(Occupant.unknown, occupant(listener.port, "k\r\nx-evil: 1"));
}
