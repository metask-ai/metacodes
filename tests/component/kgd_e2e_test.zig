//! L2: the Metacodes-owned TinyKG service is reachable by the Metacodes client.
//!
//! Every test runs on Windows too, except where a test says why not (#222:
//! these were skipped there wholesale, and a Windows-only service stall hid in
//! that gap).
//!
//! The two halves are written against the same contract but never met until
//! here: `src/kg/kgd/` synthesizes the envelope and `src/kg/transport.zig`
//! validates it field by field. This drives a real `tinykgd`, over a real
//! socket, with the real client, so a contract drift on either side fails here
//! rather than in a degraded session.

const std = @import("std");
const cc = @import("cc");
const platform = @import("platform");
const pfs = platform.fs;
const tinykg_binary = @import("tinykg_binary.zig");

const Supervisor = cc.kgd_server.Supervisor;
const WebTransport = cc.kg_transport.WebTransport;

const Harness = struct {
    tmp: std.testing.TmpDir,
    allocator: std.mem.Allocator,
    cli: []u8,
    daemon: []u8,
    store: []u8,
    staging: []u8,
    supervisor: *Supervisor,
    thread: std.Thread,
    io_runtime: *std.Io.Threaded,
    /// The service was stopped by the test and not started again.
    stopped: bool = false,

    /// Null when the staged TinyKG bundle is absent: a developer checkout
    /// without `zig build tinykg:stage` skips instead of failing.
    fn start(allocator: std.mem.Allocator, api_key: []const u8) !?Harness {
        const cli = tinykg_binary.find(allocator) orelse return null;
        errdefer allocator.free(cli);
        const daemon = daemonPath(allocator) orelse {
            allocator.free(cli);
            return null;
        };
        errdefer allocator.free(daemon);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        const store = try std.fmt.allocPrint(allocator, "{s}/store.kg.v2", .{root});
        errdefer allocator.free(store);
        try initStore(allocator, cli, store);

        const io_runtime = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(io_runtime);
        io_runtime.* = std.Io.Threaded.init(allocator, .{});

        // Staging is required and validated against a trusted root, exactly as
        // the service supplies it; a harness that omitted it would exercise a
        // path production never takes.
        const staging = try std.fmt.allocPrint(allocator, "{s}/kg/import", .{root});
        errdefer allocator.free(staging);
        const supervisor = Supervisor.start(allocator, .{
            .store_path = store,
            .cli_path = cli,
            .daemon_path = daemon,
            .api_key = api_key,
            .port = 0, // the kernel picks; nothing else may claim a fixed port in a test
            .staging_dir = staging,
        }) catch |err| {
            io_runtime.deinit();
            allocator.destroy(io_runtime);
            return err;
        };
        const thread = try std.Thread.spawn(.{}, Supervisor.serveForever, .{supervisor});
        return .{
            .tmp = tmp,
            .allocator = allocator,
            .cli = cli,
            .daemon = daemon,
            .store = store,
            .staging = staging,
            .supervisor = supervisor,
            .thread = thread,
            .io_runtime = io_runtime,
        };
    }

    /// Take the service down, as a crash or reboot would.
    fn stopService(self: *Harness) void {
        self.supervisor.stop();
        self.thread.join();
        self.supervisor.deinit();
        self.stopped = true;
    }

    fn deinit(self: *Harness) void {
        if (!self.stopped) {
            self.supervisor.stop();
            self.thread.join();
            self.supervisor.deinit();
        }
        self.io_runtime.deinit();
        self.allocator.destroy(self.io_runtime);
        self.allocator.free(self.cli);
        self.allocator.free(self.daemon);
        self.allocator.free(self.store);
        self.allocator.free(self.staging);
        self.tmp.cleanup();
    }

    fn url(self: *const Harness, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.supervisor.port()});
    }

    fn connect(self: *const Harness, allocator: std.mem.Allocator, api_key: []const u8) !WebTransport {
        const endpoint = try self.url(allocator);
        defer allocator.free(endpoint);
        return WebTransport.init(allocator, .{
            .io = self.io_runtime.io(),
            .url = endpoint,
            .api_key = api_key,
            .expected_build_id = self.supervisor.identity.buildId(),
            .expected_schema_digest = "",
        });
    }
};

fn daemonPath(allocator: std.mem.Allocator) ?[]u8 {
    const raw = std.c.getenv("METACODES_TEST_TINYKGD_BIN") orelse return null;
    const value = std.mem.span(raw);
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

fn initStore(allocator: std.mem.Allocator, cli: []const u8, store: []const u8) !void {
    const cli_z = try allocator.dupeZ(u8, cli);
    defer allocator.free(cli_z);
    const store_z = try allocator.dupeZ(u8, store);
    defer allocator.free(store_z);
    const argv = [_]?[*:0]const u8{ cli_z.ptr, "init", store_z.ptr, null };
    const stdout = try cc.tools_common.spawnCaptureStdoutAbortableTimed(&argv, allocator, null, 60_000);
    allocator.free(stdout);
}

const TEST_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "Kgd: the Metacodes client reaches the Metacodes service and reads the store" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();

    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();

    // store-info is the client's own readiness preflight, envelope and all.
    const info = try transport.run("store-info", &.{}, false);
    defer info.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), info.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, info.stdout, "storage_format_version=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.stdout, "schema_version=3") != null);

    const readiness = try transport.ready();
    try std.testing.expect(readiness.ok and readiness.ready and !readiness.degraded);
    try std.testing.expect(readiness.supported);
}

test "Kgd: a write commits and the generation advances" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();

    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();

    const before = try transport.run("store-info", &.{}, false);
    defer before.deinit(a);

    const created = try transport.run("ensure-node", &.{ "observation", "kgd end-to-end probe" }, true);
    defer created.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), created.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, created.stdout, "node ") != null);
    // A durable mutation must be reported as committed, and the client rejects
    // a committed write that did not advance the daemon's generation.
    try std.testing.expectEqual(cc.kg_transport.Result.CommitState.committed, created.commit_state);
    try std.testing.expect(created.generation > before.generation);

    // The node is visible to a subsequent read through the same service.
    const found = try transport.run("search", &.{"probe"}, false);
    defer found.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), found.exit_code);
}

test "Kgd: an agent retrieval after a write is served from a rebuilt index" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();

    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();

    // Every committed write leaves the engine's full-text index stale. On a
    // stale index the JSON (agent retrieval) form of `search` plans over an
    // in-memory scan of the whole store, and that scan refuses any node whose
    // text has no tokens (TinyKG text/in_memory_index.zig `doc_len <= 0` ->
    // Unsupported). One such node — punctuation, an empty placeholder — and
    // KgRecall failed after every write until the service rebuilt the index
    // itself. Twice, so a write after a rebuild is covered as well.
    const tokenless = try transport.run("ensure-node", &.{ "observation", "---" }, true);
    defer tokenless.deinit(a);
    try std.testing.expectEqual(cc.kg_transport.Result.CommitState.committed, tokenless.commit_state);
    for ([_][]const u8{ "kilo retrieval probe", "lima retrieval probe" }, [_][]const u8{ "kilo", "lima" }) |text, term| {
        const created = try transport.run("ensure-node", &.{ "observation", text }, true);
        defer created.deinit(a);
        try std.testing.expectEqual(cc.kg_transport.Result.CommitState.committed, created.commit_state);

        const found = try transport.run("search", &.{ term, "--profile", "agent-memory", "--format", "json", "--include-text", "--limit", "3" }, false);
        defer found.deinit(a);
        try std.testing.expectEqual(@as(i32, 0), found.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, found.stdout, "tinykg-agent-retrieval-v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, found.stdout, text) != null);
    }
}

test "Kgd: declaring a custom type's scope does not fence the session's later writes" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();
    const endpoint = try harness.url(a);
    defer a.free(endpoint);

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try harness.tmp.dir.realPath(std.testing.io, &root_buffer)];
    var kg = try cc.kg_client.KgClient.init(a, .{
        .state_root = root,
        .domain = "scope-probe-project",
        .io = harness.io_runtime.io(),
        .daemon_url = endpoint,
        .daemon_api_key = TEST_KEY,
        .daemon_expected_build_id = harness.supervisor.identity.buildId(),
    });
    defer kg.deinit();
    kg.ensureReady();
    try std.testing.expect(kg.ready);

    // A custom type in project scope makes the client declare that type's
    // scope (`schema-scope --if-absent`). tinykgd answers it with no commit
    // receipt even when it creates the scope node; sent as a fenced write,
    // that read as "may have committed" and refused every later write of the
    // session (`auto-scope custom type ... failed: AmbiguousCommit`).
    _ = try kg.remember(.observation, "first note of a custom type", "scope_probe_type", false);
    try std.testing.expect(kg.transport.daemon.ambiguousRequestId() == null);
    _ = try kg.remember(.observation, "second note after the scope declaration", "scope_probe_type", false);
    _ = try kg.remember(.observation, "a base-type note", "observation", false);
}

/// Test stand-in for the host's `KgClient.Autostart`: brings the harness's
/// service back on the port the client is configured with.
const Restarter = struct {
    harness: *Harness,
    port: u16,
    calls: u32 = 0,
    /// `util_time.nowMs()` when the client first asked.
    first_call_ms: i64 = 0,

    fn hook(self: *Restarter) cc.kg_client.KgClient.Autostart {
        return .{ .ctx = self, .start = start };
    }

    fn start(ctx: *anyopaque) bool {
        const self: *Restarter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.first_call_ms == 0) self.first_call_ms = cc.util_time.nowMs();
        const h = self.harness;
        const supervisor = Supervisor.start(h.allocator, .{
            .store_path = h.store,
            .cli_path = h.cli,
            .daemon_path = h.daemon,
            .api_key = TEST_KEY,
            .port = self.port,
            .staging_dir = h.staging,
        }) catch return false;
        const thread = std.Thread.spawn(.{}, Supervisor.serveForever, .{supervisor}) catch {
            supervisor.deinit();
            return false;
        };
        h.supervisor = supervisor;
        h.thread = thread;
        h.stopped = false;
        return true;
    }
};

test "Kgd: a session that finds its service down has the host start it, then works" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();
    const endpoint = try harness.url(a);
    defer a.free(endpoint);
    var build_id_buf: [80]u8 = undefined;
    const build_id = try std.fmt.bufPrint(&build_id_buf, "{s}", .{harness.supervisor.identity.buildId()});
    const port = harness.supervisor.port();
    // Configured, but nothing listens: a reboot, or a first session.
    harness.stopService();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try harness.tmp.dir.realPath(std.testing.io, &root_buffer)];
    var restarter = Restarter{ .harness = &harness, .port = port };
    var kg = try cc.kg_client.KgClient.init(a, .{
        .state_root = root,
        .domain = "autostart-probe-project",
        .io = harness.io_runtime.io(),
        .daemon_url = endpoint,
        .daemon_api_key = TEST_KEY,
        .daemon_expected_build_id = build_id,
        .autostart = restarter.hook(),
    });
    defer kg.deinit();
    const began_ms = cc.util_time.nowMs();
    kg.ensureReady();
    try std.testing.expectEqual(@as(u32, 1), restarter.calls);
    // The host is asked before the client spends anything on a service that
    // is not there. On Windows a refused loopback connect takes ~2 s and a
    // read is tried twice, so asking only after store-info failed cost 4 s.
    try std.testing.expect(restarter.first_call_ms - began_ms < 1_000);
    try std.testing.expect(kg.ready);
    const task = try kg.createTask("autostart probe task", "task");
    _ = try kg.taskStatus(task);
    try std.testing.expectEqual(@as(u32, 1), restarter.calls); // up: no second start

    // Without a host hook the same situation degrades, as before.
    var bare = try cc.kg_client.KgClient.init(a, .{
        .state_root = root,
        .domain = "autostart-probe-project",
        .io = harness.io_runtime.io(),
        .daemon_url = "http://127.0.0.1:1",
        .daemon_api_key = TEST_KEY,
        .daemon_expected_build_id = build_id,
    });
    defer bare.deinit();
    bare.ensureReady();
    try std.testing.expect(!bare.ready);
    try std.testing.expectEqual(cc.kg_client.DegradedKind.daemon_unreachable, bare.degradedKind().?);
}

/// `metacodes kgd` run in-process: the same configuration load and supervisor
/// the CLI uses, stopped by the test so that no service outlives it.
const InProcessService = struct {
    allocator: std.mem.Allocator,
    config: ?cc.kgd_runtime_exports.Config = null,
    staging: ?[]u8 = null,
    supervisor: ?*Supervisor = null,
    thread: ?std.Thread = null,
    launches: u32 = 0,

    fn launcher(self: *InProcessService) cc.kg_autostart.Autostart.Launcher {
        return .{ .ctx = self, .launch = launch };
    }

    fn launch(ctx: *anyopaque, state_root: []const u8, config_path: ?[]const u8) anyerror!void {
        const self: *InProcessService = @ptrCast(@alignCast(ctx));
        self.launches += 1;
        var config = try cc.kgd_runtime_exports.loadConfig(self.allocator, state_root, .{ .config_path = config_path });
        errdefer config.deinit(self.allocator);
        const staging = try cc.kgd_runtime_exports.stagingDir(self.allocator, state_root);
        errdefer self.allocator.free(staging);
        const supervisor = try Supervisor.start(self.allocator, .{
            .store_path = config.store_path,
            .cli_path = config.cli_path,
            .daemon_path = config.daemon_path,
            .api_key = config.api_key,
            .port = config.port,
            .staging_dir = staging,
        });
        errdefer supervisor.deinit();
        self.thread = try std.Thread.spawn(.{}, Supervisor.serveForever, .{supervisor});
        self.supervisor = supervisor;
        self.config = config;
        self.staging = staging;
    }

    fn deinit(self: *InProcessService) void {
        if (self.supervisor) |supervisor| {
            supervisor.stop();
            self.thread.?.join();
            supervisor.deinit();
        }
        if (self.config) |*config| config.deinit(self.allocator);
        if (self.staging) |staging| self.allocator.free(staging);
    }
};

/// Sets an environment variable for the test and puts the old value back.
const EnvRestore = struct {
    name: [*:0]const u8,
    old: ?[]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvRestore {
        const old = if (std.c.getenv(name)) |raw| try allocator.dupe(u8, std.mem.span(raw)) else null;
        if (value) |v| platform.paths.setEnv(name, v) else platform.paths.unsetEnv(name);
        return .{ .name = name, .old = old };
    }

    fn restore(self: *EnvRestore, allocator: std.mem.Allocator) void {
        if (self.old) |old| {
            const z = allocator.dupeZ(u8, old) catch return;
            defer allocator.free(z);
            platform.paths.setEnv(self.name, z.ptr);
            allocator.free(old);
        } else platform.paths.unsetEnv(self.name);
    }
};

test "Kgd: a service of another state root on this install's port is never taken for ours" {
    const a = std.testing.allocator;
    // Another state root's service, on a port this install's configuration
    // also pins: what two state roots provisioned while both services were
    // down used to get, both on 8799.
    var other = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer other.deinit();
    const squatted = other.supervisor.port();

    const cli_z = try a.dupeZ(u8, other.cli);
    defer a.free(cli_z);
    const daemon_z = try a.dupeZ(u8, other.daemon);
    defer a.free(daemon_z);
    var env = [_]EnvRestore{
        try EnvRestore.set(a, "METACODES_KG_BIN", cli_z.ptr),
        try EnvRestore.set(a, "METACODES_KGD_BIN", daemon_z.ptr),
        try EnvRestore.set(a, "METACODES_KG_AUTOSTART", null),
        try EnvRestore.set(a, "METACODES_KG_CONFIG", null),
    };
    defer for (&env) |*entry| entry.restore(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var installed = try cc.kgd_install.run(a, root, .{ .port = squatted });
    defer installed.deinit(a);
    var before = try cc.kg_client.KgClient.loadDaemonConfig(a, installed.config_path);
    defer before.deinit();

    // Without a host, the session meets the other service and stops at its key.
    {
        var bare = try cc.kg_client.KgClient.init(a, .{ .state_root = root, .domain = "squat-probe", .io = other.io_runtime.io() });
        defer bare.deinit();
        bare.ensureReady();
        try std.testing.expect(!bare.ready);
        try std.testing.expectEqual(cc.kg_client.DegradedKind.auth_failed, bare.degradedKind().?);
    }

    // With it, this install moves to a free port with a new key (the old one
    // was presented to the other service) and the same store, and starts its
    // own service there.
    var service = InProcessService{ .allocator = a };
    defer service.deinit();
    const autostart = cc.kg_autostart.Autostart.create(a, root) orelse return error.SkipZigTest;
    defer autostart.destroy();
    autostart.launcher = service.launcher();
    var kg = try cc.kg_client.KgClient.init(a, .{
        .state_root = root,
        .domain = "squat-probe",
        .io = other.io_runtime.io(),
        .autostart = autostart.hook(),
    });
    defer kg.deinit();
    kg.ensureReady();
    try std.testing.expect(kg.ready);
    try std.testing.expectEqual(@as(u32, 1), service.launches);

    var after = try cc.kg_client.KgClient.loadDaemonConfig(a, installed.config_path);
    defer after.deinit();
    const moved = cc.kgd_install.portOfUrl(after.value.url) orelse return error.TestExpectedPort;
    try std.testing.expect(moved != squatted);
    try std.testing.expectEqual(moved, service.supervisor.?.port());
    try std.testing.expect(!std.mem.eql(u8, before.value.api_key, after.value.api_key));
    try std.testing.expectEqualStrings(before.value.store.?, after.value.store.?);
    try std.testing.expectEqualStrings(before.value.expected_build_id.?, after.value.expected_build_id.?);

    // This install's writes reach its own store; the other service still
    // serves its own key on its own port.
    const task = try kg.createTask("squat probe task", "task");
    _ = try kg.taskStatus(task);
    var other_transport = try other.connect(a, TEST_KEY);
    defer other_transport.deinit();
    try std.testing.expect((try other_transport.ready()).ready);
    // The key the other service saw does not open this install's service.
    const moved_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{moved});
    defer a.free(moved_url);
    var stale = try WebTransport.init(a, .{
        .io = other.io_runtime.io(),
        .url = moved_url,
        .api_key = before.value.api_key,
        .expected_build_id = after.value.expected_build_id.?,
        .expected_schema_digest = "",
    });
    defer stale.deinit();
    try std.testing.expectError(error.AuthenticationFailed, stale.run("store-info", &.{}, false));
}

test "Kgd: a client that connects and closes without a request does not stall the next" {
    // Autostart's readiness probe does exactly this. On Windows the service
    // missed that close and held its single thread for the whole 30 s request
    // deadline, so a session that started the service waited that long for its
    // first answer. `ready` gives up after 2 s.
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();
    const probe = try platform.net.connectLoopback(harness.supervisor.port());
    platform.net.closeSocket(probe);

    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();
    const readiness = try transport.ready();
    try std.testing.expect(readiness.ready);
}

test "Kgd: the service refuses a wrong key and an undeclared capability" {
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();

    var wrong = try harness.connect(a, "f" ** 64);
    defer wrong.deinit();
    try std.testing.expectError(error.AuthenticationFailed, wrong.run("store-info", &.{}, false));

    // `ontology-rule-snapshot` requires a capability this engine build does not
    // declare; the service must refuse rather than answer without it.
    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();
    if (harness.supervisor.identity.declares("tinykg-ontology-rule-snapshot-v1")) return;
    try std.testing.expectError(error.InvalidResponse, transport.run("ontology-rule-snapshot", &.{}, false));
}

test "Kgd: a planted symlink cannot capture a markdown import" {
    // The attack plants a POSIX symlink (`std.c.symlink`); Windows has no such
    // call, and creating a symbolic link there needs a privilege a test runner
    // cannot assume.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var harness = (try Harness.start(a, TEST_KEY)) orelse return error.SkipZigTest;
    defer harness.deinit();

    // The staging name is the client's sourceKey, which is predictable, and a
    // store can live in a shared directory. Someone leaves a link there first.
    const staging_dir = try a.dupe(u8, harness.staging);
    defer a.free(staging_dir);
    try cc.util_fs.mkdirParents(staging_dir);
    const victim = try std.fmt.allocPrintSentinel(a, "{s}/victim", .{staging_dir}, 0);
    defer a.free(victim);
    const planted = try std.fmt.allocPrintSentinel(a, "{s}/0123456789abcdef.md", .{staging_dir}, 0);
    defer a.free(planted);
    {
        const fd = pfs.open(victim.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        try std.testing.expect(fd >= 0);
        try std.testing.expectEqual(@as(isize, 9), pfs.write(fd, "untouched"));
        _ = pfs.close(fd);
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(victim.ptr, planted.ptr));

    var transport = try harness.connect(a, TEST_KEY);
    defer transport.deinit();
    // The import itself may fail on the engine side; what must not happen is
    // the victim file being written through the link.
    const result = transport.importMarkdown("# imported\n", 0x0123456789abcdef, null);
    if (result) |ok| {
        var owned = ok;
        owned.deinit(a);
    } else |_| {}

    const after = @import("cc").swarm_team.readFileAlloc(a, std.mem.span(victim.ptr)).?;
    defer a.free(after);
    try std.testing.expectEqualStrings("untouched", after);
}

test "Kgd: install writes a configuration this service can be started from" {
    const a = std.testing.allocator;
    const cli = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(cli);
    const daemon = daemonPath(a) orelse return error.SkipZigTest;
    defer a.free(daemon);
    // `kg install` resolves the executables the way a real installation does.
    // A test binary has no staged bundle beside it, so point the documented
    // overrides at the ones the build staged for the suite.
    const cli_z = try a.dupeZ(u8, cli);
    defer a.free(cli_z);
    const daemon_z = try a.dupeZ(u8, daemon);
    defer a.free(daemon_z);
    platform.paths.setEnv("METACODES_KG_BIN", cli_z.ptr);
    defer platform.paths.unsetEnv("METACODES_KG_BIN");
    platform.paths.setEnv("METACODES_KGD_BIN", daemon_z.ptr);
    defer platform.paths.unsetEnv("METACODES_KGD_BIN");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];

    // No --port: the configuration's own preferred port when it is free, not
    // one fixed default every state root on the machine would reach for.
    const config_path = try cc.kg_client.KgClient.resolveDaemonConfigPath(a, home);
    defer a.free(config_path);
    const preferred = cc.kgd_install.preferredPort(config_path);
    const preferred_free = if (platform.net.listenLoopback(preferred, 1)) |probe| blk: {
        platform.net.closeSocket(probe.sock);
        break :blk true;
    } else |_| false;
    var outcome = try cc.kgd_install.run(a, home, .{});
    defer outcome.deinit(a);
    if (preferred_free) try std.testing.expectEqual(preferred, cc.kgd_install.portOfUrl(outcome.url).?);
    try std.testing.expect(outcome.created_store);
    try std.testing.expect(!outcome.reused_api_key);
    try std.testing.expect(std.mem.startsWith(u8, &outcome.build_id, "sha256:"));

    // The store the install created is a real one, and the build id it wrote is
    // the one the service computes from the same executables.
    const store_z = try a.dupeZ(u8, outcome.store_path);
    defer a.free(store_z);
    try std.testing.expect(pfs.exists(store_z.ptr));

    // A second install keeps the key so sessions holding it keep working.
    var again = try cc.kgd_install.run(a, home, .{});
    defer again.deinit(a);
    try std.testing.expect(again.reused_api_key);
    try std.testing.expect(!again.created_store);
    try std.testing.expectEqualStrings(&outcome.build_id, &again.build_id);
    // and, with no --port, keeps the port it was installed with.
    try std.testing.expectEqualStrings(outcome.url, again.url);
}

test "Kgd: what install wrote is what the service starts from" {
    const a = std.testing.allocator;
    const cli = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(cli);
    const daemon = daemonPath(a) orelse return error.SkipZigTest;
    defer a.free(daemon);
    const cli_z = try a.dupeZ(u8, cli);
    defer a.free(cli_z);
    const daemon_z = try a.dupeZ(u8, daemon);
    defer a.free(daemon_z);
    platform.paths.setEnv("METACODES_KG_BIN", cli_z.ptr);
    defer platform.paths.unsetEnv("METACODES_KG_BIN");
    platform.paths.setEnv("METACODES_KGD_BIN", daemon_z.ptr);
    defer platform.paths.unsetEnv("METACODES_KGD_BIN");
    platform.paths.unsetEnv("METACODES_KG_CONFIG");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];

    // An isolated second world: its own configuration, store and port, with
    // nothing under the default path touched.
    const config_path = try std.fmt.allocPrint(a, "{s}/isolated.json", .{home});
    defer a.free(config_path);
    const store_path = try std.fmt.allocPrint(a, "{s}/isolated.kg.v2", .{home});
    defer a.free(store_path);
    var outcome = try cc.kgd_install.run(a, home, .{
        .config_path = config_path,
        .store_path = store_path,
        .port = 8912,
    });
    defer outcome.deinit(a);

    // The handoff: `metacodes kgd` must resolve exactly what install wrote,
    // including the store, which no other file records.
    var config = try cc.kgd_runtime_exports.loadConfig(a, home, .{ .config_path = config_path });
    defer config.deinit(a);
    try std.testing.expectEqualStrings(store_path, config.store_path);
    try std.testing.expectEqualStrings(config_path, config.config_path);
    try std.testing.expectEqual(@as(u16, 8912), config.port);
    try std.testing.expectEqual(@as(usize, 64), config.api_key.len);

    // METACODES_KG_CONFIG selects the same file for the service as for a session.
    const config_z = try a.dupeZ(u8, config_path);
    defer a.free(config_z);
    platform.paths.setEnv("METACODES_KG_CONFIG", config_z.ptr);
    defer platform.paths.unsetEnv("METACODES_KG_CONFIG");
    var from_env = try cc.kgd_runtime_exports.loadConfig(a, home, .{});
    defer from_env.deinit(a);
    try std.testing.expectEqualStrings(store_path, from_env.store_path);
    try std.testing.expectEqual(@as(u16, 8912), from_env.port);

    // A --store flag still wins for one run.
    var overridden = try cc.kgd_runtime_exports.loadConfig(a, home, .{ .store_override = "/tmp/other-store" });
    defer overridden.deinit(a);
    try std.testing.expectEqualStrings("/tmp/other-store", overridden.store_path);

    // The handoff is only real if a service actually starts from it: the store
    // install created, the key it generated, the executables it resolved.
    const handoff_staging = try std.fmt.allocPrint(a, "{s}/.metacodes/kg/import", .{home});
    defer a.free(handoff_staging);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const supervisor = try Supervisor.start(a, .{
        .store_path = config.store_path,
        .cli_path = config.cli_path,
        .daemon_path = config.daemon_path,
        .api_key = config.api_key,
        // The configured port is asserted above; binding zero here keeps the
        // test from fighting whatever else is listening on this machine.
        .port = 0,
        // Staging is anchored under this test's home, the way the service
        // anchors it under the user's.
        .staging_dir = handoff_staging,
    });
    const thread = try std.Thread.spawn(.{}, Supervisor.serveForever, .{supervisor});
    defer {
        supervisor.stop();
        thread.join();
        supervisor.deinit();
    }
    const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{supervisor.port()});
    defer a.free(endpoint);
    var transport = try WebTransport.init(a, .{
        .io = io_runtime.io(),
        .url = endpoint,
        .api_key = config.api_key,
        .expected_build_id = &outcome.build_id,
        .expected_schema_digest = "",
    });
    defer transport.deinit();
    // The build id install wrote is the one the service reports, which is what
    // a session pins; a mismatch here is what every degraded session looked like.
    const info = try transport.run("store-info", &.{}, false);
    defer info.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), info.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, info.stdout, "storage_format_version=3") != null);

    // A configuration the client would refuse must not start a service either.
    // Group/other mode bits are what make it unsafe, and the client checks them
    // on POSIX only (`KgClient.readDaemonConfig`): Windows files have none.
    if (@import("builtin").os.tag == .windows) return;
    const config_c = try a.dupeZ(u8, config_path);
    defer a.free(config_c);
    try std.testing.expectEqual(@as(c_int, 0), pfs.chmod(config_c.ptr, 0o644));
    try std.testing.expectError(error.ConfigUnsafe, cc.kgd_runtime_exports.loadConfig(a, home, .{ .config_path = config_path }));
}
