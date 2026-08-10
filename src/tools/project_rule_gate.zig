//! UI-independent project rule gate protocol installed at the one actual tool
//! dispatch seam. Implementations may call a sidecar and therefore must be
//! safe for concurrent worker invocation.

const std = @import("std");
const observation = @import("observation.zig");
const project_rule_spec = @import("../core/project_rule_spec.zig");

pub const Result = enum { admit, block, fault };

pub const RecoveryAction = enum {
    none,
    edit_existing_file_exact,
};

pub const PreResult = union(enum) {
    admit,
    /// The fixed kernel admitted an outstanding whole-file recovery.  This is
    /// deliberately distinct from ordinary admission: executeOne must route
    /// the call through the native exact-edit implementation, not the normal
    /// Edit fallbacks or an embedding-provided executor.
    admit_exact_edit,
    block: RecoveryAction,
    fault,
};

/// Native-only commitments used to install and validate a Lean-selected
/// exact-edit recovery obligation. These values never expose file contents to
/// the checker or journal.
pub const ExactEditMaterial = struct {
    target_sha256: ?[64]u8 = null,
    current_sha256: ?[64]u8 = null,
    write_content_sha256: ?[64]u8 = null,
    edit_old_sha256: ?[64]u8 = null,
    edit_new_sha256: ?[64]u8 = null,

    pub fn writeReady(self: ExactEditMaterial) bool {
        return self.target_sha256 != null and self.current_sha256 != null and
            self.write_content_sha256 != null;
    }

    pub fn writeNeedsEdit(self: ExactEditMaterial) bool {
        return self.writeReady() and !std.mem.eql(
            u8,
            &self.current_sha256.?,
            &self.write_content_sha256.?,
        );
    }

    pub fn editReady(self: ExactEditMaterial) bool {
        return self.target_sha256 != null and self.current_sha256 != null and
            self.edit_old_sha256 != null and self.edit_new_sha256 != null;
    }
};

pub const PreSignal = struct {
    dispatch_id: []const u8,
    tool: []const u8,
    input_bytes: usize,
    agent_depth: u8,
    authoritative: bool,
    file_target_state: project_rule_spec.FileTargetState = .unobserved,
    exact_edit_material: ExactEditMaterial = .{},
};

pub const PostSignal = struct {
    pre: PreSignal,
    outcome: observation.Outcome,
    effect: ?observation.Effect,
    effect_valid: bool,
};

pub const Gate = struct {
    ctx: *anyopaque,
    preFn: *const fn (ctx: *anyopaque, signal: PreSignal) PreResult,
    postFn: *const fn (ctx: *anyopaque, signal: PostSignal) Result,
    /// Roll back host-side in-flight state when pre admitted but the dispatch
    /// observation could not start.  Optional for source compatibility with
    /// stateless embedding gates; the production RuntimeGate always supplies
    /// it for exact recovery.
    cancelPreFn: ?*const fn (ctx: *anyopaque, signal: PreSignal) bool = null,

    pub fn pre(self: Gate, signal: PreSignal) PreResult {
        return self.preFn(self.ctx, signal);
    }

    pub fn post(self: Gate, signal: PostSignal) Result {
        return self.postFn(self.ctx, signal);
    }

    pub fn cancelPre(self: Gate, signal: PreSignal) bool {
        const cancel = self.cancelPreFn orelse return false;
        return cancel(self.ctx, signal);
    }
};
