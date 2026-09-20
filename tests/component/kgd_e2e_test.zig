//! L2: the Metacodes-owned TinyKG service is reachable by the Metacodes client.
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
    trusted_root: []const u8,
    supervisor: *Supervisor,
    thread: std.Thread,
    io_runtime: *std.Io.Threaded,

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
            .staging = .{ .dir = staging, .trusted_root = try allocator.dupe(u8, root) },
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
            .trusted_root = supervisor.options.staging.trusted_root,
            .supervisor = supervisor,
            .thread = thread,
            .io_runtime = io_runtime,
        };
    }

    fn deinit(self: *Harness) void {
        self.supervisor.stop();
        self.thread.join();
        self.supervisor.deinit();
        self.io_runtime.deinit();
        self.allocator.destroy(self.io_runtime);
        self.allocator.free(self.cli);
        self.allocator.free(self.daemon);
        self.allocator.free(self.store);
        self.allocator.free(self.staging);
        self.allocator.free(@constCast(self.trusted_root));
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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

test "Kgd: the service refuses a wrong key and an undeclared capability" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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

    var outcome = try cc.kgd_install.run(a, home, .{ .port = 8799 });
    defer outcome.deinit(a);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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
        .staging = .{ .dir = handoff_staging, .trusted_root = home },
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
    const config_c = try a.dupeZ(u8, config_path);
    defer a.free(config_c);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(config_c.ptr, 0o644));
    try std.testing.expectError(error.ConfigUnsafe, cc.kgd_runtime_exports.loadConfig(a, home, .{ .config_path = config_path }));
}
