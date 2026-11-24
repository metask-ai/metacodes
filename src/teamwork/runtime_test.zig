//! L2 tests of the teamwork runtime and the built-in SWE loop (#514, #518,
//! #520, #523): a real git repository as the user's workspace, a real run
//! directory, worktree, ledgers and merge-back, scripted seats (and, in one
//! test, the real metacodes seat driver on a scripted provider). Each test
//! proves an input changes the user's workspace, or provably does not.
//!
//! POSIX only: the fixtures run git through `/bin/sh`.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const types = @import("types.zig");
const config = @import("config.zig");
const run_dir = @import("run_dir.zig");
const common = @import("drivers/common.zig");
const factory = @import("drivers/factory.zig");
const audit = @import("audit.zig");
const runtime = @import("runtime.zig");
const swe_loop = @import("swe_loop.zig");
const tools_common = @import("../tools/common.zig");
const swarm_team = @import("../swarm/team.zig");
const util_fs = @import("../util/fs.zig");
const permission_mod = @import("../permission.zig");
const tools_mod = @import("../tools.zig");
const drivers_test = @import("drivers/drivers_test.zig");
const reviewer = @import("reviewer.zig");
const merge_back = @import("merge_back.zig");
const interview = @import("interview.zig");
const progress = @import("progress.zig");
const ledger_mod = @import("ledger.zig");
const lesson = @import("../kg/lesson.zig");
const manager = @import("manager.zig");
const claude_code = @import("drivers/claude_code.zig");
const sandbox_exec = @import("../sandbox/exec.zig");
const pprocess = @import("platform").process;
const util_time = @import("../util/time.zig");

const testing = std.testing;
const PathBuf = [std.fs.max_path_bytes]u8;

const run_id_text = "run-4c1d9e2a";
const request_text = "Add a feature file.\n\nfeature.txt must exist and say \"feature\".\n";
const check_text = "test -f feature.txt";

const handoff_text = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";

// ── shell and files ─────────────────────────────────────────────────────────

/// Run `script` with `/bin/sh` in `cwd`; stdout owned by `testing.allocator`.
fn sh(cwd: []const u8, script: []const u8) ![]u8 {
    const a = testing.allocator;
    const script_z = try a.dupeZ(u8, script);
    defer a.free(script_z);
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", script_z.ptr, null };
    const out = try tools_common.spawnCaptureWithStderrTimed(&argv, a, null, 60_000, null, 1 << 20, cwd);
    defer a.free(out.stderr);
    if (out.exit_code != 0) {
        std.debug.print("sh failed ({d}): {s}\n{s}\n", .{ out.exit_code, script, out.stderr });
        a.free(out.stdout);
        return error.ShellFailed;
    }
    return out.stdout;
}

fn writeFile(dir: []const u8, rel: []const u8, bytes: []const u8) !void {
    var buf: PathBuf = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, rel });
    try util_fs.mkdirParentsOf(path);
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    if (!pfs.writeAll(fd, bytes)) return error.WriteFailed;
}

fn readFile(dir: []const u8, rel: []const u8) ?[]u8 {
    var buf: PathBuf = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, rel }) catch return null;
    return swarm_team.readFileAlloc(testing.allocator, path);
}

fn expectFile(dir: []const u8, rel: []const u8, want: []const u8) !void {
    const got = readFile(dir, rel) orelse {
        std.debug.print("missing {s}/{s}\n", .{ dir, rel });
        return error.FileMissing;
    };
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn exists(dir: []const u8, rel: []const u8) bool {
    var buf: PathBuf = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, rel }) catch return false;
    return pfs.exists(path.ptr);
}

// ── fixture ─────────────────────────────────────────────────────────────────

const Fixture = struct {
    root: run_dir.test_support.TestRoot,
    repo_buf: PathBuf = undefined,
    repo_len: usize = 0,
    state_buf: PathBuf = undefined,
    state_len: usize = 0,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Fixture, tag: []const u8) !void {
        self.* = .{ .root = run_dir.test_support.TestRoot.init(tag), .arena = std.heap.ArenaAllocator.init(testing.allocator) };
        errdefer self.deinit();
        self.repo_len = (try std.fmt.bufPrint(&self.repo_buf, "{s}/repo", .{self.root.slice()})).len;
        self.state_len = (try std.fmt.bufPrint(&self.state_buf, "{s}/state", .{self.root.slice()})).len;
        try util_fs.mkdirParents(self.repo());
        try util_fs.mkdirParents(self.state());
        try writeFile(self.repo(), "README.md", "readme\n");
        try writeFile(self.repo(), "src/app.txt", "v1\n");
        try writeFile(self.repo(), ".gitignore", "zig-out/\n");
        const out = try sh(self.repo(), "git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false commit -qm init");
        testing.allocator.free(out);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.root.deinit();
    }

    fn repo(self: *const Fixture) []const u8 {
        return self.repo_buf[0..self.repo_len];
    }

    fn state(self: *const Fixture) []const u8 {
        return self.state_buf[0..self.state_len];
    }

    /// `{"enabled":true,"check_command":<check_text><extra>}`; `extra`
    /// without `budget_usd` gets a $5 cap.
    fn cfg(self: *Fixture, extra: []const u8) !config.Config.Enabled {
        const a = self.arena.allocator();
        const budget = if (std.mem.indexOf(u8, extra, "budget_usd") == null) ",\"budget_usd\":5" else "";
        const text = try std.fmt.allocPrint(a, "{{\"enabled\":true,\"check_command\":\"{s}\"{s}{s}}}", .{ check_text, budget, extra });
        return (try config.validate(try config.parse(a, text, null), null)).enabled;
    }

    fn options(self: *const Fixture) runtime.StartOptions {
        return .{ .state_root = self.state(), .run_id = types.RunId.parse(run_id_text) catch unreachable, .workspace = self.repo() };
    }

    /// `git status --porcelain` plus HEAD plus every tracked and untracked
    /// file's bytes: equal snapshots mean an untouched workspace.
    fn workspaceBytes(self: *const Fixture) ![]u8 {
        return sh(self.repo(), "git rev-parse HEAD && git status --porcelain --untracked-files=all && " ++
            "git ls-files -co --exclude-standard -z | xargs -0 cat");
    }

    fn worktree(self: *const Fixture, buf: *PathBuf) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/teamwork/{s}/worktree", .{ self.state(), run_id_text }) catch unreachable;
    }

    fn runFile(self: *const Fixture, buf: *PathBuf, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/teamwork/{s}/{s}", .{ self.state(), run_id_text, rel }) catch unreachable;
    }
};

// ── scripted seats ──────────────────────────────────────────────────────────

const File = struct { path: []const u8, bytes: []const u8 };

/// What one seat does, keyed by its seat id.
const Plan = struct {
    seat: []const u8,
    /// Written into the seat's workspace (the run's worktree).
    files: []const File = &.{},
    /// Written into the user's repository while the seat runs: the user
    /// editing concurrently.
    user_files: []const File = &.{},
    /// `review.json` for a reviewer.
    review: ?[]const u8 = null,
    /// Charged to the run ledger before anything else.
    charge_usd: f64 = 0,
    /// The seat fails like a harness would.
    fail: ?types.SeatError = null,
    /// A file that must already be in the workspace, else the seat fails.
    require: ?[]const u8 = null,
    seat_files: []const File = &.{},
    handoff: []const u8 = handoff_text,
};

const ScriptedSeats = struct {
    plans: []const Plan,
    user_repo: []const u8,
    binding: common.Binding = undefined,
    /// Seat id and packet bytes of every seat run, in order; owned.
    ran: std.ArrayList(Ran) = .empty,

    const Ran = struct { seat: types.SeatId, packet: []u8, harness: types.Harness = .metacodes, remaining_usd: f64 = 0 };

    fn deinit(self: *ScriptedSeats) void {
        for (self.ran.items) |r| testing.allocator.free(r.packet);
        self.ran.deinit(testing.allocator);
    }

    fn source(self: *ScriptedSeats) runtime.SeatSource {
        return .{ .custom = .{ .ctx = self, .driverFn = driverFn } };
    }

    fn packetOf(self: *const ScriptedSeats, seat: []const u8) []const u8 {
        for (self.ran.items) |r| if (std.mem.eql(u8, r.seat.slice(), seat)) return r.packet;
        return "";
    }

    fn driverFn(ctx: *anyopaque, _: *const types.SeatSpec, binding: common.Binding) types.SeatDriver {
        const self: *ScriptedSeats = @ptrCast(@alignCast(ctx));
        self.binding = binding;
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: types.SeatDriver.VTable = .{ .run = run };

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, spec: *const types.SeatSpec, paths: types.SeatPaths, abort: *const types.AbortSignal) types.SeatDriver.Error!types.SeatOutcome {
        const self: *ScriptedSeats = @ptrCast(@alignCast(ptr));
        const seat = self.binding.seat;
        const packet = swarm_team.readFileAlloc(testing.allocator, paths.packet) orelse try testing.allocator.dupe(u8, "");
        try self.ran.append(testing.allocator, .{ .seat = seat, .packet = packet, .harness = spec.harnessKind(), .remaining_usd = self.binding.ledger.remainingUsd() });
        const plan = for (self.plans) |p| {
            if (std.mem.eql(u8, p.seat, seat.slice())) break p;
        } else {
            std.debug.print("unplanned seat {s}\n", .{seat.slice()});
            return .{ .failed = .spawn_failed };
        };
        if (plan.charge_usd > 0) _ = common.charge(self.binding, .metacodes, 1, .{ .provider_estimate = plan.charge_usd });
        // A live seat notices the shared signal, as the real drivers do.
        if (abort.isAborted()) return .aborted;
        if (plan.fail) |err| return .{ .failed = err };
        if (plan.require) |rel| if (!exists(paths.workspace, rel)) return .{ .failed = .{ .exited = 99 } };
        for (plan.files) |f| writeFile(paths.workspace, f.path, f.bytes) catch return .{ .failed = .spawn_failed };
        for (plan.user_files) |f| writeFile(self.user_repo, f.path, f.bytes) catch return .{ .failed = .spawn_failed };
        const seat_dir = common.seatDir(paths);
        if (plan.review) |review| writeFile(seat_dir, "review.json", review) catch return .{ .failed = .spawn_failed };
        for (plan.seat_files) |f| writeFile(seat_dir, f.path, f.bytes) catch return .{ .failed = .spawn_failed };
        writeFile(seat_dir, "handoff.md", plan.handoff) catch return .{ .failed = .spawn_failed };
        return run_dir.collectHandoff(gpa, paths.handoff);
    }
};

const digest = "a" ** 64;
const approve_review = "{\"verdict\":\"approve\",\"evidence\":[{\"command\":\"" ++ check_text ++ "\",\"exit_code\":0,\"output_digest\":\"" ++ digest ++ "\",\"output_excerpt\":\"\"}],\"issues\":{\"opened\":[],\"closed\":[],\"still_open\":[]}}";

fn approveClosing(comptime closed: []const u8) []const u8 {
    return "{\"verdict\":\"approve\",\"evidence\":[{\"command\":\"" ++ check_text ++ "\",\"exit_code\":0,\"output_digest\":\"" ++ digest ++ "\",\"output_excerpt\":\"\"}],\"issues\":{\"opened\":[],\"closed\":[" ++ closed ++ "],\"still_open\":[]}}";
}

const request_changes_review = "{\"verdict\":\"request_changes\",\"evidence\":[],\"issues\":{\"opened\":[{\"id\":\"no-test\",\"title\":\"The feature has no test\",\"detail\":\"Add tests/feature.sh.\"}],\"closed\":[],\"still_open\":[]}}";

const feature = File{ .path = "feature.txt", .bytes = "feature\n" };

/// Run ids, state roots and absolute paths never reach a packet.
fn expectCacheSafe(fx: *const Fixture, seats: *const ScriptedSeats) !void {
    try testing.expect(seats.ran.items.len > 0);
    for (seats.ran.items) |r| {
        try testing.expect(r.packet.len > 0);
        try testing.expect(std.mem.indexOf(u8, r.packet, run_id_text) == null);
        try testing.expect(std.mem.indexOf(u8, r.packet, fx.root.slice()) == null);
        try testing.expect(std.mem.indexOf(u8, r.packet, run_dir.seat_relative_original_request) != null);
    }
}

fn seatIds(snapshot: runtime.RunSnapshot, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (snapshot.seats, 0..) |seat, i| {
        if (i != 0) w.writeAll(",") catch unreachable;
        w.print("{s}:{s}", .{ seat.id.slice(), seat.status.name() }) catch unreachable;
    }
    return w.buffered();
}

// ── tests ───────────────────────────────────────────────────────────────────

test "teamwork preview L2: default-off start and reopen have no execution or recovery effects" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-preview-runtime");
    defer fx.deinit();
    const plans = [_]Plan{.{ .seat = "implementer-1", .files = &.{feature} }};
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    var deps: runtime.Deps = .{ .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg("");
    try testing.expectError(error.PreviewDisabled, runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options()));
    try testing.expect(!exists(fx.state(), "teamwork"));
    try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    deps.preview = .all;
    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
    _ = try run.dispatch(.implementer, "");
    try expectFile(run.status().worktree.?, "feature.txt", "feature\n");
    run.destroy();
    var dir = try run_dir.RunDir.open(testing.allocator, fx.state(), fx.options().run_id);
    defer dir.deinit(testing.allocator);
    // A same-named saved field is data, never current host authorization.
    var buf: PathBuf = undefined;
    const root = std.fs.path.dirname(try dir.path(&buf, .state)).?;
    const saved = readFile(root, "run.json") orelse return error.FileMissing;
    defer testing.allocator.free(saved);
    const forged = try std.fmt.allocPrint(testing.allocator, "{{\"preview\":true,{s}", .{saved[1..]});
    defer testing.allocator.free(forged);
    try writeFile(root, "run.json", forged);
    try writeFile(root, "budget.jsonl", "{\"torn\":");
    deps.preview = .none;
    try testing.expectError(error.PreviewDisabled, runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id));
    try expectFile(root, "budget.jsonl", "{\"torn\":");
    try expectFile(root, "run.json", forged);
    try testing.expectEqual(@as(usize, 1), seats.ran.items.len);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    try testing.expect(!exists(fx.repo(), "feature.txt"));
}

test "teamwork preview L2: opt-out blocks an approved completion but permits cancellation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-preview-completion");
    defer fx.deinit();
    const plans = [_]Plan{ .{ .seat = "implementer-1", .files = &.{feature} }, .{ .seat = "reviewer-1", .review = approve_review } };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.Phase.review_approved, run.status().state.phase());
    run.deps.preview = .none;
    try testing.expectError(error.PreviewDisabled, run.dispatch(.implementer, ""));
    try testing.expectError(error.PreviewDisabled, run.requestCompletion());
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    try testing.expectEqual(@as(usize, 2), seats.ran.items.len);
    try testing.expect(!exists(fx.repo(), "feature.txt"));
    try run.cancel();
    try testing.expectEqual(runtime.Phase.cancelled, run.status().state.phase());
}

test "teamwork runtime L2: the SWE loop's happy path changes the workspace by exactly the implementer's diff, uncommitted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-happy");
    defer fx.deinit();
    // The user has uncommitted work when the run starts: the implementer
    // starts from it, and merge-back leaves it alone.
    try writeFile(fx.repo(), "draft.txt", "draft\n");
    const head_before = try sh(fx.repo(), "git rev-parse HEAD");
    defer testing.allocator.free(head_before);
    const index_before = readFile(fx.repo(), ".git/index") orelse return error.FileMissing;
    defer testing.allocator.free(index_before);

    const plans = [_]Plan{
        .{ .seat = "implementer-1", .require = "draft.txt", .files = &.{ feature, .{ .path = "src/app.txt", .bytes = "v2\n" } }, .user_files = &.{.{ .path = "README.md", .bytes = "readme edited by the user\n" }} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();

    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    try testing.expectEqualStrings("Add a feature file.", run.status().goal);
    const final = try swe_loop.drive(run);

    if (final != .done) {
        std.debug.print("happy path final state: {any}\n", .{final});
        for (run.status().seats) |seat| std.debug.print("happy path seat {s}: {any}\n", .{ seat.id.slice(), seat.result });
    }
    try testing.expectEqual(runtime.State{ .done = .{ .files_changed = 2, .worktree_removed = true } }, final);
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try expectFile(fx.repo(), "src/app.txt", "v2\n");
    try expectFile(fx.repo(), "README.md", "readme edited by the user\n");
    try expectFile(fx.repo(), "draft.txt", "draft\n");
    try expectFile(fx.repo(), ".git/index", index_before);
    const porcelain = try sh(fx.repo(), "git status --porcelain");
    defer testing.allocator.free(porcelain);
    try testing.expectEqualStrings(" M README.md\n M src/app.txt\n?? draft.txt\n?? feature.txt\n", porcelain);
    const head_after = try sh(fx.repo(), "git rev-parse HEAD");
    defer testing.allocator.free(head_after);
    try testing.expectEqualStrings(head_before, head_after);
    var wt_buf: PathBuf = undefined;
    const worktree = fx.worktree(&wt_buf);
    try testing.expect(!exists(worktree, ""));
    const worktrees = try sh(fx.repo(), "git worktree list --porcelain | grep -c '^worktree '");
    defer testing.allocator.free(worktrees);
    try testing.expectEqualStrings("1\n", worktrees);

    // The auditor saw the recorded request and the implementer's worktree.
    try testing.expectEqualStrings(request_text, auditor.last_request.?);
    try testing.expectEqualStrings(worktree, auditor.last_workspace.?);
    const snapshot = run.status();
    var ids_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:done", seatIds(snapshot, &ids_buf));
    try testing.expect(snapshot.worktree == null);
    try testing.expectEqual(@as(u8, 1), snapshot.audit.used);
    try expectCacheSafe(&fx, &seats);
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-1"), check_text) != null);
    // run.json says done.
    var state_buf: PathBuf = undefined;
    const state_json = readFile(fx.runFile(&state_buf, ""), "run.json") orelse return error.NoState;
    defer testing.allocator.free(state_json);
    try testing.expect(std.mem.indexOf(u8, state_json, "\"state\":\"done\"") != null);
}

test "teamwork runtime L2: a review requesting changes sends its open issue into the next implementer round, then approval completes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-changes");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = request_changes_review },
        .{ .seat = "implementer-2", .files = &.{.{ .path = "tests/feature.sh", .bytes = "test -f feature.txt\n" }} },
        .{ .seat = "reviewer-2", .review = approveClosing("\"no-test\"") },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();

    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.Phase.done, final.phase());
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try expectFile(fx.repo(), "tests/feature.sh", "test -f feature.txt\n");
    var ids_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:done,implementer-2:done,reviewer-2:done", seatIds(run.status(), &ids_buf));
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-1"), "`no-test`") == null);
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-2"), "`no-test` The feature has no test") != null);
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("reviewer-2"), "`no-test`") != null);
    try testing.expectEqual(@as(u32, 0), run.status().open_issues);
    try testing.expect(run.status().seats[1].result.?.review == .changes_requested);
    try expectCacheSafe(&fx, &seats);
}

test "teamwork runtime L2: the operations API refuses illegal steps; a stale approval goes back to review" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-ops");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
        .{ .seat = "reviewer-2", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();

    // A manager cannot claim completion, review nothing, or run other roles.
    try testing.expectError(error.NotApproved, run.requestCompletion());
    try testing.expectError(error.NothingToReview, run.dispatch(.reviewer, ""));
    try testing.expectError(error.RoleNotDispatchable, run.dispatch(.verifier, ""));
    try testing.expectError(error.RoleNotDispatchable, run.dispatch(.manager, ""));
    var leak_buf: PathBuf = undefined;
    const leak = try std.fmt.bufPrint(&leak_buf, "See {s}/teamwork/{s}/audits.", .{ fx.state(), run_id_text });
    try testing.expectError(error.InstructionsNameRunState, run.dispatch(.implementer, leak));
    try testing.expectEqual(runtime.Phase.approved, run.state.phase());
    try testing.expectEqual(@as(usize, 0), run.status().seats.len);

    _ = try run.dispatch(.implementer, "Keep the change small.");
    try testing.expectEqual(runtime.Phase.reviewing, run.state.phase());
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-1"), "## Notes from the manager\n\nKeep the change small.\n") != null);
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.Phase.review_approved, run.state.phase());

    // Something changes the worktree after the approval: it no longer counts.
    var wt_buf: PathBuf = undefined;
    try writeFile(fx.worktree(&wt_buf), "late.txt", "late\n");
    try testing.expectEqual(runtime.CompletionResult.approval_stale, try run.requestCompletion());
    try testing.expectEqual(runtime.Phase.reviewing, run.state.phase());
    try testing.expectError(error.NotApproved, run.requestCompletion());
    try testing.expectEqual(@as(u32, 0), auditor.calls);

    _ = try run.dispatch(.reviewer, "");
    const result = try run.requestCompletion();
    try testing.expectEqual(@as(u32, 2), result.done.files_changed);
    try expectFile(fx.repo(), "late.txt", "late\n");
    try testing.expectError(error.RunEnded, run.dispatch(.implementer, ""));
    try testing.expectError(error.RunEnded, run.requestCompletion());
}

test "teamwork runtime L2: two failed audits fail the run; the first report reaches the repair round; the workspace is untouched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-auditfail");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
        .{ .seat = "implementer-2", .files = &.{.{ .path = "feature.txt", .bytes = "feature, second try\n" }} },
        .{ .seat = "reviewer-2", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{ .{ .fail = "The hidden requirement is not met: feature.txt must say \"feature\".\n" }, .{ .fail = "Still not met.\n" } };
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();

    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .failed = .audit_failed }, final);
    try testing.expectEqual(@as(u32, 2), auditor.calls);
    try testing.expectEqual(@as(u8, 2), auditor.last_attempt);
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    // The work is kept where the snapshot says.
    const snapshot = run.status();
    try testing.expectEqual(@as(u8, 2), snapshot.audit.used);
    try expectFile(snapshot.worktree.?, "feature.txt", "feature, second try\n");
    var report_buf: PathBuf = undefined;
    try expectFile(fx.runFile(&report_buf, ""), "audits/audit-1.md", "# Completion audit 1: fail\n\nThe hidden requirement is not met: feature.txt must say \"feature\".\n");
    for ([_][]const u8{ "implementer-2", "reviewer-2" }) |seat| {
        try testing.expect(std.mem.indexOf(u8, seats.packetOf(seat), run_dir.seat_relative_first_audit_report) != null);
    }
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-1"), "audit-1.md") == null);
    try expectCacheSafe(&fx, &seats);
}

test "teamwork runtime L2: an unverified audit forwards its leads to one more round; a second unverified audit fails the run without merging" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-unverified");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
        .{ .seat = "implementer-2", .files = &.{.{ .path = "feature.txt", .bytes = "feature, with a test\n" }} },
        .{ .seat = "reviewer-2", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{ .{ .unverified = "Not established:\nthe --flag output\n" }, .{ .unverified = "Still not established.\n" } };
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();

    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .failed = .audit_unverified }, final);
    try testing.expectEqual(@as(u32, 2), auditor.calls);
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try expectFile(run.status().worktree.?, "feature.txt", "feature, with a test\n");
    var report_buf: PathBuf = undefined;
    try expectFile(fx.runFile(&report_buf, ""), "audits/audit-1.md", "# Completion audit 1: unverified\n\nNot established:\nthe --flag output\n");
    for ([_][]const u8{ "implementer-2", "reviewer-2" }) |seat| {
        const packet = seats.packetOf(seat);
        try testing.expect(std.mem.indexOf(u8, packet, run_dir.seat_relative_first_audit_report) != null);
        try testing.expect(std.mem.indexOf(u8, packet, "could not confirm") != null);
    }
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-1"), "audit-1.md") == null);
    try expectCacheSafe(&fx, &seats);
}

test "teamwork runtime L2: a pass after the leads round merges; a failed second audit after unverified fails the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const endings = [_]struct { second: audit.StubAuditor.Scripted, final: runtime.Phase }{
        .{ .second = .pass, .final = .done },
        .{ .second = .{ .fail = "The flag is missing.\n" }, .final = .failed },
    };
    for (endings) |ending| {
        var fx: Fixture = undefined;
        try fx.init("cc-zig-teamwork-rt-leads");
        defer fx.deinit();
        const before = try fx.workspaceBytes();
        defer testing.allocator.free(before);
        const plans = [_]Plan{
            .{ .seat = "implementer-1", .files = &.{feature} },
            .{ .seat = "reviewer-1", .review = approve_review },
            .{ .seat = "implementer-2", .files = &.{.{ .path = "feature.txt", .bytes = "feature\n" }} },
            .{ .seat = "reviewer-2", .review = approve_review },
        };
        var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
        defer seats.deinit();
        const script = [_]audit.StubAuditor.Scripted{ .{ .unverified = "Not established: the flag.\n" }, ending.second };
        var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
        defer auditor.deinit();

        const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
        defer run.destroy();
        const final = try swe_loop.drive(run);

        try testing.expectEqual(ending.final, final.phase());
        try testing.expectEqual(@as(u32, 2), auditor.calls);
        switch (ending.final) {
            .done => try expectFile(fx.repo(), "feature.txt", "feature\n"),
            else => {
                try testing.expectEqual(runtime.State{ .failed = .audit_failed }, final);
                const after = try fx.workspaceBytes();
                defer testing.allocator.free(after);
                try testing.expectEqualStrings(before, after);
            },
        }
    }
}

test "teamwork runtime: Windows refuses to start or reopen a run before writing anything (#517)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var root = run_dir.test_support.TestRoot.init("cc-zig-teamwork-rt-windows");
    defer root.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = (try config.validate(try config.parse(a, "{\"enabled\":true,\"budget_usd\":5}", null), null)).enabled;
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = root.slice() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const id = try types.RunId.parse(run_id_text);

    try testing.expect(!runtime.platform_supported);
    try testing.expectError(error.UnsupportedPlatform, runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, .{ .state_root = root.slice(), .run_id = id, .workspace = root.slice() }));
    try testing.expectError(error.UnsupportedPlatform, runtime.Run.reopen(testing.allocator, deps, cfg, root.slice(), id));
    try testing.expect(!exists(root.slice(), "teamwork"));
    try testing.expectError(error.Unsupported, reviewer.workspaceTree(testing.allocator, root.slice(), root.slice(), null));
}

test "teamwork runtime L2: an unavailable audit is never a pass" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-unavailable");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    // The production default until the verifier adapter is configured.
    var unavailable: audit.UnavailableAuditor = .{};
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = unavailable.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .failed = .audit_unavailable }, final);
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(run.status().worktree != null);
    try testing.expectEqual(audit.VerdictKind.unavailable, run.status().audit.last.?);
}

test "teamwork runtime L2: reaching the budget aborts the live seat through the shared signal; nothing merges" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-budget");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .charge_usd = 1.5, .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(",\"budget_usd\":1"), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .budget_exhausted = .implementing }, final);
    // The charge that reached the cap tripped the seat's own abort signal
    // before the seat could write anything.
    try testing.expect(run.abort.isAborted());
    try testing.expect(run.status().seats[0].result.? == .aborted);
    try testing.expectEqual(@as(usize, 1), run.status().seats.len);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    var wt_buf: PathBuf = undefined;
    try testing.expect(!exists(fx.worktree(&wt_buf), "feature.txt"));
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    var ledger_buf: PathBuf = undefined;
    try expectFile(fx.runFile(&ledger_buf, ""), "budget.jsonl", "{\"seat_id\":\"implementer-1\",\"harness\":\"metacodes\",\"usd\":1.5,\"wallclock_ms\":1,\"source\":\"provider_estimate\"}\n");
    try testing.expectError(error.RunEnded, run.dispatch(.implementer, ""));
}

test "teamwork runtime L2: a run its budget stopped keeps its worktree and continues only under a higher approved cap" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-raise");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .charge_usd = 1.5 },
        .{ .seat = "implementer-2", .require = "partial.txt", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg(",\"budget_usd\":1");
    const id = fx.options().run_id;
    {
        const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
        defer run.destroy();
        try testing.expectEqual(runtime.State{ .budget_exhausted = .implementing }, try swe_loop.drive(run));
    }
    var wt_buf: PathBuf = undefined;
    try writeFile(fx.worktree(&wt_buf), "partial.txt", "partial\n");
    {
        const kept = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), id);
        defer kept.destroy();
        try testing.expectEqual(runtime.State{ .budget_exhausted = .implementing }, try swe_loop.drive(kept));
    }
    try testing.expectError(error.CapNotRaised, runtime.Run.reopenWithCap(testing.allocator, deps, cfg, fx.state(), id, 1));
    try testing.expectError(error.CapNotRaised, runtime.Run.reopenWithCap(testing.allocator, deps, cfg, fx.state(), id, 1.5));
    var raised = cfg;
    raised.budget_usd = 3;
    try testing.expectError(error.ConfigurationChanged, runtime.Run.reopenWithCap(testing.allocator, deps, raised, fx.state(), id, 4));
    {
        const run = try runtime.Run.reopenWithCap(testing.allocator, deps, cfg, fx.state(), id, 3);
        defer run.destroy();
        try testing.expectEqual(@as(f64, 3), run.status().budget.cap_usd);
        try testing.expectEqual(@as(f64, 1.5), run.status().budget.spent_usd);
        try testing.expect(try swe_loop.drive(run) == .done);
    }
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try expectFile(fx.repo(), "partial.txt", "partial\n");
    try testing.expectError(error.NotResumable, runtime.Run.reopenWithCap(testing.allocator, deps, raised, fx.state(), id, 5));
}

test "teamwork runtime L2: no dispatch without budget left; cancel stops the run without touching the workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-predispatch");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{.{ .seat = "implementer-1", .files = &.{feature} }};
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    {
        const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
        defer run.destroy();
        // Spend recorded elsewhere in the run (an interviewer, say) used it up.
        try testing.expectError(error.BudgetExhausted, run.ledger.charge(.{ .seat_id = try types.SeatId.parse("interviewer-1"), .harness = .metacodes, .wallclock_ms = 0, .cost = .{ .provider_estimate = 5 } }));
        try testing.expectError(error.BudgetExhausted, run.dispatch(.implementer, ""));
        try testing.expectEqual(runtime.State{ .budget_exhausted = .approved }, run.state);
        try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
        var recovery = try run.dir.recover(testing.allocator);
        defer recovery.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), recovery.seats.len);
    }
    var other_buf: PathBuf = undefined;
    const other_state = try std.fmt.bufPrint(&other_buf, "{s}/state2", .{fx.root.slice()});
    var options = fx.options();
    options.state_root = other_state;
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), options);
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    try run.cancel();
    try testing.expectEqual(runtime.State.cancelled, run.state);
    try testing.expect(run.abort.isAborted());
    try testing.expectError(error.RunEnded, run.dispatch(.reviewer, ""));
    try testing.expectError(error.RunEnded, run.requestCompletion());
    try run.cancel();
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
}

test "teamwork runtime L2: the round cap ends a review loop that never approves" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-rounds");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = request_changes_review },
        // A crashed seat is run again in a new seat, within the cap.
        .{ .seat = "implementer-2", .fail = .{ .exited = 1 } },
        .{ .seat = "implementer-3", .files = &.{feature} },
        .{ .seat = "reviewer-2", .review = "{\"verdict\":\"request_changes\",\"evidence\":[],\"issues\":{\"opened\":[],\"closed\":[],\"still_open\":[\"no-test\"]}}" },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(",\"max_rounds\":3"), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .failed = .rounds_exhausted }, final);
    var ids_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:done,implementer-2:failed,implementer-3:done,reviewer-2:done", seatIds(run.status(), &ids_buf));
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "teamwork runtime L2: a user edit to the implementer's file is a conflict; both sides are kept" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-conflict");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{ feature, .{ .path = "src/app.txt", .bytes = "implementer\n" } }, .user_files = &.{.{ .path = "src/app.txt", .bytes = "user\n" }} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State{ .failed = .merge_conflict }, final);
    // Neither side lost: the user's edit in the workspace, the
    // implementer's in the kept worktree and in merge.patch.
    try expectFile(fx.repo(), "src/app.txt", "user\n");
    try testing.expect(!exists(fx.repo(), "feature.txt"));
    const snapshot = run.status();
    try testing.expectEqual(@as(u32, 1), snapshot.merge_conflicts);
    try expectFile(snapshot.worktree.?, "src/app.txt", "implementer\n");
    var run_buf: PathBuf = undefined;
    const run_root = fx.runFile(&run_buf, "");
    try expectFile(run_root, "merge-conflicts.txt", "src/app.txt\n");
    const patch = readFile(run_root, "merge.patch") orelse return error.NoPatch;
    defer testing.allocator.free(patch);
    try testing.expect(std.mem.indexOf(u8, patch, "+implementer\n") != null);
    try testing.expect(std.mem.indexOf(u8, patch, "+feature\n") != null);
}

test "teamwork runtime L2: merge-back checks complete preimages after conflict discovery" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const original = "old headline\n" ++ "unchanged context\n" ** 12 ++ "old footer\n";
    const edited = "old headline\n" ++ "unchanged context\n" ** 12 ++ "user footer\n";
    const candidate = "new headline\n" ++ "unchanged context\n" ** 12 ++ "old footer\n";
    const Edit = struct {
        fn afterScan(in: merge_back.Input) merge_back.Error!void {
            writeFile(in.repo, "src/app.txt", edited) catch return error.GitFailed;
        }
    };
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-merge-preimage");
    defer fx.deinit();
    const gpa = testing.allocator;
    try writeFile(fx.repo(), "src/app.txt", original);
    const base = try merge_back.snapshot(gpa, fx.repo(), fx.state(), null);
    const wt = try std.fs.path.join(fx.arena.allocator(), &.{ fx.state(), "candidate" });
    try merge_back.addWorktree(gpa, fx.repo(), wt, base.commit, null);
    defer _ = merge_back.removeWorktree(gpa, fx.repo(), wt);
    try writeFile(wt, "src/app.txt", candidate);
    try writeFile(wt, "feature.txt", "feature\n");
    const approved = try reviewer.workspaceTree(gpa, wt, fx.state(), null);
    const patch = try std.fs.path.joinZ(fx.arena.allocator(), &.{ fx.state(), "merge.patch" });
    const conflicts = try std.fs.path.joinZ(fx.arena.allocator(), &.{ fx.state(), "merge-conflicts.txt" });
    try testing.expectEqual(merge_back.Result{ .conflict = 1 }, try merge_back.mergeBackAfterScan(gpa, .{
        .repo = fx.repo(),
        .base = base,
        .approved = approved,
        .scratch_dir = fx.state(),
        .patch_path = patch,
        .conflicts_path = conflicts,
    }, Edit.afterScan));
    try expectFile(fx.repo(), "src/app.txt", edited);
    try expectFile(wt, "src/app.txt", candidate);
    try testing.expect(!exists(fx.repo(), "feature.txt"));
}

test "teamwork runtime L2: merge-back refuses a gitlink before applying any ordinary files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-gitlink");
    defer fx.deinit();
    const gpa = testing.allocator;
    const before = try fx.workspaceBytes();
    defer gpa.free(before);
    const base = try merge_back.snapshot(gpa, fx.repo(), fx.state(), null);
    const wt = try std.fs.path.join(fx.arena.allocator(), &.{ fx.state(), "candidate" });
    try merge_back.addWorktree(gpa, fx.repo(), wt, base.commit, null);
    defer _ = merge_back.removeWorktree(gpa, fx.repo(), wt);
    try writeFile(wt, "feature.txt", "feature\n");
    const tree = try sh(wt, "git add feature.txt && git update-index --add --cacheinfo 160000,$(git rev-parse HEAD),sub && git write-tree");
    defer gpa.free(tree);
    const patch = try std.fs.path.joinZ(fx.arena.allocator(), &.{ fx.state(), "merge.patch" });
    const conflicts = try std.fs.path.joinZ(fx.arena.allocator(), &.{ fx.state(), "merge-conflicts.txt" });
    const result = try merge_back.mergeBack(gpa, .{
        .repo = fx.repo(),
        .base = base,
        .approved = try reviewer.TreeId.parse(std.mem.trimEnd(u8, tree, "\n")),
        .scratch_dir = fx.state(),
        .patch_path = patch,
        .conflicts_path = conflicts,
    });
    try testing.expect(result == .apply_failed);
    const after = try fx.workspaceBytes();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
    try expectFile(wt, "feature.txt", "feature\n");
}

test "teamwork runtime L2: interrupted admission is retryable before publication and resumable after it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-admission-recovery");
    defer fx.deinit();
    const gpa = testing.allocator;
    const opts = fx.options();
    {
        var incomplete = try run_dir.RunDir.create(gpa, fx.state(), opts.run_id);
        defer incomplete.deinit(gpa);
        try incomplete.writeOriginalRequest(request_text);
    }
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const deps: runtime.Deps = .{
        .preview = .all,
        .seats = seats.source(),
        .auditor = auditor.auditor(),
        .cli_approval = .{ .config_json = "{\"enabled\":true,\"budget_usd\":5}", .host_sha256 = @splat(0) },
    };
    const cfg = try fx.cfg("");
    const run = try runtime.Run.start(gpa, deps, .{ .text = request_text, .source = .request_file }, cfg, opts);
    run.destroy();
    var path_buf: PathBuf = undefined;
    const dir = fx.runFile(&path_buf, "");
    const published = readFile(dir, "run.json") orelse return error.MissingRunState;
    defer gpa.free(published);
    const interrupted = try std.mem.replaceOwned(u8, gpa, published, "\"initial_checkout_pending\":false", "\"initial_checkout_pending\":true");
    defer gpa.free(interrupted);
    try testing.expect(!std.mem.eql(u8, published, interrupted));
    try testing.expect(std.mem.indexOf(u8, interrupted, "\"approved_config_json\"") != null);
    try writeFile(dir, "run.json", interrupted);
    const resumed = try runtime.Run.reopen(gpa, deps, cfg, fx.state(), opts.run_id);
    defer resumed.destroy();
    try testing.expectEqual(runtime.Phase.approved, resumed.state.phase());
    try expectFile(resumed.status().worktree.?, "src/app.txt", "v1\n");
    const registrations = try sh(fx.repo(), "git worktree list --porcelain | grep -c '^worktree '");
    defer gpa.free(registrations);
    try testing.expectEqualStrings("2\n", registrations);
}

test "teamwork runtime L2: abort during the final audit tree read keeps the checkout untouched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Recheck = struct {
        fn abortRead(_: std.mem.Allocator, _: []const u8, _: []const u8, signal: ?*const types.AbortSignal) reviewer.TreeError!reviewer.TreeId {
            @constCast(signal orelse return error.GitFailed).abort(.user_interrupt);
            return error.Aborted;
        }
    };
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-abort-recheck");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.StubAuditor = .{ .script = &.{.pass}, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{
        .preview = .all,
        .seats = seats.source(),
        .auditor = auditor.auditor(),
        .recheck_audited_tree = Recheck.abortRead,
    }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.CompletionResult.cancelled, try run.requestCompletion());
    try expectFile(run.status().worktree.?, "feature.txt", "feature\n");
    try testing.expect(!exists(fx.repo(), "feature.txt"));
    var state_buf: PathBuf = undefined;
    const state = readFile(fx.runFile(&state_buf, ""), "run.json") orelse return error.MissingRunState;
    defer testing.allocator.free(state);
    try testing.expect(std.mem.indexOf(u8, state, "\"state\":\"cancelled\"") != null);
}

test "teamwork runtime L2: reopening cannot change the approved budget, harness or check" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-policy");
    defer fx.deinit();
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg("");
    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
    try testing.expectError(error.RunBusy, runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id));
    run.destroy();
    var changed = cfg;
    changed.budget_usd = 50;
    try testing.expectError(error.ConfigurationChanged, runtime.Run.reopen(testing.allocator, deps, changed, fx.state(), fx.options().run_id));
    changed = cfg;
    changed.check_command = try config.CheckCommand.init("true");
    try testing.expectError(error.ConfigurationChanged, runtime.Run.reopen(testing.allocator, deps, changed, fx.state(), fx.options().run_id));
    changed = cfg;
    changed.seats.getPtr(.implementer).model = "another-model";
    try testing.expectError(error.ConfigurationChanged, runtime.Run.reopen(testing.allocator, deps, changed, fx.state(), fx.options().run_id));
    const reopened = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id);
    defer reopened.destroy();
    try testing.expectEqual(@as(f64, 5), reopened.status().budget.cap_usd);
    try testing.expectEqual(@as(usize, 0), reopened.status().seats.len);
}

test "teamwork runtime L2: creating a worktree does not run repository hooks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-hooks");
    defer fx.deinit();
    try writeFile(fx.repo(), ".git/hooks/post-checkout", "#!/bin/sh\nprintf hook > hook-ran.txt\n");
    const out = try sh(fx.repo(), "chmod +x .git/hooks/post-checkout");
    testing.allocator.free(out);
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    try testing.expect(!exists(run.status().worktree.?, "hook-ran.txt"));
}

test "teamwork runtime L2: candidate clean filters cannot execute code on the controller" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-filters");
    defer fx.deinit();
    try writeFile(fx.repo(), "filter.sh", "cat\n");
    try writeFile(fx.repo(), ".gitattributes", "*.dat filter=worker\n");
    try writeFile(fx.repo(), "data.dat", "base\n");
    const setup = try sh(fx.repo(), "git config filter.worker.clean '/bin/sh ./filter.sh' && git config filter.worker.smudge /bin/cat");
    testing.allocator.free(setup);
    const modified = try std.fmt.allocPrint(fx.arena.allocator(), "printf called > '{s}/callback-ran'\ncat\n", .{fx.state()});
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{ feature, .{ .path = "filter.sh", .bytes = modified }, .{ .path = "data.dat", .bytes = "candidate\n" } } },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expect(!exists(fx.state(), "callback-ran"));
}

test "teamwork runtime L2: initial worktree checkout never invokes configured smudge filters" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-checkout-filter");
    defer fx.deinit();
    const script = try std.fmt.allocPrint(fx.arena.allocator(), "printf called > '{s}/callback-ran'\ncat\n", .{fx.state()});
    try writeFile(fx.repo(), "filter.sh", script);
    try writeFile(fx.repo(), ".gitattributes", "*.dat filter=worker\n");
    try writeFile(fx.repo(), "data.dat", "base bytes\n");
    const setup = try sh(fx.repo(), "git config filter.worker.clean '/bin/sh ./filter.sh' && git config filter.worker.smudge '/bin/sh ./filter.sh' && git config filter.worker.required true");
    testing.allocator.free(setup);
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    try expectFile(run.status().worktree.?, "data.dat", "base bytes\n");
    try testing.expect(!exists(fx.state(), "callback-ran"));
}

test "teamwork runtime L2: worktree conditional includes cannot re-enable checkout filters" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-conditional-filter");
    defer fx.deinit();
    try writeFile(fx.repo(), ".gitattributes", "*.dat filter=conditional\n");
    try writeFile(fx.repo(), "data.dat", "base bytes\n");
    const cfg_text = try std.fmt.allocPrint(fx.arena.allocator(), "[filter \"conditional\"]\nsmudge = \"printf called > '{s}/callback-ran'; cat\"\nrequired = true\n", .{fx.state()});
    try writeFile(fx.repo(), ".git/conditional.cfg", cfg_text);
    const setup = try sh(fx.repo(), "git config 'includeIf.gitdir:**/worktrees/**.path' conditional.cfg");
    testing.allocator.free(setup);
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    try expectFile(run.status().worktree.?, "data.dat", "base bytes\n");
    try testing.expect(!exists(fx.state(), "callback-ran"));
}

test "teamwork runtime L2: after a crash, reopen restores seats, counters and budget, and the loop finishes the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-reopen");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .charge_usd = 0.25, .files = &.{feature} },
        .{ .seat = "reviewer-2", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg("");
    {
        const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
        defer run.destroy();
        _ = try run.dispatch(.implementer, "");
        // The process dies while reviewer-1 runs: its directory and a
        // `working` record exist, run.json does not know about it yet.
        try run.dir.createSeat(.{ .id = types.seatIdFor(.reviewer, 1), .role = .reviewer, .harness = .metacodes, .status = .working });
    }
    const run = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), try types.RunId.parse(run_id_text));
    defer run.destroy();
    const snapshot = run.status();
    try testing.expectEqual(runtime.Phase.reviewing, snapshot.state.phase());
    var ids_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:failed", seatIds(snapshot, &ids_buf));
    try testing.expect(snapshot.seats[1].result.? == .interrupted);
    try testing.expectEqual(types.SeatStatus.failed, (try run.dir.readSeatRecord(types.seatIdFor(.reviewer, 1))).status);
    try testing.expectApproxEqAbs(@as(f64, 0.25), snapshot.budget.spent_usd, 1e-9);
    try testing.expectEqual(@as(usize, 1), snapshot.budget.charges);
    const implementer_record = try run.dir.readSeatRecord(types.seatIdFor(.implementer, 1));
    const expected_charter = std.fmt.bytesToHex(@import("charters.zig").digest(.implementer), .lower);
    try testing.expectEqualStrings(&expected_charter, &implementer_record.charter_sha256.?);
    try testing.expect(snapshot.worktree != null);
    try testing.expectEqualStrings("Add a feature file.", snapshot.goal);

    const final = try swe_loop.drive(run);
    try testing.expectEqual(runtime.Phase.done, final.phase());
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:failed,reviewer-2:done", seatIds(run.status(), &ids_buf));
    // A finished run reopens as it ended.
    const again = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), try types.RunId.parse(run_id_text));
    defer again.destroy();
    try testing.expectEqual(final, again.state);
    try testing.expectError(error.RunEnded, again.dispatch(.implementer, ""));
}

// ── through the real metacodes seat driver ──────────────────────────────────

fn writeInput(arena: std.mem.Allocator, path: []const u8, content: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("file_path");
    try s.write(path);
    try s.objectField("content");
    try s.write(content);
    try s.endObject();
    return out.written();
}

test "teamwork runtime L2: the SWE loop through the real metacodes driver: observed reviewer Bash, pinned check, merge-back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-metacodes");
    defer fx.deinit();
    const a = fx.arena.allocator();
    const seat_root = try std.fmt.allocPrint(a, "{s}/teamwork/{s}/seats", .{ fx.state(), run_id_text });
    const review =
        \\{"verdict":"approve","evidence":[{"command":"cat feature.txt","exit_code":0,"output_digest":"
    ++ digest ++
        \\","output_excerpt":"feature"}],"issues":{"opened":[],"closed":[],"still_open":[]}}
    ;
    const Event = drivers_test.ScriptedProvider.Event;
    const turns = [_][]const Event{
        // implementer-1
        &.{
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, "feature.txt", "feature\n") } },
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/implementer-1/handoff.md", .{seat_root}), handoff_text) } },
        },
        &.{.{ .text = "Implemented." }},
        // reviewer-1
        &.{.{ .tool = .{ .name = "Bash", .input = "{\"command\":\"cat feature.txt\"}" } }},
        &.{
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/reviewer-1/review.json", .{seat_root}), review) } },
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/reviewer-1/handoff.md", .{seat_root}), handoff_text) } },
        },
        &.{.{ .text = "Reviewed." }},
    };
    var scripted: drivers_test.ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();
    const tool_defs = try tools_mod.toToolDefinitions(a);
    // The host would allow everything; seats get their own scope.
    const perm = permission_mod.createContext(.bypass_permissions, testing.allocator);
    const seat_deps: factory.Deps = .{
        .metacodes = .{ .provider = scripted.provider(), .tool_defs = tool_defs, .permission_ctx = &perm, .home_dir = "/nonexistent-home", .state_root = fx.state(), .max_turns = 8 },
        .claude_code = .{ .parent_env = &.{}, .home_dir = "/nonexistent-home" },
    };
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const cfg = (try config.validate(try config.parse(a, "{\"enabled\":true,\"budget_usd\":5,\"check_command\":\"cat feature.txt\"}", null), null)).enabled;
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = .{ .harness = seat_deps }, .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
    defer run.destroy();
    const final = swe_loop.drive(run) catch |err| {
        std.debug.print("tool results:\n{s}\n", .{scripted.tool_results.items});
        return err;
    };

    if (final.phase() != .done) {
        for (run.status().seats) |seat| std.debug.print("seat {s}: {any}\n", .{ seat.id.slice(), seat.result });
    }
    try testing.expectEqual(runtime.Phase.done, final.phase());
    try testing.expectEqual(@as(usize, 5), scripted.calls);
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    const snapshot = run.status();
    try testing.expect(snapshot.seats[1].result.?.review == .approved);
    // Both seats charged the ledger as provider estimates.
    try testing.expectEqual(@as(usize, 2), snapshot.budget.charges);
    // The packet files carry no run state.
    var packet_buf: PathBuf = undefined;
    for ([_][]const u8{ "implementer-1", "reviewer-1" }) |seat| {
        const packet = readFile(try std.fmt.bufPrint(&packet_buf, "{s}/{s}", .{ seat_root, seat }), "packet.md") orelse return error.NoPacket;
        defer testing.allocator.free(packet);
        try testing.expect(std.mem.indexOf(u8, packet, run_id_text) == null);
        try testing.expect(std.mem.indexOf(u8, packet, fx.root.slice()) == null);
    }
}

test "teamwork runtime L2: the same reviewer claim is rejected when the metacodes seat never ran it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-unobserved");
    defer fx.deinit();
    const a = fx.arena.allocator();
    const seat_root = try std.fmt.allocPrint(a, "{s}/teamwork/{s}/seats", .{ fx.state(), run_id_text });
    const review =
        \\{"verdict":"approve","evidence":[{"command":"cat feature.txt","exit_code":0,"output_digest":"
    ++ digest ++
        \\","output_excerpt":"feature"}],"issues":{"opened":[],"closed":[],"still_open":[]}}
    ;
    const Event = drivers_test.ScriptedProvider.Event;
    const turns = [_][]const Event{
        &.{
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, "feature.txt", "feature\n") } },
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/implementer-1/handoff.md", .{seat_root}), handoff_text) } },
        },
        &.{.{ .text = "Implemented." }},
        // reviewer-1 claims the check without running anything.
        &.{
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/reviewer-1/review.json", .{seat_root}), review) } },
            .{ .tool = .{ .name = "Write", .input = try writeInput(a, try std.fmt.allocPrint(a, "{s}/reviewer-1/handoff.md", .{seat_root}), handoff_text) } },
        },
        &.{.{ .text = "Reviewed." }},
    };
    var scripted: drivers_test.ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();
    const tool_defs = try tools_mod.toToolDefinitions(a);
    const perm = permission_mod.createContext(.bypass_permissions, testing.allocator);
    const seat_deps: factory.Deps = .{
        .metacodes = .{ .provider = scripted.provider(), .tool_defs = tool_defs, .permission_ctx = &perm, .home_dir = "/nonexistent-home", .state_root = fx.state(), .max_turns = 8 },
        .claude_code = .{ .parent_env = &.{}, .home_dir = "/nonexistent-home" },
    };
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const cfg = (try config.validate(try config.parse(a, "{\"enabled\":true,\"budget_usd\":5,\"check_command\":\"cat feature.txt\"}", null), null)).enabled;
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = .{ .harness = seat_deps }, .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.Phase.implementing, run.state.phase());
    try testing.expectEqual(std.meta.Tag(@import("reviewer.zig").RejectReason).evidence_not_observed, run.status().seats[1].result.?.review.rejected);
    try testing.expect(!exists(fx.repo(), "feature.txt"));
}

// ── through the real isolated verifier ──────────────────────────────────────

test "teamwork runtime L2: separate audit checkouts send the same initial verifier request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Capture = struct {
        fn packet(gpa: std.mem.Allocator, tag: []const u8) ![]u8 {
            var fx: Fixture = undefined;
            try fx.init(tag);
            defer fx.deinit();
            const plans = [_]Plan{
                .{ .seat = "implementer-1", .files = &.{feature} },
                .{ .seat = "reviewer-1", .review = approve_review },
            };
            var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
            defer seats.deinit();
            const Event = drivers_test.ScriptedProvider.Event;
            const turns = [_][]const Event{
                &.{.{ .tool = .{ .name = "Bash", .input = "{\"command\":\"cat feature.txt\"}" } }},
                &.{.{ .text = "REQUIREMENT: feature.txt says feature\nSUBSTITUTE: different content\nPROBE: cat feature.txt\nOBSERVED: feature\nVERDICT: PASS" }},
            };
            var scripted: drivers_test.ScriptedProvider = .{ .allocator = gpa, .turns = &turns };
            defer scripted.deinit();
            var perm = permission_mod.createContext(.accept_edits, gpa);
            perm.no_interactive_prompt = true;
            var verifier: @import("verifier_auditor.zig").VerifierAuditor = .{ .deps = .{
                .provider = scripted.provider(),
                .tool_defs = try tools_mod.toToolDefinitions(fx.arena.allocator()),
                .permission_ctx = &perm,
                .state_root = fx.state(),
            } };
            const run = try runtime.Run.start(gpa, .{ .preview = .all, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
            defer run.destroy();
            try testing.expectEqual(runtime.Phase.done, (try swe_loop.drive(run)).phase());
            const text = scripted.first_user orelse return error.VerifierRequestMissing;
            try testing.expect(std.mem.indexOf(u8, text, fx.root.slice()) == null);
            return gpa.dupe(u8, text);
        }
    };
    const gpa = testing.allocator;
    const first = try Capture.packet(gpa, "cc-zig-teamwork-audit-wire-first");
    defer gpa.free(first);
    const second = try Capture.packet(gpa, "cc-zig-teamwork-audit-wire-second");
    defer gpa.free(second);
    try testing.expectEqualStrings(first, second);
}

test "teamwork runtime L2: an A to B to A checkout cannot borrow a verifier pass" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const verifier_auditor = @import("verifier_auditor.zig");
    const Switch = struct {
        delegate: audit.CompletionAuditor,

        fn run(ptr: *anyopaque, gpa: std.mem.Allocator, request: audit.AuditRequest) audit.CompletionAuditor.Error!audit.AuditVerdict {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // This boundary runs after the runtime confirmed tree A and
            // before the verifier materializes its own checkout.
            writeFile(request.workspace, "feature.txt", "candidate B\n") catch unreachable;
            defer writeFile(request.workspace, feature.path, feature.bytes) catch unreachable;
            return self.delegate.audit(gpa, request);
        }
    };
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-audit-identity");
    defer fx.deinit();
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    var provider: drivers_test.ScriptedProvider = .{ .allocator = testing.allocator, .turns = &.{} };
    defer provider.deinit();
    var permission = permission_mod.createContext(.accept_edits, testing.allocator);
    var verifier: verifier_auditor.VerifierAuditor = .{ .deps = .{
        .provider = provider.provider(),
        .tool_defs = &.{},
        .permission_ctx = &permission,
        .state_root = fx.state(),
    } };
    var swap: Switch = .{ .delegate = verifier.auditor() };
    const run = try runtime.Run.start(testing.allocator, .{
        .preview = .all,
        .seats = seats.source(),
        .auditor = .{ .ptr = &swap, .vtable = &.{ .audit = Switch.run } },
    }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.CompletionResult{ .failed = .audit_unavailable }, try run.requestCompletion());
    try testing.expectEqual(@as(usize, 0), provider.calls);
    try expectFile(run.status().worktree.?, feature.path, feature.bytes);
    try testing.expect(!exists(fx.repo(), feature.path));
}

test "teamwork runtime L2: a verifier PASS cannot complete when its spend is not durable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const verifier_auditor = @import("verifier_auditor.zig");
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-unrecorded");
    defer fx.deinit();
    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    const plans = [_]Plan{
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const turns = [_][]const drivers_test.ScriptedProvider.Event{
        &.{.{ .tool = .{ .name = "Bash", .input = "{\"command\":\"cat feature.txt\"}" } }},
        &.{.{ .text = "REQUIREMENT: feature.txt says feature\nSUBSTITUTE: different content\nPROBE: cat feature.txt\nOBSERVED: feature\nVERDICT: PASS" }},
    };
    var scripted: drivers_test.ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();
    var perm = permission_mod.createContext(.accept_edits, testing.allocator);
    perm.no_interactive_prompt = true;
    var verifier: verifier_auditor.VerifierAuditor = .{ .deps = .{
        .provider = scripted.provider(),
        .tool_defs = try tools_mod.toToolDefinitions(fx.arena.allocator()),
        .permission_ctx = &perm,
        .state_root = fx.state(),
    } };
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    // Simulate a lost ledger mount while keeping the in-memory cap intact.
    const unusable = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/missing/budget.jsonl", .{fx.state()}, 0);
    testing.allocator.free(run.ledger.path);
    run.ledger.path = unusable;
    try testing.expectEqual(runtime.CompletionResult{ .failed = .audit_unavailable }, try run.requestCompletion());
    try testing.expectEqual(@as(usize, 2), scripted.calls);
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "teamwork runtime L2: the isolated verifier audits the result; its FAIL report drives the repair round, its PASS completes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const verifier_auditor = @import("verifier_auditor.zig");
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-rt-verifier");
    defer fx.deinit();
    const a = fx.arena.allocator();
    const plans = [_]Plan{
        // The pinned check only asks for the file; the request asks for its content.
        .{ .seat = "implementer-1", .files = &.{.{ .path = "feature.txt", .bytes = "wrong\n" }} },
        .{ .seat = "reviewer-1", .review = approve_review },
        .{ .seat = "implementer-2", .files = &.{feature} },
        .{ .seat = "reviewer-2", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const Event = drivers_test.ScriptedProvider.Event;
    const probe = "{\"command\":\"cat $WORKSPACE/feature.txt\"}";
    const turns = [_][]const Event{
        // audit 1
        &.{ .{ .tool = .{ .name = "Bash", .input = probe } }, .{ .tool = .{ .name = "Read", .input = "{\"file_path\":\"$WORKSPACE/feature.txt\"}" } } },
        &.{.{ .text = "REQUIREMENT: feature.txt must exist and say \"feature\"\nSUBSTITUTE: a feature.txt with other content\nPROBE: cat $WORKSPACE/feature.txt\nOBSERVED: wrong\nVERDICT: FAIL" }},
        // audit 2
        &.{.{ .tool = .{ .name = "Bash", .input = probe } }},
        &.{.{ .text = "REQUIREMENT: feature.txt must exist and say \"feature\"\nSUBSTITUTE: a feature.txt with other content\nPROBE: cat $WORKSPACE/feature.txt\nOBSERVED: feature\nVERDICT: PASS" }},
    };
    var scripted: drivers_test.ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();
    var perm = permission_mod.createContext(.accept_edits, testing.allocator);
    perm.no_interactive_prompt = true;
    var verifier: verifier_auditor.VerifierAuditor = .{ .deps = .{
        .provider = scripted.provider(),
        .tool_defs = try tools_mod.toToolDefinitions(a),
        .permission_ctx = &perm,
        .state_root = fx.state(),
    } };
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text, .source = .request_file }, try fx.cfg(""), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    if (final.phase() != .done) {
        var report_buf: PathBuf = undefined;
        if (readFile(fx.runFile(&report_buf, ""), "audits/audit-1.md")) |r| {
            defer testing.allocator.free(r);
            std.debug.print("audit-1:\n{s}\n", .{r});
        }
        if (readFile(fx.runFile(&report_buf, ""), "audits/audit-2.md")) |r| {
            defer testing.allocator.free(r);
            std.debug.print("audit-2:\n{s}\n", .{r});
        }
    }
    try testing.expectEqual(runtime.Phase.done, final.phase());
    try testing.expectEqual(@as(usize, 4), scripted.calls);
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    // The verifier's packet is the recorded request, verbatim.
    try testing.expect(std.mem.indexOf(u8, scripted.first_user.?, request_text) != null);
    try testing.expect(std.mem.indexOf(u8, scripted.first_user.?, "path: $WORKSPACE (your working directory)") != null);
    try testing.expect(std.mem.indexOf(u8, scripted.first_user.?, fx.root.slice()) == null);
    var run_buf: PathBuf = undefined;
    const report = readFile(fx.runFile(&run_buf, ""), "audits/audit-1.md") orelse return error.NoReport;
    defer testing.allocator.free(report);
    try testing.expect(std.mem.startsWith(u8, report, "# Completion audit 1: fail\n\nIsolated verifier verdict: FAIL\n"));
    try testing.expect(std.mem.indexOf(u8, report, "  Probe: `cat $WORKSPACE/feature.txt`\n  Observed: wrong\n") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, scripted.tool_results.items, "wrong"));
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-2"), run_dir.seat_relative_first_audit_report) != null);
    // Both audits were charged to the run ledger.
    const ledger_text = readFile(fx.runFile(&run_buf, ""), "budget.jsonl") orelse return error.NoLedger;
    defer testing.allocator.free(ledger_text);
    try testing.expect(std.mem.indexOf(u8, ledger_text, "\"seat_id\":\"verifier-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, ledger_text, "\"seat_id\":\"verifier-2\"") != null);
    try testing.expectEqual(@as(u8, 2), run.status().audit.used);
}

const ScriptedVerdicts = struct {
    decisions: []const interview.Decision,
    calls: usize = 0,

    fn prompter(self: *ScriptedVerdicts) interview.Prompter {
        return .{ .ctx = self, .decideFn = decide };
    }

    fn decide(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!interview.Decision {
        const self: *ScriptedVerdicts = @ptrCast(@alignCast(ctx));
        defer self.calls += 1;
        return self.decisions[self.calls];
    }
};

test "teamwork interview L2: no worker before approval, and the edited approval is ORIGINAL_REQUEST byte for byte" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-interview");
    defer fx.deinit();
    const draft_handoff = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nAdd feature.txt.\n## Verification\ntest -f feature.txt\n";
    const plans = [_]Plan{
        .{ .seat = "interviewer-1", .handoff = draft_handoff, .charge_usd = 0.25, .files = &.{.{ .path = "scratch.txt", .bytes = "scratch\n" }} },
        .{ .seat = "implementer-1", .files = &.{feature} },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const cfg = try fx.cfg("");
    var abort = types.AbortSignal.init();
    var deps: runtime.Deps = .{ .seats = seats.source(), .auditor = auditor.auditor() };

    try testing.expectError(error.PreviewDisabled, interview.draft(testing.allocator, deps, cfg, fx.options(), "add a feature\n", &abort));
    try testing.expect(!exists(fx.state(), "teamwork"));
    deps.preview = .all;

    const before = try fx.workspaceBytes();
    defer testing.allocator.free(before);
    var drafted = try interview.draft(testing.allocator, deps, cfg, fx.options(), "add a feature\n", &abort);
    defer drafted.deinit(testing.allocator);
    try testing.expectEqualStrings("Add feature.txt.\n\n## Acceptance checks\n\ntest -f feature.txt\n", drafted.text);
    try testing.expectEqual(@as(usize, 1), seats.ran.items.len);
    const packet = seats.packetOf("interviewer-1");
    try testing.expect(std.mem.indexOf(u8, packet, run_id_text) == null);
    try testing.expect(std.mem.indexOf(u8, packet, fx.root.slice()) == null);
    try testing.expect(std.mem.endsWith(u8, packet, "## Request\n\nadd a feature\n"));
    const after = try fx.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(!exists(fx.state(), "teamwork/" ++ run_id_text ++ "/ORIGINAL_REQUEST.md"));
    try testing.expect(!exists(fx.state(), "teamwork/" ++ run_id_text ++ "/worktree"));
    try testing.expect(!exists(fx.state(), "teamwork/" ++ run_id_text ++ "/interview"));
    try testing.expect(!exists(fx.state(), "teamwork/" ++ run_id_text ++ "/run.json"));

    var rejecting: ScriptedVerdicts = .{ .decisions = &.{ .{ .edit = "something else" }, .reject } };
    try testing.expect(try interview.approve(drafted.text, .interview, "terms", rejecting.prompter()) == null);
    try testing.expectEqual(@as(usize, 1), seats.ran.items.len);

    const edited = "Add feature.txt containing \"feature\".\r\nKeep README.md as it is.  \n";
    var editing: ScriptedVerdicts = .{ .decisions = &.{ .{ .edit = edited }, .approve } };
    const approved = (try interview.approve(drafted.text, .interview, "terms", editing.prompter())).?;
    try testing.expectEqual(runtime.RequestSource.user_edited, approved.source);
    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = approved.text, .source = approved.source }, cfg, fx.options());
    defer run.destroy();
    try expectFile(fx.state(), "teamwork/" ++ run_id_text ++ "/ORIGINAL_REQUEST.md", edited);
    try testing.expectEqual(@as(f64, 0.25), run.ledger.spent_usd);
    const saved = readFile(fx.state(), "teamwork/" ++ run_id_text ++ "/run.json") orelse return error.FileMissing;
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"request_source\":\"user_edited\"") != null);

    const final = try swe_loop.drive(run);
    try testing.expectEqual(runtime.Phase.done, final.phase());
    try testing.expectEqual(@as(usize, 3), seats.ran.items.len);
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try testing.expect(!exists(fx.repo(), "scratch.txt"));
}

test "teamwork interview L2: a skip-interview request is recorded as such and survives reopen" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-skip-interview");
    defer fx.deinit();
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const cfg = try fx.cfg("");
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const segments = try interview.parseSegments(fx.arena.allocator(), "[skip-interview] " ++ request_text);
    try testing.expect(segments.skip_interview);
    {
        const run = try runtime.Run.start(testing.allocator, deps, .{ .text = segments.request, .source = .skip_interview }, cfg, fx.options());
        defer run.destroy();
    }
    try expectFile(fx.state(), "teamwork/" ++ run_id_text ++ "/ORIGINAL_REQUEST.md", request_text);
    const run = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), types.RunId.parse(run_id_text) catch unreachable);
    defer run.destroy();
    try testing.expectEqual(runtime.RequestSource.skip_interview, run.request_source);
    try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
}

const Recorder = struct {
    text: std.ArrayList(u8) = .empty,
    board: progress.Board = .init(testing.allocator),

    fn deinit(self: *Recorder) void {
        self.text.deinit(testing.allocator);
        self.board.deinit();
    }

    fn observer(self: *Recorder) progress.Observer {
        return .{ .ctx = self, .notifyFn = notify };
    }

    fn notify(ctx: *anyopaque, event: *const progress.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var out: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &self.text);
        defer self.text = out.toArrayList();
        const w = &out.writer;
        const snapshot = event.snapshot;
        switch (event.change) {
            .seat => |seat| w.print("{s} {s}>{s}", .{ seat.id.slice(), if (seat.from) |from| from.name() else "-", seat.to.name() }) catch unreachable,
            .phase => |phase| w.print("phase {s}>{s}", .{ @tagName(phase.from), @tagName(phase.to) }) catch unreachable,
        }
        w.print(" @{s} {d}/{d}\n", .{ @tagName(snapshot.phase), snapshot.seatsDone(), snapshot.seats.len }) catch unreachable;
        self.board.observer().notify(event);
    }
};

test "teamwork progress L2: the host observer gets every seat and phase change, the interviewer waits as needs_you" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-progress");
    defer fx.deinit();
    const draft_handoff = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nAdd feature.txt.\n## Verification\ntest -f feature.txt\n";
    const plans = [_]Plan{
        .{ .seat = "interviewer-1", .handoff = draft_handoff, .charge_usd = 0.25 },
        .{ .seat = "implementer-1", .files = &.{feature}, .charge_usd = 0.5 },
        .{ .seat = "reviewer-1", .review = approve_review },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const cfg = try fx.cfg("");
    var abort = types.AbortSignal.init();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor(), .observer = recorder.observer() };

    var drafted = try interview.draft(testing.allocator, deps, cfg, fx.options(), "add a feature\n", &abort);
    defer drafted.deinit(testing.allocator);
    var dir = try run_dir.RunDir.open(testing.allocator, fx.state(), fx.options().run_id);
    defer dir.deinit(testing.allocator);
    const interviewer = types.SeatId.parse(interview.interviewer_seat) catch unreachable;
    try testing.expectEqual(types.SeatStatus.needs_you, (try dir.readSeatRecord(interviewer)).status);
    {
        var waiting = (try recorder.board.read(testing.allocator)).?;
        defer waiting.deinit();
        try testing.expectEqual(progress.Phase.interviewing, waiting.snapshot().phase);
        try testing.expectEqualStrings("add a feature", waiting.snapshot().goal);
        try testing.expectEqual(@as(f64, 0.25), waiting.snapshot().budget.spent_usd);
    }
    try interview.finishApproval(testing.allocator, deps, cfg, fx.options(), "add a feature\n");
    try testing.expectEqual(types.SeatStatus.done, (try dir.readSeatRecord(interviewer)).status);

    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = drafted.text, .source = .interview }, cfg, fx.options());
    defer run.destroy();
    try testing.expectEqual(runtime.Phase.done, (try swe_loop.drive(run)).phase());
    try testing.expectEqualStrings(
        \\interviewer-1 ->queued @interviewing 0/1
        \\interviewer-1 queued>working @interviewing 0/1
        \\interviewer-1 working>needs_you @interviewing 0/1
        \\interviewer-1 needs_you>done @interviewing 1/1
        \\implementer-1 ->queued @approved 0/1
        \\phase approved>implementing @implementing 0/1
        \\implementer-1 queued>working @implementing 0/1
        \\implementer-1 working>done @implementing 1/1
        \\phase implementing>reviewing @reviewing 1/1
        \\reviewer-1 ->queued @reviewing 1/2
        \\reviewer-1 queued>working @reviewing 1/2
        \\reviewer-1 working>done @reviewing 2/2
        \\phase reviewing>review_approved @review_approved 2/2
        \\phase review_approved>auditing @auditing 2/2
        \\phase auditing>merging @merging 2/2
        \\phase merging>done @done 2/2
        \\
    , recorder.text.items);
    var final = (try recorder.board.read(testing.allocator)).?;
    defer final.deinit();
    try testing.expectEqual(progress.Phase.done, final.snapshot().phase);
    try testing.expectEqual(@as(f64, 0.75), final.snapshot().budget.spent_usd);
    try testing.expectEqualStrings("Add feature.txt.", final.snapshot().goal);
}

test "teamwork progress L2: an interview that spends the budget never leaves its seat waiting on the user" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-progress-budget");
    defer fx.deinit();
    const plans = [_]Plan{.{ .seat = "interviewer-1", .charge_usd = 1 }};
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    var auditor: audit.StubAuditor = .{ .script = &.{}, .gpa = testing.allocator };
    defer auditor.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const cfg = try fx.cfg(",\"budget_usd\":1");
    var abort = types.AbortSignal.init();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor(), .observer = recorder.observer() };
    var drafted = try interview.draft(testing.allocator, deps, cfg, fx.options(), "add a feature\n", &abort);
    defer drafted.deinit(testing.allocator);
    try testing.expect(drafted == .budget_exhausted);
    var dir = try run_dir.RunDir.open(testing.allocator, fx.state(), fx.options().run_id);
    defer dir.deinit(testing.allocator);
    try testing.expectEqual(types.SeatStatus.done, (try dir.readSeatRecord(types.SeatId.parse(interview.interviewer_seat) catch unreachable)).status);
    try testing.expect(std.mem.indexOf(u8, recorder.text.items, "needs_you") == null);
}

const hidden_check = "sh hidden-test.sh";
const hidden_test = File{ .path = "hidden-test.sh", .bytes = "grep -qx feature feature.txt\n" };
const approve_hidden = "{\"verdict\":\"approve\",\"evidence\":[{\"command\":\"" ++ hidden_check ++ "\",\"exit_code\":0,\"output_digest\":\"" ++ digest ++ "\",\"output_excerpt\":\"\"}],\"issues\":{\"opened\":[],\"closed\":[],\"still_open\":[]}}";

fn candidatesCfg(fx: *Fixture, extra: []const u8) !config.Config.Enabled {
    const a = fx.arena.allocator();
    const text = try std.fmt.allocPrint(a, "{{\"enabled\":true,\"budget_usd\":5,\"check_command\":\"{s}\"{s}}}", .{ hidden_check, extra });
    return (try config.validate(try config.parse(a, text, null), null)).enabled;
}

fn judgment(comptime selected: []const u8, comptime others: [2][]const u8) File {
    return .{ .path = "judgment.json", .bytes = "{\"selected\":\"" ++ selected ++ "\",\"eliminated\":[{\"candidate\":\"" ++ others[0] ++ "\",\"reason\":\"It fails the hidden test.\"},{\"candidate\":\"" ++ others[1] ++ "\",\"reason\":\"It changes the wrong file.\"}]}" };
}

const Pitfalls = struct {
    texts: std.ArrayList([]u8) = .empty,

    fn sink(self: *Pitfalls) runtime.PitfallSink {
        return .{ .ctx = self, .rememberFn = remember };
    }

    fn remember(ctx: *anyopaque, text: []const u8) bool {
        const self: *Pitfalls = @ptrCast(@alignCast(ctx));
        const copy = testing.allocator.dupe(u8, text) catch return false;
        self.texts.append(testing.allocator, copy) catch {
            testing.allocator.free(copy);
            return false;
        };
        return true;
    }

    fn deinit(self: *Pitfalls) void {
        for (self.texts.items) |text| testing.allocator.free(text);
        self.texts.deinit(testing.allocator);
    }
};

const three_candidates = [_]Plan{
    .{ .seat = "implementer-1", .require = "hidden-test.sh", .files = &.{.{ .path = "feature.txt", .bytes = "wrong\n" }} },
    .{ .seat = "reviewer-1", .review = approve_hidden },
    .{ .seat = "implementer-2", .require = "hidden-test.sh", .files = &.{feature} },
    .{ .seat = "reviewer-2", .review = approve_hidden },
    .{ .seat = "implementer-3", .files = &.{.{ .path = "other.txt", .bytes = "feature\n" }} },
    .{ .seat = "reviewer-3", .review = approve_hidden },
};

test "teamwork candidates L2: of three candidates only the one passing the hidden test is judged eligible, selected and merged back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-candidates");
    defer fx.deinit();
    try writeFile(fx.repo(), hidden_test.path, hidden_test.bytes);
    const plans = three_candidates ++ [_]Plan{
        .{ .seat = "judge-1", .require = "candidate-2.diff", .seat_files = &.{judgment("candidate-2", .{ "candidate-1", "candidate-3" })} },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    var pitfalls: Pitfalls = .{};
    defer pitfalls.deinit();
    const cfg = try candidatesCfg(&fx, ",\"candidates\":3,\"candidate_estimate_usd\":1");
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor(), .pitfalls = pitfalls.sink() };

    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
    try testing.expect(run.status().worktree == null);
    try testing.expectError(error.CandidatesPending, run.dispatch(.implementer, ""));
    try testing.expectEqual(runtime.CandidatesResult{ .selected = 2 }, try run.runCandidates());
    const statuses = [_]runtime.CandidateStatus{ .rejected, .selected, .rejected };
    for (run.status().candidates, statuses) |candidate, want| try testing.expectEqual(want, candidate.status);
    var ids_buf: [512]u8 = undefined;
    try testing.expectEqualStrings("implementer-1:done,reviewer-1:done,implementer-2:done,reviewer-2:done,implementer-3:done,reviewer-3:done,judge-1:done", seatIds(run.status(), &ids_buf));
    try testing.expectEqual(runtime.Phase.review_approved, run.status().state.phase());
    try testing.expect(std.mem.endsWith(u8, run.status().worktree.?, "/candidates/candidate-2"));
    try expectFile(run.status().worktree.?, "feature.txt", "feature\n");
    var root_buf: PathBuf = undefined;
    const root = fx.runFile(&root_buf, "");
    try testing.expect(!exists(root, "candidates/candidate-1"));
    try testing.expect(!exists(root, "candidates/candidate-3"));
    try testing.expect(!exists(root, "judging/candidate-1.diff"));

    const judge_packet = seats.packetOf("judge-1");
    try testing.expect(std.mem.indexOf(u8, judge_packet, "- `candidate-1` was not approved: the review did not hold up (check_disagrees). Not eligible.") != null);
    try testing.expect(std.mem.indexOf(u8, judge_packet, "- `candidate-2` passed its verified review. Eligible.") != null);
    try testing.expect(std.mem.indexOf(u8, judge_packet, "- `candidate-3` was not approved: the review did not hold up (check_disagrees). Not eligible.") != null);
    try expectCacheSafe(&fx, &seats);

    try testing.expectEqual(@as(usize, 2), pitfalls.texts.items.len);
    var binding: lesson.Binding = .{ .verdict = .failed, .task = lesson.NO_TASK, .run = run_id_text };
    for (pitfalls.texts.items) |text| try lesson.checkBinding(try lesson.parse(text), &binding);
    try testing.expect(std.mem.indexOf(u8, pitfalls.texts.items[0], "lesson: candidate-1 lost to candidate-2: It fails the hidden test.") != null);
    try testing.expect(std.mem.indexOf(u8, pitfalls.texts.items[1], "lesson: candidate-3 lost to candidate-2: It changes the wrong file.") != null);

    run.destroy();
    const reopened = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id);
    defer reopened.destroy();
    try testing.expect(std.mem.endsWith(u8, reopened.status().worktree.?, "/candidates/candidate-2"));
    try testing.expectEqual(runtime.CandidateStatus.selected, reopened.status().candidates[1].status);
    const final = try swe_loop.drive(reopened);
    try testing.expectEqual(runtime.State{ .done = .{ .files_changed = 1, .worktree_removed = true } }, final);
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try testing.expect(!exists(fx.repo(), "other.txt"));
    try testing.expect(std.mem.endsWith(u8, auditor.last_workspace.?, "/candidates/candidate-2"));
    const worktrees = try sh(fx.repo(), "git worktree list --porcelain | grep -c '^worktree '");
    defer testing.allocator.free(worktrees);
    try testing.expectEqualStrings("1\n", worktrees);
}

test "teamwork candidates L2: an invalid judgment runs the judge again; no approved candidate fails without a judge" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-candidates-judge");
    defer fx.deinit();
    try writeFile(fx.repo(), hidden_test.path, hidden_test.bytes);
    const plans = three_candidates ++ [_]Plan{
        .{ .seat = "judge-1", .seat_files = &.{judgment("candidate-1", .{ "candidate-2", "candidate-3" })} },
        .{ .seat = "judge-2", .seat_files = &.{judgment("candidate-2", .{ "candidate-3", "candidate-1" })} },
    };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try candidatesCfg(&fx, ",\"candidates\":3,\"candidate_estimate_usd\":1"), fx.options());
    defer run.destroy();
    try testing.expectEqual(runtime.CandidatesResult{ .selected = 2 }, try run.runCandidates());
    const seats_now = run.status().seats;
    try testing.expectEqual(runtime.SeatResult{ .judgment = .{ .invalid = error.NotEligible } }, seats_now[seats_now.len - 2].result.?);
    try testing.expectEqual(runtime.SeatResult{ .judgment = .{ .selected = 2 } }, seats_now[seats_now.len - 1].result.?);
    try testing.expectError(error.NoCandidates, run.runCandidates());

    var none: Fixture = undefined;
    try none.init("cc-zig-teamwork-candidates-none");
    defer none.deinit();
    try writeFile(none.repo(), hidden_test.path, hidden_test.bytes);
    const failing = [_]Plan{
        .{ .seat = "implementer-1", .fail = .{ .exited = 3 } },
        .{ .seat = "implementer-2", .files = &.{.{ .path = "feature.txt", .bytes = "wrong\n" }} },
        .{ .seat = "reviewer-1", .review = approve_hidden },
    };
    var none_seats: ScriptedSeats = .{ .plans = &failing, .user_repo = none.repo() };
    defer none_seats.deinit();
    const before = try none.workspaceBytes();
    defer testing.allocator.free(before);
    const lost = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = none_seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try candidatesCfg(&none, ",\"candidates\":2,\"candidate_estimate_usd\":1"), none.options());
    defer lost.destroy();
    try testing.expectEqual(runtime.State{ .failed = .no_candidate_approved }, try swe_loop.drive(lost));
    try testing.expectEqual(runtime.CandidateStatus.rejected, lost.status().candidates[0].status);
    try testing.expectEqual(runtime.CandidateStatus.rejected, lost.status().candidates[1].status);
    try testing.expectEqual(@as(usize, 3), none_seats.ran.items.len);
    const after = try none.workspaceBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "teamwork candidates L2: a start whose candidate estimate exceeds the budget left is refused before anything runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-candidates-budget");
    defer fx.deinit();
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const request: runtime.ApprovedRequest = .{ .text = request_text, .source = .request_file };

    try testing.expectError(error.CandidateBudgetExceeded, runtime.Run.start(testing.allocator, deps, request, try candidatesCfg(&fx, ",\"candidates\":3,\"candidate_estimate_usd\":2"), fx.options()));
    var root_buf: PathBuf = undefined;
    const root = fx.runFile(&root_buf, "");
    try testing.expect(!exists(root, "run.json"));
    try testing.expect(!exists(root, run_dir.original_request_file));

    var ledger_buf: PathBuf = undefined;
    const ledger_path = fx.runFile(&ledger_buf, run_dir.budget_file);
    try util_fs.mkdirParents(std.fs.path.dirname(ledger_path).?);
    var spent = try ledger_mod.Ledger.load(testing.allocator, ledger_path, 5);
    try spent.charge(.{ .seat_id = types.seatIdFor(.interviewer, 1), .harness = .metacodes, .wallclock_ms = 1, .cost = .{ .provider_estimate = 3 } });
    spent.deinit(testing.allocator);
    try testing.expectError(error.CandidateBudgetExceeded, runtime.Run.start(testing.allocator, deps, request, try candidatesCfg(&fx, ",\"candidates\":3,\"candidate_estimate_usd\":0.8"), fx.options()));
    try testing.expect(!exists(root, "run.json"));
    const run = try runtime.Run.start(testing.allocator, deps, request, try candidatesCfg(&fx, ",\"candidates\":3,\"candidate_estimate_usd\":0.6"), fx.options());
    defer run.destroy();
    try testing.expectEqual(runtime.Phase.approved, run.status().state.phase());
    try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
}

const manager_allowance = "1.5";

const mcp_initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fake-manager\",\"version\":\"1\"}}}";
const mcp_initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";

fn mcpCall(comptime id: []const u8, comptime name: []const u8, comptime arguments: []const u8) []const u8 {
    return "{\"jsonrpc\":\"2.0\",\"id\":" ++ id ++ ",\"method\":\"tools/call\",\"params\":{\"name\":\"" ++ name ++ "\",\"arguments\":" ++ arguments ++ "}}";
}

const FakeManager = struct {
    command_buf: PathBuf = undefined,
    command_len: usize = 0,

    const Ending = enum { reports_cost, runs_until_stopped, hangs };

    fn command(self: *const FakeManager) []const u8 {
        return self.command_buf[0..self.command_len];
    }

    fn install(self: *FakeManager, fx: *const Fixture, requests: []const []const u8, replies: usize, ending: Ending) !void {
        const a = testing.allocator;
        self.command_len = (try std.fmt.bufPrint(&self.command_buf, "{s}/bin/claude-manager", .{fx.root.slice()})).len;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        var run_buf: PathBuf = undefined;
        const run_root = fx.runFile(&run_buf, "");
        try text.print(a,
            \\#!/bin/sh
            \\case "$1" in
            \\--version) echo '2.1.323 (Claude Code)'; exit 0 ;;
            \\--help) echo '--print --output-format stream-json --verbose --add-dir --permission-mode acceptEdits --permission-prompts --no-session-persistence --model --effort --max-budget-usd --append-system-prompt --strict-mcp-config --mcp-config --allowedTools'; exit 0 ;;
            \\esac
            \\printf '%s\n' "$@" > argv.txt
            \\pwd -P > cwd.txt
            \\for target in '{0s}ORIGINAL_REQUEST.md' '{0s}budget.jsonl' '{0s}run.json' '{0s}worktree/README.md' '{1s}/README.md'; do
            \\  if printf tampered >> "$target" 2>/dev/null; then echo "$target" >> breach.txt; fi
            \\done
            \\cfg=''
            \\prev=''
            \\for a in "$@"; do
            \\  if [ "$prev" = "--mcp-config" ]; then cfg="$a"; fi
            \\  prev="$a"
            \\done
            \\set -- $(printf '%s' "$cfg" | sed 's/.*"args":\["\([^"]*\)","\([^"]*\)","\([^"]*\)"\].*/\1 \2 \3/')
            \\: > responses
            \\
        , .{ run_root, fx.repo() });
        switch (ending) {
            .reports_cost, .runs_until_stopped => {
                try text.appendSlice(a, "{\n  cat <<'REQUESTS'\n");
                for (requests) |line| try text.print(a, "{s}\n", .{line});
                try text.print(a, "REQUESTS\n  while [ \"$(wc -l < responses)\" -lt {d} ]; do sleep 0.05; done\n", .{replies});
                if (ending == .runs_until_stopped) try text.appendSlice(a, "  sleep 10\n");
                try text.appendSlice(a, "} | /bin/sh \"$1\" \"$2\" \"$3\" > responses\n");
                try text.appendSlice(a, "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.3}'\nexit 0\n");
            },
            .hangs => try text.appendSlice(a, "touch ready\nsleep 300\n"),
        }
        var bin_buf: PathBuf = undefined;
        try util_fs.mkdirParents(try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{fx.root.slice()}));
        try writeFile(fx.root.slice(), "bin/claude-manager", text.items);
        var path_buf: PathBuf = undefined;
        if (pfs.chmod(try std.fmt.bufPrintZ(&path_buf, "{s}", .{self.command()}), 0o755) != 0) return error.ChmodFailed;
    }
};

fn managerCfg(fx: *Fixture, fake: *const FakeManager, implementer: []const u8) !config.Config.Enabled {
    const extra = try std.fmt.allocPrint(fx.arena.allocator(), ",\"budget_usd\":5,\"manager_budget_usd\":" ++ manager_allowance ++ ",\"seats\":{{\"manager\":{{\"harness\":\"claude_code\",\"command\":\"{s}\"}}{s}}}", .{ fake.command(), implementer });
    return fx.cfg(extra);
}

fn managerOptions(fx: *Fixture) !claude_code.Options {
    const a = fx.arena.allocator();
    const home = try std.fmt.allocPrint(a, "{s}/home", .{fx.root.slice()});
    try util_fs.mkdirParents(home);
    const env = try a.alloc([:0]const u8, 3);
    env[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home}, 0);
    env[1] = "PATH=/usr/bin:/bin";
    env[2] = "ANTHROPIC_API_KEY=sk-ant-secret";
    return .{ .preview = .all, .parent_env = env, .home_dir = home };
}

fn managerFile(fx: *const Fixture, seat: []const u8, rel: []const u8) ?[]u8 {
    var buf: PathBuf = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/teamwork/{s}/seats/{s}", .{ fx.state(), run_id_text, seat }) catch return null;
    return readFile(dir, rel);
}

fn replyFor(responses: []const u8, comptime id: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, responses, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"id\":" ++ id ++ ",") != null) return line;
    }
    return "";
}

fn ledgerHas(fx: *const Fixture, line: []const u8) bool {
    var buf: PathBuf = undefined;
    const budget = readFile(fx.runFile(&buf, ""), "budget.jsonl") orelse return false;
    defer testing.allocator.free(budget);
    return std.mem.indexOf(u8, budget, line) != null;
}

test "teamwork manager L2: a launched manager drives the run over real MCP requests, inside its sandbox, on the run's budget" {
    if (builtin.os.tag == .windows or !sandbox_exec.hostSupported()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-manager-mcp");
    defer fx.deinit();
    const requests = [_][]const u8{
        mcp_initialize,
        mcp_initialized,
        mcpCall("2", "teamwork_request_completion", "{}"),
        mcpCall("3", "teamwork_dispatch", "{\"role\":\"implementer\",\"instructions\":\"see " ++ run_id_text ++ "\"}"),
        mcpCall("4", "teamwork_dispatch", "{\"role\":\"implementer\",\"instructions\":\"Write feature.txt.\"}"),
        mcpCall("5", "teamwork_dispatch", "{\"role\":\"reviewer\"}"),
        mcpCall("6", "teamwork_request_completion", "{}"),
    };
    var fake: FakeManager = .{};
    try fake.install(&fx, &requests, 6, .reports_cost);
    const plans = [_]Plan{ .{ .seat = "implementer-1", .files = &.{feature}, .charge_usd = 0.5 }, .{ .seat = "reviewer-1", .review = approve_review } };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();

    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try managerCfg(&fx, &fake, ""), fx.options());
    defer run.destroy();
    const final = try manager.drive(run, try managerOptions(&fx));

    try testing.expectEqual(runtime.Phase.done, final.phase());
    try expectFile(fx.repo(), "feature.txt", "feature\n");
    try expectFile(fx.repo(), "README.md", "readme\n");
    var run_buf: PathBuf = undefined;
    try expectFile(fx.runFile(&run_buf, ""), "ORIGINAL_REQUEST.md", request_text);
    if (managerFile(&fx, "manager-1", "breach.txt")) |breach| {
        defer testing.allocator.free(breach);
        std.debug.print("manager wrote outside its seat: {s}\n", .{breach});
        return error.ManagerEscapedSandbox;
    }

    const responses = managerFile(&fx, "manager-1", "responses") orelse return error.NoResponses;
    defer testing.allocator.free(responses);
    try testing.expect(std.mem.indexOf(u8, replyFor(responses, "2"), "\"error\":\"NotApproved\"") != null);
    try testing.expect(std.mem.indexOf(u8, replyFor(responses, "3"), "\"error\":\"InstructionsNameRunState\"") != null);
    try testing.expect(std.mem.indexOf(u8, replyFor(responses, "4"), "\"seat_id\":\"implementer-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, replyFor(responses, "6"), "\"outcome\":{\"kind\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, replyFor(responses, "6"), "\"held_usd\":" ++ manager_allowance ++ ",\"manager\":\"run_ledger\"") != null);

    const argv = managerFile(&fx, "manager-1", "argv.txt") orelse return error.NoArgv;
    defer testing.allocator.free(argv);
    for ([_][]const u8{ "--permission-mode\n", "default\n", "--max-budget-usd\n", "1.500000\n", "--allowedTools\n", "mcp__teamwork\n", "--strict-mcp-config\n" }) |want| {
        try testing.expect(std.mem.indexOf(u8, argv, want) != null);
    }
    try testing.expect(std.mem.indexOf(u8, argv, "--add-dir") == null);
    try testing.expect(std.mem.indexOf(u8, argv, "sk-ant-secret") == null);
    try testing.expect(std.mem.indexOf(u8, argv, run_id_text ++ "/worktree") == null);

    try testing.expectEqual(@as(f64, 3.5), seats.ran.items[0].remaining_usd);
    try testing.expectEqual(types.Harness.metacodes, seats.ran.items[0].harness);
    try testing.expect(ledgerHas(&fx, "{\"seat_id\":\"manager-1\",\"harness\":\"claude_code\",\"usd\":0.3,"));
    const snapshot = run.status();
    try testing.expectEqual(@as(f64, 0), snapshot.budget.held_usd);
    try testing.expectApproxEqAbs(@as(f64, 0.8), snapshot.budget.spent_usd, 1e-9);
    try testing.expectEqual(runtime.ManagerSpend.run_ledger, snapshot.budget.manager);
    var ids_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("manager-1:done,implementer-1:done,reviewer-1:done", seatIds(snapshot, &ids_buf));
    try testing.expect(!exists(fx.runFile(&run_buf, ""), "budget.jsonl.hold"));
}

test "teamwork manager L2: the manager and worker harnesses switch independently" {
    if (builtin.os.tag == .windows or !sandbox_exec.hostSupported()) return error.SkipZigTest;
    for ([_]bool{ true, false }) |launched| {
        var fx: Fixture = undefined;
        try fx.init("cc-zig-teamwork-manager-switch");
        defer fx.deinit();
        const requests = [_][]const u8{
            mcp_initialize,
            mcp_initialized,
            mcpCall("2", "teamwork_dispatch", "{\"role\":\"implementer\"}"),
            mcpCall("3", "teamwork_dispatch", "{\"role\":\"reviewer\"}"),
            mcpCall("4", "teamwork_request_completion", "{}"),
        };
        var fake: FakeManager = .{};
        try fake.install(&fx, &requests, 4, .reports_cost);
        const plans = [_]Plan{ .{ .seat = "implementer-1", .files = &.{feature} }, .{ .seat = "reviewer-1", .review = approve_review } };
        var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
        defer seats.deinit();
        const script = [_]audit.StubAuditor.Scripted{.pass};
        var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
        defer auditor.deinit();
        const claude_implementer = try std.fmt.allocPrint(fx.arena.allocator(), ",\"implementer\":{{\"harness\":\"claude_code\",\"command\":\"{s}/bin/claude\"}}", .{fx.root.slice()});
        const cfg = if (launched)
            try managerCfg(&fx, &fake, claude_implementer)
        else
            try fx.cfg(try std.fmt.allocPrint(fx.arena.allocator(), ",\"seats\":{{{s}}}", .{claude_implementer[1..]}));
        const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
        defer run.destroy();
        try testing.expectEqual(runtime.Phase.done, (try manager.drive(run, try managerOptions(&fx))).phase());
        try testing.expectEqual(types.Harness.claude_code, seats.ran.items[0].harness);
        var ids_buf: [256]u8 = undefined;
        if (launched) {
            try testing.expectEqualStrings("manager-1:done,implementer-1:done,reviewer-1:done", seatIds(run.status(), &ids_buf));
            const argv = managerFile(&fx, "manager-1", "argv.txt") orelse return error.NoArgv;
            testing.allocator.free(argv);
        } else {
            try testing.expectEqualStrings("implementer-1:done,reviewer-1:done", seatIds(run.status(), &ids_buf));
            try testing.expect(managerFile(&fx, "manager-1", "argv.txt") == null);
            try testing.expectEqual(runtime.ManagerSpend.none, run.status().budget.manager);
        }
    }
}

test "teamwork manager L2: an exhausted budget stops the manager and the workers and merges nothing" {
    if (builtin.os.tag == .windows or !sandbox_exec.hostSupported()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-manager-budget");
    defer fx.deinit();
    const requests = [_][]const u8{
        mcp_initialize,
        mcp_initialized,
        mcpCall("2", "teamwork_dispatch", "{\"role\":\"implementer\"}"),
        mcpCall("3", "teamwork_dispatch", "{\"role\":\"reviewer\"}"),
    };
    var fake: FakeManager = .{};
    try fake.install(&fx, &requests, 3, .runs_until_stopped);
    const plans = [_]Plan{ .{ .seat = "implementer-1", .files = &.{feature}, .charge_usd = 3.5 }, .{ .seat = "reviewer-1", .review = approve_review } };
    var seats: ScriptedSeats = .{ .plans = &plans, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try managerCfg(&fx, &fake, ""), fx.options());
    defer run.destroy();

    try testing.expectEqual(runtime.Phase.budget_exhausted, (try manager.drive(run, try managerOptions(&fx))).phase());
    try testing.expectEqual(@as(usize, 1), seats.ran.items.len);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    try testing.expect(!exists(fx.repo(), "feature.txt"));
    try testing.expectEqual(runtime.SeatResult.aborted, run.status().seats[0].result.?);
    try testing.expect(ledgerHas(&fx, "{\"seat_id\":\"manager-1\",\"harness\":\"claude_code\",\"usd\":1.5,\"wallclock_ms\":"));
    try testing.expect(ledgerHas(&fx, "\"source\":\"reserved\""));
    try testing.expectEqual(@as(f64, 5), run.status().budget.spent_usd);
}

const AbortWhenReady = struct {
    fn wait(fx: *const Fixture, abort: *types.AbortSignal) void {
        var waited: u32 = 0;
        while (waited < 2000) : (waited += 1) {
            if (managerFile(fx, "manager-1", "ready")) |ready| {
                testing.allocator.free(ready);
                abort.abort(.user_ctrl_c);
                return;
            }
            util_time.sleepMs(10);
        }
    }
};

test "teamwork manager L2: a host cancel kills a busy manager; its unknown spend consumes the hold" {
    if (builtin.os.tag == .windows or !sandbox_exec.hostSupported()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-manager-cancel");
    defer fx.deinit();
    var fake: FakeManager = .{};
    try fake.install(&fx, &.{}, 0, .hangs);
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const run = try runtime.Run.start(testing.allocator, .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text, .source = .request_file }, try managerCfg(&fx, &fake, ""), fx.options());
    defer run.destroy();
    const host = try std.Thread.spawn(.{}, AbortWhenReady.wait, .{ &fx, &run.abort });
    const started = util_time.nowMs();
    const final = try manager.drive(run, try managerOptions(&fx));
    host.join();

    try testing.expectEqual(runtime.Phase.cancelled, final.phase());
    try testing.expect(util_time.nowMs() - started < 60_000);
    try testing.expectEqual(runtime.SeatResult.aborted, run.status().seats[0].result.?);
    try testing.expect(ledgerHas(&fx, "{\"seat_id\":\"manager-1\",\"harness\":\"claude_code\",\"usd\":1.5,"));
    try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
}

test "teamwork manager L2: a crash while the manager runs consumes its hold once; reopening never grants it again" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-manager-crash");
    defer fx.deinit();
    var fake: FakeManager = .{};
    fake.command_len = (try std.fmt.bufPrint(&fake.command_buf, "{s}/bin/claude-manager", .{fx.root.slice()})).len;
    var seats: ScriptedSeats = .{ .plans = &.{}, .user_repo = fx.repo() };
    defer seats.deinit();
    const script = [_]audit.StubAuditor.Scripted{.pass};
    var auditor: audit.StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer auditor.deinit();
    const deps: runtime.Deps = .{ .preview = .all, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try managerCfg(&fx, &fake, "");
    {
        const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text, .source = .request_file }, cfg, fx.options());
        defer run.destroy();
        const id = try run.openManager();
        try run.holdManager(id);
        try testing.expectEqual(@as(f64, 3.5), run.status().budget.remaining_usd);
    }
    for (0..2) |_| {
        const run = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id);
        defer run.destroy();
        const snapshot = run.status();
        try testing.expectEqual(@as(f64, 1.5), snapshot.budget.spent_usd);
        try testing.expectEqual(@as(f64, 0), snapshot.budget.held_usd);
        try testing.expectEqual(@as(f64, 3.5), snapshot.budget.remaining_usd);
        try testing.expectEqual(types.SeatStatus.failed, snapshot.seats[0].status);
    }
    const run = try runtime.Run.reopen(testing.allocator, deps, cfg, fx.state(), fx.options().run_id);
    defer run.destroy();
    const next = try run.openManager();
    try testing.expectEqualStrings("manager-2", next.slice());
    try run.holdManager(next);
    try testing.expectEqual(@as(f64, 2), run.status().budget.remaining_usd);
}

test "teamwork manager L2: the controller's death kills the manager's whole process group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-manager-lifeline");
    defer fx.deinit();
    const pidfile = try std.fmt.allocPrintSentinel(fx.arena.allocator(), "{s}/manager.pid", .{fx.root.slice()}, 0);
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", claude_code.lifeline_script, "teamwork-manager", "/bin/sh", "-c", "sleep 300 & echo $! > \"$0\"; wait", pidfile.ptr, null };
    const child = try pprocess.spawnPipesWith(&argv, .{ .env = &.{"PATH=/usr/bin:/bin"}, .cwd = fx.root.slice() });
    var pid: ?std.c.pid_t = null;
    var waited: u32 = 0;
    while (pid == null and waited < 500) : (waited += 1) {
        if (swarm_team.readFileAlloc(testing.allocator, pidfile)) |text| {
            defer testing.allocator.free(text);
            pid = std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
        }
        if (pid == null) util_time.sleepMs(10);
    }
    const grandchild = pid orelse return error.ManagerNotStarted;
    try testing.expectEqual(@as(c_int, 0), std.c.kill(grandchild, @enumFromInt(0)));
    child.closeStdin();
    var alive = true;
    var reaped = false;
    waited = 0;
    while (alive and waited < 500) : (waited += 1) {
        if (!reaped) reaped = child.tryWait() == .exited;
        alive = std.c.kill(grandchild, @enumFromInt(0)) == 0;
        if (alive) util_time.sleepMs(10);
    }
    child.closeStdout();
    try testing.expect(!alive);
}
