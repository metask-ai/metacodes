//! L2: a degraded TinyKG is diagnosable and recoverable (2026-09-19 finding:
//! every session had been silently degraded since 2026-08-13).
//!
//! Covers the kind classification behind `KgClient.degradedKind`, the probe
//! schedule, configuration re-read on retry, the read-only doctor probe, the
//! daemon readiness probe, the tool envelope and the doctor report.

const std = @import("std");
const cc = @import("cc");
const platform = @import("platform");
const pfs = platform.fs;
const paths = platform.paths;
const net = platform.net;
const tinykg_binary = @import("tinykg_binary.zig");

const KgClient = cc.kg_client.KgClient;
const DegradedKind = cc.kg_client.DegradedKind;

const BUILD_ID = "sha256:" ++ ("a" ** 64);
const VALID_CONFIG = "{\"url\":\"http://127.0.0.1:1\",\"api_key\":\"k\",\"expected_build_id\":\"" ++ BUILD_ID ++ "\"}";

/// None of these may leak from the developer's shell into a classification test.
fn clearKgEnv() void {
    paths.unsetEnv("METACODES_KG_CONFIG");
    paths.unsetEnv("METACODES_KG_URL");
    paths.unsetEnv("METACODES_KG_API_KEY");
    paths.unsetEnv("METACODES_KG_EXPECTED_BUILD_ID");
    paths.unsetEnv("METACODES_KG_EXPECTED_SCHEMA_DIGEST");
    paths.unsetEnv("METACODES_KG_TRANSPORT");
    paths.unsetEnv("METACODES_KG_BIN");
    paths.unsetEnv("METACODES_KG_STORE");
}

const Home = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Home {
        var h = Home{ .tmp = std.testing.tmpDir(.{}) };
        errdefer h.tmp.cleanup();
        try h.tmp.dir.createDirPath(std.testing.io, ".metacodes/kg");
        h.root_len = try h.tmp.dir.realPath(std.testing.io, &h.root_buf);
        return h;
    }
    fn deinit(self: *Home) void {
        self.tmp.cleanup();
    }
    fn root(self: *const Home) []const u8 {
        return self.root_buf[0..self.root_len];
    }
    /// Writes `<root>/.metacodes/kg/daemon.json` with the given mode and returns its path.
    fn writeConfig(self: *const Home, allocator: std.mem.Allocator, content: []const u8, mode: u16) ![]u8 {
        const path = try std.fmt.allocPrint(allocator, "{s}/.metacodes/kg/daemon.json", .{self.root()});
        errdefer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (fd < 0) return error.ConfigWriteFailed;
        defer _ = pfs.close(fd);
        if (pfs.write(fd, content) != @as(isize, @intCast(content.len))) return error.ConfigWriteFailed;
        if (std.c.chmod(path_z.ptr, mode) != 0) return error.ConfigChmodFailed;
        return path;
    }
};

/// One-shot loopback HTTP responder: answers the first request with a plain 200
/// JSON body and closes. The SSE mock server streams chunked events on 200, which
/// is not what `/api/ready` returns.
const ReadyResponder = struct {
    listener: net.Listener,
    body: []const u8,
    status_line: []const u8 = "HTTP/1.1 200 OK",

    fn serve(self: *ReadyResponder) void {
        const conn = net.acceptConn(self.listener.sock) orelse return;
        defer net.closeSocket(conn);
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            if (!net.pollReadable(conn, 2_000)) break;
            const n = net.recv(conn, buf[total..]);
            if (n <= 0) break;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
        }
        // Answer only a request that actually arrived: a probe that never sends
        // its GET must fail here, not be rescued by an unsolicited response.
        if (!std.mem.startsWith(u8, buf[0..total], "GET /api/ready ")) return;
        var hdr: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hdr, "{s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ self.status_line, self.body.len }) catch return;
        sendAll(conn, head);
        sendAll(conn, self.body);
    }
    fn sendAll(conn: net.Socket, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = net.send(conn, bytes[off..]);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }
};

fn initClient(allocator: std.mem.Allocator, home: []const u8) !KgClient {
    return KgClient.init(allocator, .{ .home = home, .domain = "kgstate", .io = std.testing.io });
}

test "KgState: no daemon.json is unconfigured with a hint" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expect(!client.ready);
    try std.testing.expectEqual(DegradedKind.unconfigured, client.degradedKind().?);
    try std.testing.expect(client.degradedHint().len > 0);
    try std.testing.expectEqualStrings("unconfigured", client.transportName());
}

test "KgState: a world-readable daemon.json is config_unsafe, not unconfigured" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    const path = try home.writeConfig(a, VALID_CONFIG, 0o644);
    defer a.free(path);
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expectEqual(DegradedKind.config_unsafe, client.degradedKind().?);
    try std.testing.expect(std.mem.indexOf(u8, client.degradedHint(), "600") != null);
}

test "KgState: malformed daemon.json is config_invalid" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    const path = try home.writeConfig(a, "{\"url\":", 0o600);
    defer a.free(path);
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expectEqual(DegradedKind.config_invalid, client.degradedKind().?);
}

test "KgState: METACODES_KG_CONFIG naming a missing file is config_invalid and init still succeeds" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    const missing_path = try std.fmt.allocPrint(a, "{s}/does-not-exist.json", .{home.root()});
    defer a.free(missing_path);
    const missing = try a.dupeZ(u8, missing_path);
    defer a.free(missing);
    paths.setEnv("METACODES_KG_CONFIG", missing.ptr);
    defer paths.unsetEnv("METACODES_KG_CONFIG");
    // Before the fix `init` failed here and the App dropped the whole diagnosis.
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expectEqual(DegradedKind.config_invalid, client.degradedKind().?);
}

test "KgState: a valid config pointing at a closed loopback port is daemon_unreachable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    const path = try home.writeConfig(a, VALID_CONFIG, 0o600);
    defer a.free(path);
    var client = try initClient(a, home.root());
    defer client.deinit();
    try std.testing.expectEqualStrings("daemon", client.transportName());
    client.ensureReady();
    try std.testing.expect(!client.ready);
    try std.testing.expectEqual(DegradedKind.daemon_unreachable, client.degradedKind().?);
}

test "KgState: probe schedule doubles from 5 s to a 5 min cap" {
    try std.testing.expect(KgClient.probeDue(1_000, 0, 0)); // never probed: due
    try std.testing.expect(!KgClient.probeDue(1_000, 1_000, 5_000)); // inside the window
    try std.testing.expect(KgClient.probeDue(6_000, 1_000, 5_000)); // window elapsed
    try std.testing.expectEqual(@as(i64, 5_000), KgClient.nextBackoff(0));
    try std.testing.expectEqual(@as(i64, 10_000), KgClient.nextBackoff(5_000));
    try std.testing.expectEqual(@as(i64, 300_000), KgClient.nextBackoff(200_000));
    try std.testing.expectEqual(@as(i64, 300_000), KgClient.nextBackoff(300_000));
}

test "KgState: retryReadyIfDue re-reads a config written after startup" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expectEqual(DegradedKind.unconfigured, client.degradedKind().?);
    // The user repairs the configuration mid-session.
    const path = try home.writeConfig(a, VALID_CONFIG, 0o600);
    defer a.free(path);
    try std.testing.expect(!client.retryReadyIfDue());
    // Re-read happened: the client is now bound to the (unreachable) daemon, not "unconfigured".
    try std.testing.expectEqual(DegradedKind.daemon_unreachable, client.degradedKind().?);
    try std.testing.expectEqualStrings("daemon", client.transportName());
    // And the schedule armed itself: an immediate second call does no work.
    try std.testing.expect(client.probe_backoff_ms >= 5_000);
    try std.testing.expect(!client.retryReadyIfDue());
}

test "KgState: ensureReadyReadOnly never creates a CLI store" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    // The real staged tinykg: a fake binary could not create a store, so it could
    // not tell a read-only probe from `ensureReady` (mutation check ME).
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    const store = try std.fmt.allocPrint(a, "{s}/no-such-store", .{home.root()});
    defer a.free(store);
    var client = try KgClient.init(a, .{
        .home = home.root(),
        .domain = "kgstate",
        .exclusive_cli = true,
        .env_bin = bin,
        .env_store = store,
    });
    defer client.deinit();
    client.ensureReadyReadOnly();
    try std.testing.expect(!client.ready);
    try std.testing.expectEqual(DegradedKind.cli_store_failed, client.degradedKind().?);
    const store_z = try a.dupeZ(u8, store);
    defer a.free(store_z);
    try std.testing.expect(!pfs.exists(store_z.ptr));
}

test "KgState: transport ready() reports a degraded daemon and a refused connection" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // std.testing.io runs Select tasks without real concurrency, so the 2 s deadline
    // task would always win the race; the app uses a threaded Io, tests too.
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();
    var responder = ReadyResponder{ .listener = try net.listenLoopback(0, 1), .body = "{\"ok\":false,\"ready\":false,\"degraded\":true}" };
    defer net.closeSocket(responder.listener.sock);
    const thread = try std.Thread.spawn(.{}, ReadyResponder.serve, .{&responder});
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{responder.listener.port});
    defer a.free(url);
    var transport = try cc.kg_transport.WebTransport.init(a, .{
        .io = io,
        .url = url,
        .api_key = "k",
        .expected_build_id = BUILD_ID,
        .expected_schema_digest = "",
    });
    defer transport.deinit();
    const readiness = try transport.ready();
    thread.join();
    try std.testing.expect(readiness.degraded);
    try std.testing.expect(!readiness.ready);

    var refused = try cc.kg_transport.WebTransport.init(a, .{
        .io = io,
        .url = "http://127.0.0.1:1",
        .api_key = "k",
        .expected_build_id = BUILD_ID,
        .expected_schema_digest = "",
    });
    defer refused.deinit();
    const err = refused.ready();
    try std.testing.expect(if (err) |_| false else |e| e == error.RequestFailed or e == error.DaemonUnavailable or e == error.RequestTimedOut);
}

test "KgState: an actor without /api/ready is reported as supported=false, not degraded" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();
    var responder = ReadyResponder{ .listener = try net.listenLoopback(0, 1), .body = "", .status_line = "HTTP/1.1 501 Not Implemented" };
    defer net.closeSocket(responder.listener.sock);
    const thread = try std.Thread.spawn(.{}, ReadyResponder.serve, .{&responder});
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{responder.listener.port});
    defer a.free(url);
    var transport = try cc.kg_transport.WebTransport.init(a, .{
        .io = io,
        .url = url,
        .api_key = "k",
        .expected_build_id = BUILD_ID,
        .expected_schema_digest = "",
    });
    defer transport.deinit();
    const readiness = try transport.ready();
    thread.join();
    try std.testing.expect(!readiness.supported);
    try std.testing.expect(!readiness.degraded);
    try std.testing.expect(readiness.ready);
}

test "KgState: a degraded KG tool result carries kind and hint" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    var ctx = cc.tools.ToolContext{ .allocator = a, .kg = &client };
    var outcome = try cc.tools.dispatch(&ctx, "KgRemember", "{\"text\":\"x\"}");
    defer outcome.deinit(a);
    const bytes = switch (outcome) {
        .ok => |body| switch (body) {
            .@"inline" => |result| result.bytes,
            else => return error.UnexpectedBody,
        },
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kg_unavailable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"unconfigured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"hint\":\"") != null);
}

test "KgState: doctor reports the KG diagnosis without letting it decide health" {
    const a = std.testing.allocator;
    const unresolved = cc.doctor.Check{ .name = "tinykg", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null };
    var without = cc.doctor.Report{ .checks = .{
        .{ .name = "ripgrep", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
        unresolved,
        .{ .name = "formal_kernel", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
        .{ .name = "project_kernel", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
    }, .kg = null };
    defer without.deinit(a);
    var with = cc.doctor.Report{ .checks = without.checks, .kg = .{
        .state = try a.dupe(u8, "daemon_unreachable"),
        .transport = try a.dupe(u8, "daemon"),
        .config = try a.dupe(u8, "/home/x/.metacodes/kg/daemon.json"),
        .hint = try a.dupe(u8, "start tinykgd"),
    } };
    defer if (with.kg) |kg| kg.deinit(a);
    // Health is an install property; a missing daemon must not flip it.
    try std.testing.expectEqual(without.healthy(), with.healthy());

    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    try cc.doctor.writeJson(&json.writer, &with);
    const json_bytes = try json.toOwnedSlice();
    defer a.free(json_bytes);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"kg\":{\"state\":\"daemon_unreachable\",\"transport\":\"daemon\"") != null);

    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try cc.doctor.writeText(&text.writer, &with);
    const text_bytes = try text.toOwnedSlice();
    defer a.free(text_bytes);
    try std.testing.expect(std.mem.indexOf(u8, text_bytes, "tinykg_daemon daemon_unreachable transport=daemon config=/home/x/.metacodes/kg/daemon.json hint=start tinykgd") != null);
}

test "KgState: only the root client re-reads configuration; clones keep the fence they were born with" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    var root = try initClient(a, home.root());
    defer root.deinit();
    root.ensureReady();
    var early_clone = try root.cloneForThread(a, home.root());
    defer early_clone.deinit();
    early_clone.ensureReady();
    try std.testing.expectEqual(DegradedKind.unconfigured, early_clone.degradedKind().?);
    // The user repairs the configuration while the clone is alive.
    const path = try home.writeConfig(a, VALID_CONFIG, 0o600);
    defer a.free(path);
    // A clone must not rebuild a transport of its own: that transport would own
    // a private write fence, splitting the ambiguous-commit poison in-process.
    try std.testing.expect(!early_clone.retryReadyNow());
    try std.testing.expectEqual(DegradedKind.unconfigured, early_clone.degradedKind().?);
    try std.testing.expectEqualStrings("unconfigured", early_clone.transportName());
    // The root re-reads, binds to the daemon, and later clones inherit that binding.
    try std.testing.expect(!root.retryReadyNow());
    try std.testing.expectEqualStrings("daemon", root.transportName());
    try std.testing.expectEqual(DegradedKind.daemon_unreachable, root.degradedKind().?);
    var late_clone = try root.cloneForThread(a, home.root());
    defer late_clone.deinit();
    try std.testing.expectEqualStrings("daemon", late_clone.transportName());
}

test "KgState: retryReadyNow probes inside the backoff window, retryReadyIfDue does not" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();
    var client = try initClient(a, home.root());
    defer client.deinit();
    client.ensureReady();
    try std.testing.expect(!client.retryReadyIfDue()); // arms the 5 s window
    try std.testing.expect(client.probe_backoff_ms >= 5_000);
    const path = try home.writeConfig(a, VALID_CONFIG, 0o600);
    defer a.free(path);
    try std.testing.expect(!client.retryReadyIfDue()); // inside the window: no work
    try std.testing.expectEqual(DegradedKind.unconfigured, client.degradedKind().?);
    try std.testing.expect(!client.retryReadyNow()); // explicit request: probes now
    try std.testing.expectEqual(DegradedKind.daemon_unreachable, client.degradedKind().?);
    try std.testing.expectEqualStrings("daemon", client.transportName());
}

test "KgState: doctor names the configuration source and shares the repair hint" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    clearKgEnv();
    const a = std.testing.allocator;
    var home = try Home.init();
    defer home.deinit();

    // No client at all (App could not build one): still a hint, never "-".
    const none = (try cc.kgDiagnosis(a, null, home.root())).?;
    defer none.deinit(a);
    try std.testing.expectEqualStrings("unconfigured", none.state);
    try std.testing.expectEqualStrings(KgClient.hintFor(.unconfigured), none.hint);

    // Default path: reported even though the file does not exist yet.
    var plain = try initClient(a, home.root());
    defer plain.deinit();
    const plain_diag = (try cc.kgDiagnosis(a, &plain, home.root())).?;
    defer plain_diag.deinit(a);
    const default_path = try std.fmt.allocPrint(a, "{s}/.metacodes/kg/daemon.json", .{home.root()});
    defer a.free(default_path);
    try std.testing.expectEqualStrings("unconfigured", plain_diag.state);
    try std.testing.expectEqualStrings(default_path, plain_diag.config);
    try std.testing.expectEqualStrings(KgClient.hintFor(.unconfigured), plain_diag.hint);

    // METACODES_KG_CONFIG names the file the binding was read from.
    const missing_path = try std.fmt.allocPrint(a, "{s}/explicit.json", .{home.root()});
    defer a.free(missing_path);
    const missing = try a.dupeZ(u8, missing_path);
    defer a.free(missing);
    paths.setEnv("METACODES_KG_CONFIG", missing.ptr);
    defer paths.unsetEnv("METACODES_KG_CONFIG");
    var explicit = try initClient(a, home.root());
    defer explicit.deinit();
    const explicit_diag = (try cc.kgDiagnosis(a, &explicit, home.root())).?;
    defer explicit_diag.deinit(a);
    try std.testing.expectEqualStrings("config_invalid", explicit_diag.state);
    try std.testing.expectEqualStrings(missing_path, explicit_diag.config);
    try std.testing.expectEqualStrings(KgClient.hintFor(.config_invalid), explicit_diag.hint);

    // The METACODES_KG_* triple wins over the file and is reported as "env".
    paths.setEnv("METACODES_KG_URL", "http://127.0.0.1:1");
    defer paths.unsetEnv("METACODES_KG_URL");
    paths.setEnv("METACODES_KG_API_KEY", "k");
    defer paths.unsetEnv("METACODES_KG_API_KEY");
    paths.setEnv("METACODES_KG_EXPECTED_BUILD_ID", BUILD_ID);
    defer paths.unsetEnv("METACODES_KG_EXPECTED_BUILD_ID");
    var env_client = try initClient(a, home.root());
    defer env_client.deinit();
    const env_diag = (try cc.kgDiagnosis(a, &env_client, home.root())).?;
    defer env_diag.deinit(a);
    try std.testing.expectEqualStrings("daemon_unreachable", env_diag.state);
    try std.testing.expectEqualStrings("daemon", env_diag.transport);
    try std.testing.expectEqualStrings("env", env_diag.config);
}
