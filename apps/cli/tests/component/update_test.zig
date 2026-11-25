//! L2: `metacodes update` end to end against a loopback release mirror
//! (doc/UPDATE_DESIGN.md §11).
//!
//! A fixture release is a real unit directory — manifest v2, file digests —
//! whose `bin/metacodes` is `zig-out/bin/update_unit_probe`: its `install`
//! runs the real installer (apps/cli/src/app/install.zig, no doctor), every other call
//! is only recorded. The mirror serves `latest` as a 302 to `…/tag/<v>`, the
//! release's SHA256SUMS and its archive (`.tar.gz`, `.zip` on Windows), and
//! records every request. So each test sees what update sent over the wire,
//! what it ran, and what the install looks like afterwards.
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const harness = @import("harness");
const platform = @import("platform");
const net = platform.net;
const update = cc.app_update;
const install = cc.app_install;
const release_source = cc.app_release_source;
const archive_fixture = cc.app_archive_fixture;

const testing = std.testing;
const is_windows = builtin.os.tag == .windows;
const EXE = if (is_windows) "metacodes.exe" else "metacodes";
const TINYKGD = if (is_windows) "tinykgd.exe" else "tinykgd";
const PROBE = if (is_windows) "zig-out/bin/update_unit_probe.exe" else "zig-out/bin/update_unit_probe";
const EXT = if (is_windows) ".zip" else ".tar.gz";
const LOG_ENV = "METACODES_UPDATE_PROBE_LOG";
const EXIT_ENV = "METACODES_UPDATE_PROBE_EXIT";
const HELP_ENV = "METACODES_UPDATE_PROBE_HELP";

// ── the mirror ───────────────────────────────────────────────────────────────

const Route = struct {
    path: []const u8,
    status: []const u8 = "200 OK",
    location: ?[]const u8 = null,
    body: []const u8 = "",
};

const Mirror = struct {
    gpa: std.mem.Allocator,
    listener: net.Listener,
    routes: std.ArrayList(Route) = .empty,
    requests: std.ArrayList([]u8) = .empty,
    mutex: platform.sync.Mutex = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(gpa: std.mem.Allocator) !*Mirror {
        const self = try gpa.create(Mirror);
        self.* = .{ .gpa = gpa, .listener = try net.listenLoopback(0, 16) };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *Mirror) void {
        self.stopping.store(true, .release);
        if (harness.clientRoundtrip(self.gpa, self.listener.port, "GET /__stop HTTP/1.1\r\n\r\n", null)) |bytes| self.gpa.free(bytes) else |_| {}
        if (self.thread) |thread| thread.join();
        net.closeSocket(self.listener.sock);
        for (self.requests.items) |request| self.gpa.free(request);
        self.requests.deinit(self.gpa);
        self.routes.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Routes are matched on the path after `/r`.
    fn route(self: *Mirror, r: Route) !void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        for (self.routes.items) |*existing| if (std.mem.eql(u8, existing.path, r.path)) {
            existing.* = r;
            return;
        };
        try self.routes.append(self.gpa, r);
    }

    fn base(self: *Mirror, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/r", .{self.listener.port});
    }

    fn requestCount(self: *Mirror) usize {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return self.requests.items.len;
    }

    /// Whether a request for a path ending in `suffix` was made.
    fn requested(self: *Mirror, suffix: []const u8) bool {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        for (self.requests.items) |path| if (std.mem.endsWith(u8, path, suffix)) return true;
        return false;
    }

    fn clearRequests(self: *Mirror) void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        for (self.requests.items) |request| self.gpa.free(request);
        self.requests.clearRetainingCapacity();
    }

    fn serve(self: *Mirror) void {
        while (true) {
            const conn = net.acceptConn(self.listener.sock) orelse {
                if (self.stopping.load(.acquire)) return;
                continue;
            };
            defer net.closeSocket(conn);
            if (self.stopping.load(.acquire)) return;
            net.setRecvTimeoutMs(conn, 5000);
            var buf: [8192]u8 = undefined;
            var got: usize = 0;
            while (got < buf.len and std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null) {
                const n = net.recv(conn, buf[got..]);
                if (n <= 0) break;
                got += @intCast(n);
            }
            const line_end = std.mem.indexOf(u8, buf[0..got], "\r\n") orelse continue;
            var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
            const method = parts.next() orelse continue;
            const target = parts.next() orelse continue;
            const path = if (std.mem.startsWith(u8, target, "/r")) target[2..] else target;
            var response: std.ArrayList(u8) = .empty;
            defer response.deinit(self.gpa);
            {
                _ = self.mutex.lock();
                defer _ = self.mutex.unlock();
                const copy = self.gpa.dupe(u8, path) catch continue;
                self.requests.append(self.gpa, copy) catch self.gpa.free(copy);
                const found: Route = for (self.routes.items) |r| {
                    if (std.mem.eql(u8, r.path, path)) break r;
                } else .{ .path = path, .status = "404 Not Found", .body = "not here" };
                response.print(self.gpa, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ found.status, found.body.len }) catch continue;
                if (found.location) |location| response.print(self.gpa, "Location: {s}\r\n", .{location}) catch continue;
                response.appendSlice(self.gpa, "\r\n") catch continue;
                if (!std.mem.eql(u8, method, "HEAD")) response.appendSlice(self.gpa, found.body) catch continue;
            }
            var sent: usize = 0;
            while (sent < response.items.len) {
                const n = net.send(conn, response.items[sent..]);
                if (n <= 0) break;
                sent += @intCast(n);
            }
        }
    }
};

// ── fixture releases ─────────────────────────────────────────────────────────

const Content = union(enum) { text: []const u8, probe };

const Release = struct {
    version: []const u8,
    tinykgd: Content = .{ .text = "tinykgd-1" },
    /// What the manifest says, when it is not `version` (a mislabelled release).
    manifest_version: ?[]const u8 = null,
    target: []const u8 = update.hostTargetId(),
};

const Env = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    probe: []const u8,
    log_path: []const u8,
    prefix: []const u8,
    mirror: *Mirror,
    units: usize = 0,
    log: std.Io.Writer.Allocating,

    fn init(self: *Env) !void {
        self.arena_state = .init(testing.allocator);
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, buf[0..try self.tmp.dir.realPath(testing.io, &buf)]);
        self.probe = std.Io.Dir.cwd().readFileAlloc(testing.io, PROBE, a, .limited(64 << 20)) catch |err| {
            std.debug.print("update_test: {s} is missing (zig build test:harness): {s}\n", .{ PROBE, @errorName(err) });
            return err;
        };
        self.log_path = try std.fs.path.join(a, &.{ self.root, "probe.log" });
        self.prefix = try std.fs.path.join(a, &.{ self.root, "opt", "mc" });
        self.mirror = try Mirror.start(testing.allocator);
        self.log = .init(a);
        platform.paths.setEnv(LOG_ENV, try a.dupeZ(u8, self.log_path));
        platform.paths.unsetEnv(EXIT_ENV);
        platform.paths.unsetEnv(HELP_ENV);
    }

    fn deinit(self: *Env) void {
        platform.paths.unsetEnv(LOG_ENV);
        platform.paths.unsetEnv(EXIT_ENV);
        platform.paths.unsetEnv(HELP_ENV);
        self.mirror.stop();
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Env) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    const Staged = struct { dir: []const u8, members: []const archive_fixture.Member, root_name: []const u8 };

    /// A release unit directory, and the archive members that hold it.
    fn stage(self: *Env, release: Release) !Staged {
        const a = self.arena();
        self.units += 1;
        const root_name = try std.fmt.allocPrint(a, "metacodes-{s}-{s}", .{ release.version, release.target });
        const dir = try std.fs.path.join(a, &.{ self.root, "units", try std.fmt.allocPrint(a, "{d}", .{self.units}), root_name });
        const Item = struct { rel: []const u8, data: []const u8, exec: bool };
        const tinykgd: Item = switch (release.tinykgd) {
            .text => |t| .{ .rel = "vendor/tinykg/" ++ TINYKGD, .data = t, .exec = false },
            .probe => .{ .rel = "vendor/tinykg/" ++ TINYKGD, .data = self.probe, .exec = true },
        };
        const items = [_]Item{
            .{ .rel = "bin/" ++ EXE, .data = self.probe, .exec = true },
            .{ .rel = "vendor/tinykg/" ++ (if (is_windows) "tinykg.exe" else "tinykg"), .data = "tinykg-1", .exec = false },
            tinykgd,
            .{ .rel = "share/doc/README.md", .data = try std.fmt.allocPrint(a, "metacodes {s}\n", .{release.version}), .exec = false },
        };
        var files: std.ArrayList(install.FileEntry) = .empty;
        var members: std.ArrayList(archive_fixture.Member) = .empty;
        for (items) |item| {
            const path = try std.fs.path.join(a, &.{ dir, item.rel });
            try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(path).?);
            try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = item.data, .flags = .{ .permissions = if (item.exec) .executable_file else .default_file } });
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(item.data, &digest, .{});
            try files.append(a, .{ .path = item.rel, .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) });
            try members.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_name, item.rel }), .kind = if (item.exec) .executable else .file, .data = item.data });
        }
        const manifest = try std.json.Stringify.valueAlloc(a, .{
            .schema_version = 2,
            .name = "metacodes-cli",
            .release = .{ .version = release.manifest_version orelse release.version, .channel = "stable" },
            .source = .{ .commit = "0123456789ab", .dirty = false },
            .target = .{ .id = release.target },
            .files = files.items,
        }, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "manifest.json" }), .data = manifest });
        try members.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/manifest.json", .{root_name}), .data = manifest });
        return .{ .dir = dir, .members = members.items, .root_name = root_name };
    }

    /// Install `release` at the prefix directly, recording `source`.
    fn installDirect(self: *Env, release: Release, source: ?release_source.UpdateSource) !void {
        const staged = try self.stage(release);
        _ = try install.run(self.arena(), testing.io, staged.dir, .{
            .prefix = self.prefix,
            .upgrade = true,
            .allow_downgrade = true,
            .update_source = if (source) |s| .{ .set = s } else .keep,
            .self_check = false,
        }, &self.log.writer);
    }

    /// Publish `release` on the mirror: SUMS and its archive. `bad_sum`
    /// publishes a sum the archive does not match.
    fn publish(self: *Env, release: Release, bad_sum: bool) !void {
        const a = self.arena();
        const staged = try self.stage(release);
        const bytes = if (is_windows) try archive_fixture.zip(a, staged.members) else try archive_fixture.tarGz(a, staged.members);
        const asset = try std.fmt.allocPrint(a, "metacodes-{s}-{s}{s}", .{ release.version, update.hostTargetId(), EXT });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var hex = std.fmt.bytesToHex(digest, .lower);
        if (bad_sum) hex[0] = if (hex[0] == '0') '1' else '0';
        const sums = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ &hex, asset });
        try self.mirror.route(.{ .path = try std.fmt.allocPrint(a, "/download/{s}/{s}", .{ release.version, asset }), .body = bytes });
        try self.mirror.route(.{ .path = try std.fmt.allocPrint(a, "/download/{s}/metacodes-{s}-SHA256SUMS", .{ release.version, release.version }), .body = sums });
    }

    /// `latest` redirects to the tag's page, which answers 200 as GitHub's
    /// does (update, like install.sh, follows to it with HEAD requests).
    fn setLatest(self: *Env, version: []const u8) !void {
        const a = self.arena();
        const tag = try std.fmt.allocPrint(a, "/tag/{s}", .{version});
        try self.mirror.route(.{
            .path = "/latest",
            .status = "302 Found",
            .location = try std.fmt.allocPrint(a, "{s}{s}", .{ try self.mirror.base(a), tag }),
        });
        try self.mirror.route(.{ .path = tag, .body = "release page" });
    }

    fn base(self: *Env) ![]const u8 {
        return self.mirror.base(self.arena());
    }

    fn mirrorSource(self: *Env) !release_source.UpdateSource {
        return release_source.parseBase(self.arena(), try self.base());
    }

    /// `update.Options` without the prefix, which is always the env's.
    const RunOptions = struct {
        check: bool = false,
        version: ?[]const u8 = null,
        release_base: ?[]const u8 = null,
        pull: bool = false,
        allow_downgrade: bool = false,
        no_sdk: bool = false,
        ignore_running: bool = false,
    };

    fn run(self: *Env, options: RunOptions) !update.Outcome {
        self.log.clearRetainingCapacity();
        return update.run(self.arena(), testing.io, .{
            .prefix = self.prefix,
            .check = options.check,
            .version = options.version,
            .release_base = options.release_base,
            .pull = options.pull,
            .allow_downgrade = options.allow_downgrade,
            .no_sdk = options.no_sdk,
            .ignore_running = options.ignore_running,
        }, &self.log.writer);
    }

    fn probeLog(self: *Env) []const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, self.log_path, self.arena(), .limited(1 << 20)) catch "";
    }

    fn clearProbeLog(self: *Env) void {
        std.Io.Dir.cwd().deleteFile(testing.io, self.log_path) catch {};
    }

    fn noStaging(self: *Env) !void {
        var dir = std.Io.Dir.cwd().openDir(testing.io, try std.fs.path.join(self.arena(), &.{ self.prefix, ".update" }), .{ .iterate = true }) catch return;
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| try testing.expect(!std.mem.startsWith(u8, entry.name, "run-"));
    }
};

fn expectLine(log: []const u8, expected: []const []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (expected, 0..) |part, i| {
        if (i > 0) try buf.append(testing.allocator, '\t');
        try buf.appendSlice(testing.allocator, part);
    }
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), buf.items)) return;
    std.debug.print("expected probe line:\n  {s}\nprobe log:\n{s}\n", .{ buf.items, log });
    return error.TestExpectedEqual;
}

// ── release installs ─────────────────────────────────────────────────────────

test "update: a release install moves to the latest release from its recorded mirror, which stays recorded" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    const mirror = try env.mirrorSource();
    try env.installDirect(.{ .version = "1.0.0" }, mirror);
    try env.publish(.{ .version = "1.1.0", .tinykgd = .{ .text = "tinykgd-1" } }, false);
    try env.setLatest("1.1.0");

    // No --release-base: the record names the mirror.
    const outcome = try env.run(.{});
    try testing.expectEqual(update.Action.upgrade, outcome.action);
    try testing.expectEqualStrings("1.0.0", outcome.from);
    try testing.expectEqualStrings("1.1.0", outcome.to);
    try testing.expectEqualStrings(try env.base(), outcome.origin);

    // Exactly the installer contract, run from the staged unit.
    try expectLine(env.probeLog(), &.{ "install", "--help" });
    try expectLine(env.probeLog(), &.{ "install", "--prefix", env.prefix, "--upgrade", "--release-base", try env.base() });

    const measured = try install.measure(env.arena(), testing.io, env.prefix);
    try testing.expect(measured.intact());
    try testing.expectEqualStrings("1.1.0", measured.manifest.?.release.version);
    try testing.expect(measured.record.update_source.eql(mirror));
    try env.noStaging();
    // Same TinyKG digests and no service provisioned: no repin.
    try testing.expect(std.mem.indexOf(u8, env.probeLog(), "kg\tinstall") == null);
}

test "update: an install that is up to date, or newer than the latest, downloads nothing" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.1.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0" }, false);
    try env.setLatest("1.1.0");

    const same = try env.run(.{});
    try testing.expectEqual(update.Action.up_to_date, same.action);
    try testing.expect(env.mirror.requested("/latest"));
    try testing.expect(!env.mirror.requested("SHA256SUMS"));
    try testing.expect(!env.mirror.requested(EXT));

    // GitHub's Latest label behind the install.
    env.mirror.clearRequests();
    try env.installDirect(.{ .version = "1.2.0" }, null);
    const newer = try env.run(.{});
    try testing.expectEqual(update.Action.newer_installed, newer.action);
    try testing.expect(env.mirror.requested("/latest"));
    try testing.expect(!env.mirror.requested("SHA256SUMS"));
    try testing.expect(!env.mirror.requested(EXT));
    try testing.expectEqualStrings("", env.probeLog());
}

test "update: a damaged install is repaired from the same release" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.1.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0" }, false);
    try env.setLatest("1.1.0");
    const daemon = try std.fs.path.join(env.arena(), &.{ env.prefix, "vendor", "tinykg", TINYKGD });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = daemon, .data = "damaged" });

    const outcome = try env.run(.{});
    try testing.expectEqual(update.Action.repair, outcome.action);
    try testing.expect((try install.measure(env.arena(), testing.io, env.prefix)).intact());
}

test "update: a download that does not match the sums, or a mislabelled unit, never runs and changes nothing" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0" }, true);
    try env.setLatest("1.1.0");
    try testing.expectError(error.DigestMismatch, env.run(.{}));
    try testing.expectEqualStrings("", env.probeLog());
    try testing.expectEqualStrings("1.0.0", (try install.measure(env.arena(), testing.io, env.prefix)).record.version);
    try env.noStaging();

    // The archive says 1.1.1 inside while it is published as 1.1.0.
    try env.publish(.{ .version = "1.1.0", .manifest_version = "1.1.1" }, false);
    try testing.expectError(error.StagedUnitMismatch, env.run(.{}));
    try testing.expectEqualStrings("", env.probeLog());
    try testing.expect((try install.measure(env.arena(), testing.io, env.prefix)).intact());
    try env.noStaging();
}

test "update: --check reports an update and fetches no archive; --version older needs --allow-downgrade" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.1.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.2.0" }, false);
    try env.publish(.{ .version = "1.0.0" }, false);
    try env.setLatest("1.2.0");

    const checked = try env.run(.{ .check = true });
    try testing.expectEqual(update.Action.upgrade, checked.action);
    try testing.expect(checked.checked_only and checked.changes());
    try testing.expectEqual(@as(usize, 0), checked.sessions.len);
    try testing.expectEqual(@as(usize, 0), checked.services.len);
    try testing.expect(std.mem.indexOf(u8, env.log.written(), "run from") == null);
    try testing.expect(std.mem.indexOf(u8, try jsonOf(&env, checked), "\"checked_only\":true,\"stopped_services\":[],\"running_sessions\":[],\"sessions\":[],\"services\":[]") != null);
    try testing.expect(!env.mirror.requested("SHA256SUMS"));
    try testing.expectEqualStrings("", env.probeLog());

    try testing.expectError(error.DowngradeRefused, env.run(.{ .version = "1.0.0" }));
    try testing.expectEqualStrings("", env.probeLog());
    const down = try env.run(.{ .version = "1.0.0", .allow_downgrade = true });
    try testing.expectEqual(update.Action.downgrade, down.action);
    try expectLine(env.probeLog(), &.{ "install", "--prefix", env.prefix, "--upgrade", "--release-base", try env.base(), "--allow-downgrade" });
    try testing.expectEqualStrings("1.0.0", (try install.measure(env.arena(), testing.io, env.prefix)).record.version);
}

test "update: --release-base names a new mirror and the record keeps it; an old unit is not given it" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, null); // the default base
    try env.publish(.{ .version = "1.1.0" }, false);
    try env.setLatest("1.1.0");

    _ = try env.run(.{ .release_base = try env.base() });
    try testing.expect((try install.measure(env.arena(), testing.io, env.prefix)).record.update_source.eql(try env.mirrorSource()));

    // A unit whose installer predates --release-base (its help does not name it).
    env.clearProbeLog();
    try env.publish(.{ .version = "1.2.0" }, false);
    try env.setLatest("1.2.0");
    platform.paths.setEnv(HELP_ENV, "usage: metacodes install --prefix <dir> [--upgrade] [--allow-downgrade]\n");
    defer platform.paths.unsetEnv(HELP_ENV);
    _ = try env.run(.{});
    try expectLine(env.probeLog(), &.{ "install", "--prefix", env.prefix, "--upgrade" });
    try testing.expect(std.mem.indexOf(u8, env.log.written(), "cannot record a mirror") != null);
}

test "update: a failed installer is reported, and the next update converges" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0" }, false);
    try env.setLatest("1.1.0");

    platform.paths.setEnv(EXIT_ENV, "1");
    try testing.expectError(error.InstallFailed, env.run(.{}));
    platform.paths.unsetEnv(EXIT_ENV);
    // The executable is in place (on Windows: renamed back) and unchanged.
    const exe = try std.fs.path.join(env.arena(), &.{ env.prefix, "bin", EXE });
    try std.Io.Dir.cwd().access(testing.io, exe, .{});
    try testing.expectEqualStrings("1.0.0", (try install.measure(env.arena(), testing.io, env.prefix)).record.version);

    // A half-written install: the record already names 1.1.0.
    const record = try std.fs.path.join(env.arena(), &.{ env.prefix, "etc", "metacodes", "install.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, record, env.arena(), .limited(64 << 10));
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = record, .data = try std.mem.replaceOwned(u8, env.arena(), text, "\"1.0.0\"", "\"1.1.0\"") });
    const outcome = try env.run(.{});
    try testing.expectEqual(update.Action.repair, outcome.action);
    try testing.expect((try install.measure(env.arena(), testing.io, env.prefix)).intact());
    if (is_windows) {
        // The executable renamed aside by the successful run is removed by the next.
        _ = try env.run(.{});
        var bin = try std.Io.Dir.cwd().openDir(testing.io, try std.fs.path.join(env.arena(), &.{ env.prefix, "bin" }), .{ .iterate = true });
        defer bin.close(testing.io);
        var it = bin.iterate();
        var old: usize = 0;
        while (try it.next(testing.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".old")) {
            old += 1;
        };
        try testing.expect(old <= 1); // the last run's own
    }
}

test "update: changed TinyKG binaries repin a provisioned TinyKG service" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0", .tinykgd = .{ .text = "tinykgd-2" } }, false);
    try env.setLatest("1.1.0");

    // Not provisioned: nothing to repin.
    _ = try env.run(.{});
    try testing.expect(std.mem.indexOf(u8, env.probeLog(), "kg\tinstall") == null);

    try env.installDirect(.{ .version = "1.0.0" }, null);
    const kg_dir = try std.fs.path.join(env.arena(), &.{ env.prefix, "state", "kg" });
    try std.Io.Dir.cwd().createDirPath(testing.io, kg_dir);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(env.arena(), &.{ kg_dir, "daemon.json" }), .data = "{}" });
    env.clearProbeLog();
    _ = try env.run(.{});
    try expectLine(env.probeLog(), &.{ "kg", "install" });
}

test "update: options that do not fit the source, and a development install without a checkout, refuse before any request" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, try env.mirrorSource());
    try testing.expectError(error.OptionNotForSource, env.run(.{ .pull = true }));
    try testing.expectError(error.InvalidVersion, env.run(.{ .version = "v1.2" }));
    try testing.expectError(error.InvalidReleaseBase, env.run(.{ .release_base = "http://mirror.example/r" }));

    // A pre-channel install that records no source.
    const manifest_path = try std.fs.path.join(env.arena(), &.{ env.prefix, "manifest.json" });
    const manifest = try std.Io.Dir.cwd().readFileAlloc(testing.io, manifest_path, env.arena(), .limited(1 << 20));
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = manifest_path, .data = try std.mem.replaceOwned(u8, env.arena(), manifest, "\"stable\"", "\"pre\"") });
    try env.installDirect(.{ .version = "1.0.0" }, .default_release);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = manifest_path, .data = try std.mem.replaceOwned(u8, env.arena(), manifest, "\"stable\"", "\"pre\"") });
    try testing.expectError(error.NoCheckoutRecorded, env.run(.{}));
    try testing.expectEqual(@as(usize, 0), env.mirror.requestCount());
}

test "update: a session running from the install refuses the update; this install's TinyKG service is stopped" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0", .tinykgd = .probe }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0", .tinykgd = .probe }, false);
    try env.setLatest("1.1.0");
    const exe = try std.fs.path.join(env.arena(), &.{ env.prefix, "bin", EXE });

    // A session.
    {
        var session = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "sleep", "30000" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        defer session.kill(testing.io);
        try waitForProcesses(&env, 1);
        try testing.expectError(error.SessionsRunning, env.run(.{}));
        try testing.expect(std.mem.indexOf(u8, env.log.written(), "pid ") != null);
        try testing.expect(std.mem.indexOf(u8, env.probeLog(), "--upgrade") == null);
        env.mirror.clearRequests();
        const checked = try env.run(.{ .check = true });
        try testing.expect(checked.checked_only and checked.changes());
        try testing.expectEqualSlices(update.Pid, &.{pidOf(&session)}, checked.sessions);
        try testing.expectEqual(@as(usize, 0), checked.services.len);
        try testing.expectEqual(@as(usize, 0), checked.running_sessions.len);
        const text = env.log.written();
        try testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(env.arena(), "pid {d}  {s}", .{ pidOf(&session), exe })) != null);
        try testing.expect(std.mem.indexOf(u8, text, "the update would be refused until they exit") != null);
        try testing.expectEqual(!is_windows, std.mem.indexOf(u8, text, "or with --ignore-running") != null);
        const doc = try jsonOf(&env, checked);
        try testing.expect(std.mem.indexOf(u8, doc, try std.fmt.allocPrint(env.arena(), "\"sessions\":[{d}],\"services\":[]", .{pidOf(&session)})) != null);
        try testing.expect(std.mem.indexOf(u8, doc, "\"stopped_services\":[],\"running_sessions\":[]") != null);
        try testing.expect(!env.mirror.requested("SHA256SUMS"));
        try testing.expect(std.mem.indexOf(u8, env.probeLog(), "--upgrade") == null);
        try testing.expectEqualStrings("1.0.0", (try install.measure(env.arena(), testing.io, env.prefix)).record.version);
        if (is_windows) try testing.expectError(error.IgnoreRunningUnsupported, env.run(.{ .ignore_running = true }));
    }
    try waitForProcesses(&env, 0);

    // The service: a kgd stand-in with its tinykgd child on a pipe.
    var service = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "kgd" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer service.kill(testing.io);
    try waitForProcesses(&env, 2);
    const checked = try env.run(.{ .check = true });
    try testing.expectEqualSlices(update.Pid, &.{pidOf(&service)}, checked.services);
    try testing.expectEqual(@as(usize, 0), checked.sessions.len);
    try testing.expect(std.mem.indexOf(u8, env.log.written(), "a real run stops this install's TinyKG service") != null);
    try testing.expect(std.mem.indexOf(u8, try jsonOf(&env, checked), try std.fmt.allocPrint(env.arena(), "\"sessions\":[],\"services\":[{d}]", .{pidOf(&service)})) != null);
    try testing.expectEqual(@as(usize, 2), (try platform.process_scan.listUnder(env.arena(), testing.io, env.prefix)).len);
    const outcome = try env.run(.{});
    try testing.expectEqual(update.Action.upgrade, outcome.action);
    try testing.expectEqualSlices(update.Pid, checked.services, outcome.stopped_services);
    _ = try service.wait(testing.io);
    // Its tinykgd went with it, and the install went ahead.
    try waitForProcesses(&env, 0);
    try testing.expectEqualStrings("1.1.0", (try install.measure(env.arena(), testing.io, env.prefix)).record.version);
}

test "update: --ignore-running goes ahead and names the sessions left running" {
    if (is_windows) return error.SkipZigTest; // refused there, covered above
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    try env.installDirect(.{ .version = "1.0.0" }, try env.mirrorSource());
    try env.publish(.{ .version = "1.1.0" }, false);
    try env.setLatest("1.1.0");
    const exe = try std.fs.path.join(env.arena(), &.{ env.prefix, "bin", EXE });
    var session = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "sleep", "30000" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer session.kill(testing.io);
    try waitForProcesses(&env, 1);
    const outcome = try env.run(.{ .ignore_running = true });
    try testing.expectEqual(update.Action.upgrade, outcome.action);
    try testing.expectEqual(@as(usize, 1), outcome.running_sessions.len);
    try testing.expectEqual(pidOf(&session), outcome.running_sessions[0]);
}

fn jsonOf(env: *Env, outcome: update.Outcome) ![]const u8 {
    var doc: std.Io.Writer.Allocating = .init(env.arena());
    try outcome.writeJson(&doc.writer);
    return doc.written();
}

fn pidOf(child: *const std.process.Child) update.Pid {
    if (is_windows) return GetProcessId(child.id.?);
    return @intCast(child.id.?);
}
extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;

/// Wait until exactly `count` processes run from the env's prefix.
fn waitForProcesses(env: *Env, count: usize) !void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const found = try platform.process_scan.listUnder(env.arena(), testing.io, env.prefix);
        if (found.len == count) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
    return error.TestUnexpectedResult;
}

// ── development installs ─────────────────────────────────────────────────────

const Checkout = struct {
    dir: []const u8,
    args_log: []const u8,
    git: []const u8,

    fn create(env: *Env, version: []const u8) !Checkout {
        const a = env.arena();
        var git_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git = try a.dupe(u8, platform.exe_lookup.lookup("git", &git_buf) orelse return error.SkipZigTest);
        const dir = try std.fs.path.join(a, &.{ env.root, "src", "metacodes" });
        const args_log = try std.fs.path.join(a, &.{ env.root, "install-sh.log" });
        for ([_][]const u8{ "build.zig", "release/manifest_contract.zig", "scripts/kernel_pins.py" }) |rel| {
            const path = try std.fs.path.join(a, &.{ dir, rel });
            try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(path).?);
            try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "// fixture\n" });
        }
        try std.Io.Dir.cwd().writeFile(testing.io, .{
            .sub_path = try std.fs.path.join(a, &.{ dir, "scripts", "install.sh" }),
            .data = try std.fmt.allocPrint(a, "#!/bin/sh\nfor a in \"$0\" \"$@\"; do printf '%s\\t' \"$a\"; done >> '{s}'\necho >> '{s}'\n", .{ args_log, args_log }),
        });
        const checkout: Checkout = .{ .dir = dir, .args_log = args_log, .git = git };
        try checkout.setVersion(env, version);
        try checkout.gitRun(env, &.{"init"});
        try checkout.commitAll(env);
        return checkout;
    }

    fn setVersion(self: Checkout, env: *Env, version: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{
            .sub_path = try std.fs.path.join(env.arena(), &.{ self.dir, "build.zig.zon" }),
            .data = try std.fmt.allocPrint(env.arena(), ".{{\n    .name = .metacodes,\n    .version = \"{s}\",\n}}\n", .{version}),
        });
    }

    fn gitRun(self: Checkout, env: *Env, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(env.arena(), &.{ self.git, "-C", self.dir, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false" });
        try argv.appendSlice(env.arena(), args);
        const result = try std.process.run(env.arena(), testing.io, .{ .argv = argv.items });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], result.stderr });
            return error.GitFailed;
        }
    }

    fn commitAll(self: Checkout, env: *Env) !void {
        try self.gitRun(env, &.{ "add", "-A" });
        try self.gitRun(env, &.{ "commit", "-q", "-m", "fixture" });
    }

    fn head(self: Checkout, env: *Env) ![]const u8 {
        const result = try std.process.run(env.arena(), testing.io, .{ .argv = &.{ self.git, "-C", self.dir, "rev-parse", "HEAD" } });
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn installed(self: Checkout, env: *Env, commit: []const u8, dirty: bool, version: []const u8) !void {
        // A development install of `commit`: the manifest names it.
        try env.installDirect(.{ .version = version }, try release_source.parseCheckout(env.arena(), self.dir));
        const manifest_path = try std.fs.path.join(env.arena(), &.{ env.prefix, "manifest.json" });
        const manifest = try std.Io.Dir.cwd().readFileAlloc(testing.io, manifest_path, env.arena(), .limited(1 << 20));
        var replaced = try std.mem.replaceOwned(u8, env.arena(), manifest, "0123456789ab", commit);
        replaced = try std.mem.replaceOwned(u8, env.arena(), replaced, "\"stable\"", "\"pre\"");
        if (dirty) replaced = try std.mem.replaceOwned(u8, env.arena(), replaced, "\"dirty\": false", "\"dirty\": true");
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = manifest_path, .data = replaced });
    }

    fn argsLog(self: Checkout, env: *Env) []const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, self.args_log, env.arena(), .limited(1 << 20)) catch "";
    }
};

test "update: a development install is rebuilt from its checkout only when the checkout moved or is dirty" {
    if (is_windows) return error.SkipZigTest; // refused there (next test)
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    const checkout = try Checkout.create(&env, "1.0.1-dev");
    const first = try checkout.head(&env);
    try checkout.installed(&env, first, false, "1.0.1-dev+abc");

    // The same clean commit: nothing to build.
    const same = try env.run(.{});
    try testing.expectEqual(update.Action.up_to_date, same.action);
    try testing.expectEqual(update.SourceKind.checkout, same.source);
    try testing.expectEqualStrings("", checkout.argsLog(&env));
    try testing.expectEqual(@as(usize, 0), env.mirror.requestCount());

    // A local change: rebuild with the exact installer arguments.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(env.arena(), &.{ checkout.dir, "build.zig" }), .data = "// changed\n" });
    const dirty = try env.run(.{});
    try testing.expectEqual(update.Action.rebuild, dirty.action);
    const script = try std.fs.path.join(env.arena(), &.{ checkout.dir, "scripts", "install.sh" });
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(env.arena(), "{s}\t--dev\t--source\t{s}\t--prefix\t{s}\t--no-link\t--no-sdk\t\n", .{ script, checkout.dir, env.prefix }),
        checkout.argsLog(&env),
    );

    // Another commit, clean.
    try checkout.commitAll(&env);
    try std.Io.Dir.cwd().deleteFile(testing.io, checkout.args_log);
    const moved = try env.run(.{ .check = true });
    try testing.expectEqual(update.Action.rebuild, moved.action);
    try testing.expect(moved.checked_only);
    try testing.expectEqualStrings("", checkout.argsLog(&env));

    // A checkout switched to an older version needs --allow-downgrade.
    try checkout.setVersion(&env, "0.9.0-dev");
    try checkout.commitAll(&env);
    try testing.expectError(error.DowngradeRefused, env.run(.{}));
    _ = try env.run(.{ .allow_downgrade = true });
    try testing.expect(std.mem.endsWith(u8, checkout.argsLog(&env), "--no-sdk\t--allow-downgrade\t\n"));

    // Release options do not apply, and --check never pulls.
    try testing.expectError(error.OptionNotForSource, env.run(.{ .version = "1.0.0" }));
    try testing.expectError(error.CheckWithPull, env.run(.{ .check = true, .pull = true }));
}

test "update: a development install whose checkout is gone, or on Windows, is refused" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    const gone = try std.fs.path.join(env.arena(), &.{ env.root, "removed-worktree" });
    try env.installDirect(.{ .version = "1.0.1-dev" }, try release_source.parseCheckout(env.arena(), gone));
    if (is_windows) {
        try testing.expectError(error.CheckoutUnsupportedOnWindows, env.run(.{}));
        return;
    }
    try testing.expectError(error.CheckoutMissing, env.run(.{}));
    try testing.expect(std.mem.indexOf(u8, env.log.written(), gone) != null);
}

// ── the contract with future releases ────────────────────────────────────────

test "update: the real installer names every option update passes to a release unit" {
    const cli = std.mem.span(std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ cli, "install", "--help" } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    for ([_][]const u8{ "--prefix", "--upgrade", "--sdk", "--allow-downgrade", "--release-base", "--checkout" }) |flag| {
        if (std.mem.indexOf(u8, result.stdout, flag) == null) {
            std.debug.print("`metacodes install --help` no longer names {s}:\n{s}\n", .{ flag, result.stdout });
            return error.TestExpectedEqual;
        }
    }
    const help = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ cli, "--help" } });
    defer testing.allocator.free(help.stdout);
    defer testing.allocator.free(help.stderr);
    try testing.expect(std.mem.indexOf(u8, help.stdout, "  update") != null);
}
