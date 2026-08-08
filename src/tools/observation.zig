//! UI-independent observations from the one real tool-dispatch seam.
//!
//! `tool_start` / `tool_result` describe a model attempt and its conversation
//! pairing. They are useful UI/evaluation events, but they are not proof that
//! the tool implementation actually ran. This protocol is emitted directly
//! around `tool_exec.executeOne`'s dispatch call instead.
//!
//! Tools may attach one versioned typed effect to the terminal observation.
//! Effects are evidence only: neither a tool nor an observation sink can grant
//! permission, promote a Lean rule, or authorize a follow-up mutation.

const std = @import("std");

pub const SCHEMA_VERSION = "metacodes-tool-observation-v1";

pub const Origin = enum {
    authoritative,
    speculative_prefetch,
};

pub const Outcome = enum {
    succeeded,
    tool_error,
    pending,
    host_failed,
    host_rejected,
    host_fatal,
};

pub const BeforeState = enum {
    missing,
    known,
    unknown,
};

pub const ChangeState = enum {
    changed,
    unchanged,
    unknown,
};

/// First operation-specific signal. Literal paths and file contents are not
/// included; the observation carries commitments and exact byte counts. A path
/// hash is a commitment, not an anonymity guarantee against dictionary attacks.
/// This effect describes the target file only, not every auxiliary side effect
/// of the surrounding tool (for example parent-directory creation).
pub const FileMutationV1 = struct {
    path_sha256: [64]u8,
    before_state: BeforeState,
    before_sha256: [64]u8,
    after_sha256: [64]u8,
    before_bytes: usize,
    after_bytes: usize,
    change: ChangeState,
};

pub const Effect = union(enum) {
    file_mutation_v1: FileMutationV1,
};

/// Per-dispatch stack slot. A tool can publish at most one effect. A second
/// publication does not overwrite the first; it marks the evidence invalid so
/// the terminal observation cannot silently bless an ambiguous effect set.
pub const EffectSlot = struct {
    effect: ?Effect = null,
    valid: bool = true,

    pub fn record(self: *EffectSlot, effect: Effect) void {
        if (self.effect != null) {
            self.valid = false;
            return;
        }
        self.effect = effect;
    }
};

pub const Event = union(enum) {
    dispatch_started: struct {
        schema_version: []const u8 = SCHEMA_VERSION,
        id: []const u8,
        requested_name: []const u8,
        dispatched_name: []const u8,
        origin: Origin,
        agent_depth: u8,
        input_bytes: usize,
        input_sha256: [64]u8,
    },
    dispatch_finished: struct {
        schema_version: []const u8 = SCHEMA_VERSION,
        id: []const u8,
        requested_name: []const u8,
        dispatched_name: []const u8,
        origin: Origin,
        agent_depth: u8,
        outcome: Outcome,
        error_code: ?[]const u8,
        elapsed_ms: u64,
        result_present: bool,
        result_bytes: usize,
        result_sha256: [64]u8,
        effect: ?Effect,
        effect_valid: bool,
    },
};

/// The callback can be invoked concurrently by tool workers and speculative
/// prefetch. Implementations must synchronize their own state and consume all
/// borrowed slices before returning. `false` is a fail-closed control signal:
/// a rejected start prevents dispatch; a rejected finish poisons the run after
/// the already-observed real-world outcome.
pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, event: Event) bool,

    pub fn emit(self: Sink, event: Event) bool {
        return self.emitFn(self.ctx, event);
    }
};

pub const BeforeContent = union(BeforeState) {
    missing,
    known: []const u8,
    unknown,
};

pub fn fileMutation(path: []const u8, before: BeforeContent, after: []const u8) Effect {
    var before_sha256 = [_]u8{'0'} ** 64;
    var before_bytes: usize = 0;
    const change: ChangeState = switch (before) {
        .missing => .changed,
        .unknown => .unknown,
        .known => |bytes| blk: {
            before_sha256 = sha256Hex(bytes);
            before_bytes = bytes.len;
            break :blk if (std.mem.eql(u8, bytes, after)) .unchanged else .changed;
        },
    };
    return .{ .file_mutation_v1 = .{
        .path_sha256 = sha256Hex(path),
        .before_state = std.meta.activeTag(before),
        .before_sha256 = before_sha256,
        .after_sha256 = sha256Hex(after),
        .before_bytes = before_bytes,
        .after_bytes = after.len,
        .change = change,
    } };
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "tool observation: file mutation evidence preserves unknown pre-state" {
    const created = fileMutation("/private/a", .missing, "new").file_mutation_v1;
    try std.testing.expect(created.before_state == .missing);
    try std.testing.expect(created.change == .changed);
    try std.testing.expectEqual(@as(usize, 3), created.after_bytes);

    const unchanged = fileMutation("/private/a", .{ .known = "same" }, "same").file_mutation_v1;
    try std.testing.expect(unchanged.before_state == .known);
    try std.testing.expect(unchanged.change == .unchanged);
    try std.testing.expectEqualSlices(u8, &unchanged.before_sha256, &unchanged.after_sha256);

    const unknown = fileMutation("/private/a", .unknown, "new").file_mutation_v1;
    try std.testing.expect(unknown.before_state == .unknown);
    try std.testing.expect(unknown.change == .unknown);
}

test "tool observation: effect slot rejects ambiguous double publication" {
    var slot = EffectSlot{};
    slot.record(fileMutation("/a", .missing, "one"));
    slot.record(fileMutation("/a", .missing, "two"));
    try std.testing.expect(slot.effect != null);
    try std.testing.expect(!slot.valid);
}
