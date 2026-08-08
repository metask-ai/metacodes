//! UI-independent project rule gate protocol installed at the one actual tool
//! dispatch seam. Implementations may call a sidecar and therefore must be
//! safe for concurrent worker invocation.

const observation = @import("observation.zig");
const project_rule_spec = @import("../core/project_rule_spec.zig");

pub const Result = enum { admit, block, fault };

pub const PreSignal = struct {
    dispatch_id: []const u8,
    tool: []const u8,
    input_bytes: usize,
    agent_depth: u8,
    authoritative: bool,
    file_target_state: project_rule_spec.FileTargetState = .unobserved,
};

pub const PostSignal = struct {
    pre: PreSignal,
    outcome: observation.Outcome,
    effect: ?observation.Effect,
    effect_valid: bool,
};

pub const Gate = struct {
    ctx: *anyopaque,
    preFn: *const fn (ctx: *anyopaque, signal: PreSignal) Result,
    postFn: *const fn (ctx: *anyopaque, signal: PostSignal) Result,

    pub fn pre(self: Gate, signal: PreSignal) Result {
        return self.preFn(self.ctx, signal);
    }

    pub fn post(self: Gate, signal: PostSignal) Result {
        return self.postFn(self.ctx, signal);
    }
};
