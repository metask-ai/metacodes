//! The completion audit seam (#514, #516): how the teamwork runtime asks
//! whether a run's result fulfils the user's original request.
//!
//! Completion is never declared by a manager or a seat. The runtime calls a
//! `CompletionAuditor` from `Run.requestCompletion` and acts on the verdict
//! by fixed rules (runtime.zig):
//!
//! - `pass` is the only verdict that lets a run reach merge-back and `done`;
//! - the first `fail` forwards its report into one repair round, and the
//!   first `unverified` forwards its report (the verifier's evidence and
//!   what it could not establish) into one leads round; a second audit that
//!   does not pass ends the run `failed` (at most two audits per run);
//! - `unverified` and `unavailable` never count as a pass: the run never
//!   merges on them, the worktree is kept, and the user workspace is
//!   untouched. `unavailable` ends the run at once.
//!
//! Implementations:
//!
//! - `StubAuditor`: scripted verdicts, for tests only.
//! - `UnavailableAuditor`: always `unavailable`, for a host that has no
//!   verifier configured: without one no run can complete (fail closed).
//! - `verifier_auditor.VerifierAuditor`: the production auditor, the
//!   isolated verifier's standalone `verify` (#516,
//!   doc/ISOLATED_VERIFIER_DESIGN.md) behind this interface. Another auditor
//!   plugs in the same way, through `runtime.Deps.auditor`.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const ledger_mod = @import("ledger.zig");
const TreeId = @import("reviewer.zig").TreeId;

/// What an auditor is given. Every slice and pointer is borrowed for the
/// call.
pub const AuditRequest = struct {
    preview: @import("../preview.zig").Features = .none,
    /// `ORIGINAL_REQUEST.md`, byte for byte: the audit's baseline.
    original_request: []const u8,
    /// The implementer's worktree, holding exactly the tree the reviewer
    /// approved. The auditor must not modify it (the runtime re-checks the
    /// tree afterwards and fails the run if it changed).
    workspace: []const u8,
    approved_tree: TreeId,
    /// The commit the worktree started from: `git diff <base>` against the
    /// workspace is exactly the run's change.
    base: []const u8,
    /// The host-pinned check command, if configured.
    check: ?config.CheckCommand,
    /// 1 or 2.
    attempt: u8,
    /// A directory of the auditor's own, outside the workspace
    /// (`audits/audit-<n>/` in the run directory).
    scratch_dir: []const u8,
    /// The run ledger: an auditor that spends money charges it, like a seat.
    ledger: *ledger_mod.Ledger,
    abort: *const types.AbortSignal,
};

/// An audit's answer. Reports are owned by the `gpa` given to `audit`;
/// release them with `deinit`.
pub const AuditVerdict = union(enum) {
    /// Every requirement of the original request is met, with evidence.
    pass: TreeId,
    /// The result does not fulfil the request. The report says what is
    /// missing; the runtime forwards it to the repair round.
    fail: []u8,
    /// The auditor could not decide (inconclusive or demoted evidence). The
    /// report's evidence and open points are the leads the runtime forwards.
    unverified: []u8,
    /// The auditor could not run at all.
    unavailable: []u8,

    pub fn deinit(self: *AuditVerdict, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .pass => {},
            .fail, .unverified, .unavailable => |text| gpa.free(text),
        }
        self.* = undefined;
    }

    pub fn report(self: *const AuditVerdict) []const u8 {
        return switch (self.*) {
            .pass => "",
            .fail, .unverified, .unavailable => |text| text,
        };
    }
};

pub const VerdictKind = std.meta.Tag(AuditVerdict);

/// The completion audit interface. The only error is running out of memory:
/// every other failure of the auditor is `unavailable`.
pub const CompletionAuditor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{OutOfMemory};

    pub const VTable = struct {
        audit: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, request: AuditRequest) Error!AuditVerdict,
    };

    pub fn audit(self: CompletionAuditor, gpa: std.mem.Allocator, request: AuditRequest) Error!AuditVerdict {
        return self.vtable.audit(self.ptr, gpa, request);
    }
};

/// The production default until the verifier adapter exists: every audit is
/// `unavailable`, so no run reaches `done` unaudited.
pub const UnavailableAuditor = struct {
    pub const reason = "No completion auditor is installed (the isolated verifier, #516, is not wired yet).\n";

    pub fn auditor(self: *UnavailableAuditor) CompletionAuditor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: CompletionAuditor.VTable = .{ .audit = auditFn };

    fn auditFn(_: *anyopaque, gpa: std.mem.Allocator, _: AuditRequest) CompletionAuditor.Error!AuditVerdict {
        return .{ .unavailable = try gpa.dupe(u8, reason) };
    }
};

/// Test double: answers from a script, one verdict per call (the last one
/// repeats), and records what it was asked.
pub const StubAuditor = struct {
    pub const Scripted = union(VerdictKind) {
        pass,
        fail: []const u8,
        unverified: []const u8,
        unavailable: []const u8,
    };

    script: []const Scripted,
    calls: u32 = 0,
    /// Copies of the last request's fields, owned by `gpa`.
    gpa: std.mem.Allocator,
    last_request: ?[]u8 = null,
    last_workspace: ?[]u8 = null,
    last_attempt: u8 = 0,

    pub fn deinit(self: *StubAuditor) void {
        if (self.last_request) |s| self.gpa.free(s);
        if (self.last_workspace) |s| self.gpa.free(s);
        self.* = undefined;
    }

    pub fn auditor(self: *StubAuditor) CompletionAuditor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: CompletionAuditor.VTable = .{ .audit = auditFn };

    fn auditFn(ptr: *anyopaque, gpa: std.mem.Allocator, request: AuditRequest) CompletionAuditor.Error!AuditVerdict {
        const self: *StubAuditor = @ptrCast(@alignCast(ptr));
        const index = @min(self.calls, self.script.len - 1);
        self.calls += 1;
        if (self.last_request) |s| self.gpa.free(s);
        if (self.last_workspace) |s| self.gpa.free(s);
        self.last_request = try self.gpa.dupe(u8, request.original_request);
        self.last_workspace = try self.gpa.dupe(u8, request.workspace);
        self.last_attempt = request.attempt;
        return switch (self.script[index]) {
            .pass => .{ .pass = request.approved_tree },
            .fail => |text| .{ .fail = try gpa.dupe(u8, text) },
            .unverified => |text| .{ .unverified = try gpa.dupe(u8, text) },
            .unavailable => |text| .{ .unavailable = try gpa.dupe(u8, text) },
        };
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "audit: the default auditor is unavailable, never a pass" {
    var ledger: ledger_mod.Ledger = .{ .path = undefined, .pending_path = undefined, .cap_usd = 1 };
    var abort = types.AbortSignal.init();
    var default: UnavailableAuditor = .{};
    var verdict = try default.auditor().audit(testing.allocator, .{
        .original_request = "x",
        .workspace = "/w",
        .approved_tree = try TreeId.parse("a" ** 40),
        .base = "b",
        .check = null,
        .attempt = 1,
        .scratch_dir = "/s",
        .ledger = &ledger,
        .abort = &abort,
    });
    defer verdict.deinit(testing.allocator);
    try testing.expect(verdict == .unavailable);
    try testing.expectEqualStrings(UnavailableAuditor.reason, verdict.report());
}

test "audit: the stub replays its script and records the request" {
    var ledger: ledger_mod.Ledger = .{ .path = undefined, .pending_path = undefined, .cap_usd = 1 };
    var abort = types.AbortSignal.init();
    const script = [_]StubAuditor.Scripted{ .{ .fail = "missing flag" }, .pass };
    var stub: StubAuditor = .{ .script = &script, .gpa = testing.allocator };
    defer stub.deinit();
    const request: AuditRequest = .{ .original_request = "req", .workspace = "/wt", .approved_tree = try TreeId.parse("a" ** 40), .base = "b", .check = null, .attempt = 1, .scratch_dir = "/s", .ledger = &ledger, .abort = &abort };
    var first = try stub.auditor().audit(testing.allocator, request);
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("missing flag", first.fail);
    var second = try stub.auditor().audit(testing.allocator, request);
    defer second.deinit(testing.allocator);
    try testing.expect(second == .pass);
    var third = try stub.auditor().audit(testing.allocator, request);
    defer third.deinit(testing.allocator);
    try testing.expect(third == .pass);
    try testing.expectEqualStrings("/wt", stub.last_workspace.?);
}
