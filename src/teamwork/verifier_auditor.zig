//! The completion auditor backed by the isolated verifier (#516,
//! `core/isolated_verifier.zig`): the adapter audit.zig names.
//!
//! One audit:
//!
//! 1. The pinned `check_command`, if configured, is re-run in the approved snapshot
//!    (`reviewer.CheckRunner`, sandboxed like the Bash tool). A failing check
//!    is an audit `fail` without spawning the verifier; a check that cannot
//!    run is `unavailable`.
//! 2. `isolated_verifier.verify` judges that snapshot of the worktree
//!    against `ORIGINAL_REQUEST.md`, with `base` = the worktree's base commit,
//!    so `git diff base candidate` is exactly the run's change. Its cost cap is
//!    the smaller of the verifier's own and what is left of the run budget.
//! 3. The spend is charged to the run ledger as `verifier-<attempt>`.
//! 4. The outcome maps one to one: `pass` → pass, `fail` → fail (its evidence
//!    becomes the report the repair round reads), `unverified` → unverified,
//!    `unavailable` → unavailable.
//!
//! Teamwork does not use `isolated_verifier.compose`: in the check gate the
//! verifier can only demote a green check, so an `unverified` or
//! `unavailable` verifier leaves the check's pass standing. Completing a
//! teamwork run needs more: an explicit verifier PASS (doc/TEAMWORK_DESIGN.md).

const std = @import("std");
const iv = @import("../core/isolated_verifier.zig");
const log = @import("../util/log.zig");
const types = @import("types.zig");
const audit = @import("audit.zig");
const reviewer = @import("reviewer.zig");
const isolation = @import("../agents/isolation.zig");
const write_scope = @import("drivers/write_scope.zig");
const pfs = @import("platform").fs;

pub const VerifierAuditor = struct {
    /// The verifier's host dependencies; `abort` is replaced by the run's
    /// signal on every audit.
    deps: iv.Deps,
    /// Runs the pinned check (the same runner the review checks use).
    check_runner: reviewer.CheckRunner = .{},
    /// `--verifier-model`; null = the provider's model.
    model: ?[]const u8 = null,
    budget: iv.Budget = .{},

    pub fn auditor(self: *VerifierAuditor) audit.CompletionAuditor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: audit.CompletionAuditor.VTable = .{ .audit = auditFn };

    fn auditFn(ptr: *anyopaque, gpa: std.mem.Allocator, request: audit.AuditRequest) audit.CompletionAuditor.Error!audit.AuditVerdict {
        const self: *VerifierAuditor = @ptrCast(@alignCast(ptr));
        if (!request.preview.teamwork) return .{ .unavailable = try gpa.dupe(u8, "Teamwork preview is disabled.\n") };
        var snapshot = isolation.Snapshot.create(gpa, request.scratch_dir, request.workspace, request.base, request.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .unavailable = try gpa.dupe(u8, "The approved audit snapshot could not be created.\n") },
        };
        defer snapshot.deinit();
        if (!std.mem.eql(u8, snapshot.tree, request.approved_tree.slice()))
            return .{ .unavailable = try gpa.dupe(u8, "The audit snapshot does not match the approved tree.\n") };
        if (!try snapshotMatches(gpa, &snapshot, request))
            return .{ .unavailable = try gpa.dupe(u8, "The audit checkout does not match the approved tree.\n") };
        const temp = try std.fs.path.joinZ(gpa, &.{ request.scratch_dir, "tmp" });
        defer gpa.free(temp);
        if (pfs.mkdir(temp.ptr, 0o700) != 0 and !pfs.lastErrnoIs(.EXIST))
            return .{ .unavailable = try gpa.dupe(u8, "The audit temporary directory could not be created.\n") };
        var check_runner = self.check_runner;
        if (check_runner.sandbox == null) check_runner.sandbox = self.deps.sandbox;
        check_runner.private_temp = temp;
        var pinned: ?iv.PinnedCheck = null;
        if (request.check) |check| {
            const ran = check_runner.run(gpa, check, snapshot.path, request.abort) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Aborted => return .{ .unavailable = try gpa.dupe(u8, "The audit was aborted.\n") },
            };
            switch (ran) {
                .unavailable => |why| return .{ .unavailable = try std.fmt.allocPrint(gpa, "The pinned check could not run: {s}.\n", .{@tagName(why)}) },
                .exited => |code| if (code != 0) return .{ .fail = try std.fmt.allocPrint(
                    gpa,
                    "The pinned check `{s}` exits {d} on the result.\n",
                    .{ check.text, code },
                ) },
            }
            if (!try snapshotMatches(gpa, &snapshot, request))
                return .{ .unavailable = try gpa.dupe(u8, "The pinned check changed the approved audit checkout.\n") };
            pinned = .{ .command = check.text, .passed = 1, .total = 1 };
        }

        var budget = self.budget;
        budget.cost_usd = @min(budget.cost_usd, request.ledger.remainingUsd());
        if (!(budget.cost_usd > 0)) return .{ .unavailable = try gpa.dupe(u8, "No run budget is left for the verifier.\n") };
        var deps = self.deps;
        deps.preview = request.preview;
        deps.abort = request.abort;
        var sandbox = write_scope.seatSandbox(deps.sandbox);
        const git_protection = try write_scope.GitProtection.init(gpa, snapshot.path, sandbox.deny_write);
        defer git_protection.deinit();
        sandbox.deny_write = git_protection.roots;
        sandbox.temp_writes = .{ .isolated = temp };
        if (deps.sandbox != null) deps.sandbox = &sandbox;
        const seat_id = types.seatIdFor(.verifier, request.attempt);
        request.ledger.reserve(seat_id, .metacodes) catch return .{ .unavailable = try gpa.dupe(u8, "The verifier's budget reservation could not be recorded.\n") };
        var result = try iv.verify(gpa, deps, .{
            .task_statement = request.original_request,
            .workspace = .{ .snapshot = &snapshot },
            .aliased_workspace_packet = true,
            .pinned_check = pinned,
            .budget = budget,
            .model = self.model,
        });
        defer result.deinit();
        if (!charge(request, result.record)) return .{ .unavailable = try gpa.dupe(u8, "The verifier's spend could not be durably recorded.\n") };

        return switch (result.outcome) {
            .pass => if (std.mem.eql(u8, result.record.tree, request.approved_tree.slice()) and try snapshotMatches(gpa, &snapshot, request))
                .{ .pass = request.approved_tree }
            else
                .{ .unavailable = try gpa.dupe(u8, "The verifier did not confirm the approved audit checkout.\n") },
            .fail => |report| .{ .fail = try render(gpa, "FAIL", report.evidence, null, null) },
            .unverified => |u| .{ .unverified = try render(gpa, "UNVERIFIED", u.evidence, u.not_established, u.downgrade) },
            .unavailable => |why| .{ .unavailable = try std.fmt.allocPrint(gpa, "The isolated verifier produced no verdict: {s}.\n", .{@tagName(why)}) },
        };
    }

    fn snapshotMatches(gpa: std.mem.Allocator, snapshot: *const isolation.Snapshot, request: audit.AuditRequest) error{OutOfMemory}!bool {
        const tree = reviewer.workspaceTree(gpa, snapshot.path, snapshot.root, request.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        return tree.eql(request.approved_tree);
    }

    fn charge(request: audit.AuditRequest, record: iv.Record) bool {
        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "verifier-{d}", .{request.attempt}) catch unreachable;
        const usd = @as(f64, @floatFromInt(record.cost_microusd)) / 1_000_000.0;
        request.ledger.charge(.{
            .seat_id = types.SeatId.parse(id_text) catch unreachable,
            .harness = .metacodes,
            .wallclock_ms = record.wall_ms,
            .cost = .{ .provider_estimate = usd },
        }) catch |err| switch (err) {
            // The runtime reads `isExhausted` after the audit.
            error.BudgetExhausted => return true,
            error.InvalidAmount, error.WriteFailed => {
                log.warn("teamwork", "verifier charge not recorded: {s}", .{@errorName(err)});
                return false;
            },
        };
        return true;
    }
};

/// The report a repair round reads: the verifier's evidence blocks, as data.
fn render(
    gpa: std.mem.Allocator,
    verdict_name: []const u8,
    evidence: []const iv.Evidence,
    not_established: ?[]const u8,
    downgrade: ?iv.Downgrade,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, verdict_name, evidence, not_established, downgrade) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn write(
    w: *std.Io.Writer,
    verdict_name: []const u8,
    evidence: []const iv.Evidence,
    not_established: ?[]const u8,
    downgrade: ?iv.Downgrade,
) std.Io.Writer.Error!void {
    try w.print("Isolated verifier verdict: {s}\n", .{verdict_name});
    if (downgrade) |d| try w.print("(downgraded: {s})\n", .{@tagName(d)});
    for (evidence) |e| {
        try w.print("\n- Requirement: {s}\n", .{e.requirement});
        if (e.substitute.len != 0) try w.print("  Substitute: {s}\n", .{e.substitute});
        try w.print("  Probe: `{s}`{s}\n", .{ e.probe, if (e.matched) "" else " (not a command the verifier ran)" });
        if (e.observed.len != 0) try w.print("  Observed: {s}\n", .{e.observed});
    }
    if (not_established) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len != 0) try w.print("\nNot established:\n{s}\n", .{trimmed});
    }
}

const testing = std.testing;

test "verifier auditor: the report lists the evidence and flags unmatched probes" {
    const blocks = [_]iv.Evidence{
        .{ .requirement = "feature.txt says feature", .substitute = "an empty file", .probe = "cat feature.txt", .observed = "wrong", .matched = true },
        .{ .requirement = "r2", .probe = "ls", .matched = false },
    };
    const text = try render(testing.allocator, "FAIL", &blocks, "the flag", null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "- Requirement: feature.txt says feature\n  Substitute: an empty file\n  Probe: `cat feature.txt`\n  Observed: wrong\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Probe: `ls` (not a command the verifier ran)") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Not established:\nthe flag\n"));
}
