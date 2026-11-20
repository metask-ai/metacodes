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
};

const ScriptedSeats = struct {
    plans: []const Plan,
    user_repo: []const u8,
    binding: common.Binding = undefined,
    /// Seat id and packet bytes of every seat run, in order; owned.
    ran: std.ArrayList(Ran) = .empty,

    const Ran = struct { seat: types.SeatId, packet: []u8 };

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

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: *const types.SeatSpec, paths: types.SeatPaths, abort: *const types.AbortSignal) types.SeatDriver.Error!types.SeatOutcome {
        const self: *ScriptedSeats = @ptrCast(@alignCast(ptr));
        const seat = self.binding.seat;
        const packet = swarm_team.readFileAlloc(testing.allocator, paths.packet) orelse try testing.allocator.dupe(u8, "");
        try self.ran.append(testing.allocator, .{ .seat = seat, .packet = packet });
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
        writeFile(seat_dir, "handoff.md", handoff_text) catch return .{ .failed = .spawn_failed };
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
    try testing.expectError(error.PreviewDisabled, runtime.Run.start(testing.allocator, deps, .{ .text = request_text }, cfg, fx.options()));
    try testing.expect(!exists(fx.state(), "teamwork"));
    try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
    try testing.expectEqual(@as(u32, 0), auditor.calls);
    deps.preview = true;
    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text }, cfg, fx.options());
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
    deps.preview = false;
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
    defer run.destroy();
    _ = try run.dispatch(.implementer, "");
    _ = try run.dispatch(.reviewer, "");
    try testing.expectEqual(runtime.Phase.review_approved, run.status().state.phase());
    run.deps.preview = false;
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

    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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

    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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

    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = unavailable.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(",\"budget_usd\":1"), fx.options());
    defer run.destroy();
    const final = try swe_loop.drive(run);

    try testing.expectEqual(runtime.State.budget_exhausted, final);
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
        const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
        defer run.destroy();
        // Spend recorded elsewhere in the run (an interviewer, say) used it up.
        try testing.expectError(error.BudgetExhausted, run.ledger.charge(.{ .seat_id = try types.SeatId.parse("interviewer-1"), .harness = .metacodes, .wallclock_ms = 0, .cost = .{ .provider_estimate = 5 } }));
        try testing.expectError(error.BudgetExhausted, run.dispatch(.implementer, ""));
        try testing.expectEqual(runtime.State.budget_exhausted, run.state);
        try testing.expectEqual(@as(usize, 0), seats.ran.items.len);
        var recovery = try run.dir.recover(testing.allocator);
        defer recovery.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), recovery.seats.len);
    }
    var other_buf: PathBuf = undefined;
    const other_state = try std.fmt.bufPrint(&other_buf, "{s}/state2", .{fx.root.slice()});
    var options = fx.options();
    options.state_root = other_state;
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), options);
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(",\"max_rounds\":3"), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
        .preview = true,
        .seats = seats.source(),
        .auditor = auditor.auditor(),
        .cli_approval = .{ .config_json = "{\"enabled\":true,\"budget_usd\":5}", .host_sha256 = @splat(0) },
    };
    const cfg = try fx.cfg("");
    const run = try runtime.Run.start(gpa, deps, .{ .text = request_text }, cfg, opts);
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
        .preview = true,
        .seats = seats.source(),
        .auditor = auditor.auditor(),
        .recheck_audited_tree = Recheck.abortRead,
    }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const deps: runtime.Deps = .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg("");
    const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text }, cfg, fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const deps: runtime.Deps = .{ .preview = true, .seats = seats.source(), .auditor = auditor.auditor() };
    const cfg = try fx.cfg("");
    {
        const run = try runtime.Run.start(testing.allocator, deps, .{ .text = request_text }, cfg, fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = .{ .harness = seat_deps }, .auditor = auditor.auditor() }, .{ .text = request_text }, cfg, fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = .{ .harness = seat_deps }, .auditor = auditor.auditor() }, .{ .text = request_text }, cfg, fx.options());
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
            const run = try runtime.Run.start(gpa, .{ .preview = true, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
        .preview = true,
        .seats = seats.source(),
        .auditor = .{ .ptr = &swap, .vtable = &.{ .audit = Switch.run } },
    }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    const probe = "{\"command\":\"cat feature.txt\"}";
    const turns = [_][]const Event{
        // audit 1
        &.{.{ .tool = .{ .name = "Bash", .input = probe } }},
        &.{.{ .text = "REQUIREMENT: feature.txt must exist and say \"feature\"\nSUBSTITUTE: a feature.txt with other content\nPROBE: cat feature.txt\nOBSERVED: wrong\nVERDICT: FAIL" }},
        // audit 2
        &.{.{ .tool = .{ .name = "Bash", .input = probe } }},
        &.{.{ .text = "REQUIREMENT: feature.txt must exist and say \"feature\"\nSUBSTITUTE: a feature.txt with other content\nPROBE: cat feature.txt\nOBSERVED: feature\nVERDICT: PASS" }},
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
    const run = try runtime.Run.start(testing.allocator, .{ .preview = true, .seats = seats.source(), .auditor = verifier.auditor() }, .{ .text = request_text }, try fx.cfg(""), fx.options());
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
    try testing.expect(std.mem.indexOf(u8, scripted.first_user.?, "path: . (your working directory)") != null);
    try testing.expect(std.mem.indexOf(u8, scripted.first_user.?, fx.root.slice()) == null);
    var run_buf: PathBuf = undefined;
    const report = readFile(fx.runFile(&run_buf, ""), "audits/audit-1.md") orelse return error.NoReport;
    defer testing.allocator.free(report);
    try testing.expect(std.mem.startsWith(u8, report, "# Completion audit 1: fail\n\nIsolated verifier verdict: FAIL\n"));
    try testing.expect(std.mem.indexOf(u8, report, "  Probe: `cat feature.txt`\n  Observed: wrong\n") != null);
    try testing.expect(std.mem.indexOf(u8, seats.packetOf("implementer-2"), run_dir.seat_relative_first_audit_report) != null);
    // Both audits were charged to the run ledger.
    const ledger_text = readFile(fx.runFile(&run_buf, ""), "budget.jsonl") orelse return error.NoLedger;
    defer testing.allocator.free(ledger_text);
    try testing.expect(std.mem.indexOf(u8, ledger_text, "\"seat_id\":\"verifier-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, ledger_text, "\"seat_id\":\"verifier-2\"") != null);
    try testing.expectEqual(@as(u8, 2), run.status().audit.used);
}
