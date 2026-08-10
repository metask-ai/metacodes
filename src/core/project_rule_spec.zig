//! Small, typed policy IR shared by candidate build, replay/shadow, the Lean
//! runtime kernel, and the Zig tool-dispatch sensor.
//!
//! The IR starts intentionally narrow.  New project experience may justify a
//! new constructor, but a candidate cannot smuggle arbitrary native code into
//! the runtime.  Candidate Lean source exports this exact spec and proves its
//! structural validity; the build pipeline compares the exported canonical
//! JSON with this host-owned representation byte-for-byte.

const std = @import("std");
const observation = @import("../tools/observation.zig");

pub const SCHEMA_VERSION = "metacodes-project-rule-spec-v2";
pub const MAX_TOOL_NAME_BYTES: usize = 128;
pub const MAX_INPUT_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_AGENT_DEPTH: u8 = 16;

pub const EffectRequirement = enum {
    none,
    file_mutation_v1_reobserved,
};

/// Selects which concrete host state makes a rule applicable.  This remains a
/// closed enum rather than a candidate-provided predicate: the fixed kernel,
/// not untrusted Lean source, owns the production decision function.
pub const TargetScope = enum {
    all,
    existing_file,
};

/// Pre-dispatch filesystem state observed by the native host.  `unobserved`
/// is valid for tools that do not expose a file target; it is never accepted
/// as evidence that a Write target is new.  `other_existing` includes
/// directories and symlinks/reparse points.  Ambiguous errors are
/// `unavailable`, so an existing-file rule fails closed rather than silently
/// treating them as a safe create.
pub const FileTargetState = observation.FileTargetState;

pub const Spec = struct {
    target_tool: []const u8,
    target_scope: TargetScope = .all,
    deny_target: bool,
    max_input_bytes: u64,
    max_agent_depth: u8,
    authoritative_only: bool,
    effect_requirement: EffectRequirement,
};

pub const Wire = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    target_tool: []const u8,
    target_scope: TargetScope = .all,
    deny_target: bool,
    max_input_bytes: u64,
    max_agent_depth: u8,
    authoritative_only: bool,
    effect_requirement: EffectRequirement,
};

pub const PreSignal = struct {
    tool: []const u8,
    input_bytes: usize,
    agent_depth: u8,
    authoritative: bool,
    file_target_state: FileTargetState = .unobserved,
    exact_recovery_material_ready: bool = false,
};

/// Host comparisons for one pending exact-edit obligation. Plaintext paths
/// and contents stay outside the checker; the native sensor binds those bytes
/// and supplies only the equality facts needed by the fixed decision kernel.
pub const RecoveryPreSignal = struct {
    tool: []const u8,
    input_bytes: usize,
    agent_depth: u8,
    authoritative: bool,
    target_matches: bool,
    material_available: bool,
    /// The current file still has the content observed when the prohibited
    /// Write was blocked. This supplies content-CAS semantics across turns.
    current_matches_source: bool,
    old_matches_current: bool,
    new_matches_blocked: bool,
};

pub const RecoveryPostSignal = struct {
    pre: RecoveryPreSignal,
    succeeded: bool,
    effect_valid: bool,
    has_file_mutation_v1: bool,
    post_reobserved: bool,
    observed_matches_blocked: bool,
};

pub const PostSignal = struct {
    pre: PreSignal,
    succeeded: bool,
    effect_valid: bool,
    has_file_mutation_v1: bool,
    post_reobserved: bool,
};

pub fn validate(spec: Spec) !void {
    if (!validToolName(spec.target_tool)) return error.InvalidTargetTool;
    if (spec.target_scope == .existing_file and
        !std.mem.eql(u8, spec.target_tool, "Write"))
        return error.InvalidTargetScope;
    if (spec.max_input_bytes == 0 or spec.max_input_bytes > MAX_INPUT_BYTES)
        return error.InvalidInputBound;
    if (spec.max_agent_depth > MAX_AGENT_DEPTH) return error.InvalidDepthBound;
    if (spec.deny_target and spec.effect_requirement != .none)
        return error.UnreachableEffectRequirement;
}

pub fn toWire(spec: Spec) Wire {
    return .{
        .target_tool = spec.target_tool,
        .target_scope = spec.target_scope,
        .deny_target = spec.deny_target,
        .max_input_bytes = spec.max_input_bytes,
        .max_agent_depth = spec.max_agent_depth,
        .authoritative_only = spec.authoritative_only,
        .effect_requirement = spec.effect_requirement,
    };
}

pub fn fromWire(wire: Wire) !Spec {
    if (!std.mem.eql(u8, wire.schema_version, SCHEMA_VERSION))
        return error.UnsupportedRuleSpec;
    const spec = Spec{
        .target_tool = wire.target_tool,
        .target_scope = wire.target_scope,
        .deny_target = wire.deny_target,
        .max_input_bytes = wire.max_input_bytes,
        .max_agent_depth = wire.max_agent_depth,
        .authoritative_only = wire.authoritative_only,
        .effect_requirement = wire.effect_requirement,
    };
    try validate(spec);
    return spec;
}

pub fn renderCanonical(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    try validate(spec);
    return std.json.Stringify.valueAlloc(allocator, toWire(spec), .{});
}

pub fn preDecision(spec: Spec, signal: PreSignal) bool {
    if (!std.mem.eql(u8, signal.tool, spec.target_tool)) return true;
    switch (spec.target_scope) {
        .all => {},
        .existing_file => switch (signal.file_target_state) {
            // A missing target is outside this rule's scope.  Every state that
            // fails to prove a regular existing file is conservative except
            // the explicit, host-observed missing state.
            .missing => return true,
            .regular_existing => {},
            .unobserved, .other_existing, .unavailable => return false,
        },
    }
    if (spec.deny_target) return false;
    if (signal.input_bytes > spec.max_input_bytes or
        signal.agent_depth > spec.max_agent_depth) return false;
    if (spec.authoritative_only and !signal.authoritative) return false;
    return true;
}

pub fn postDecision(spec: Spec, signal: PostSignal) bool {
    if (!std.mem.eql(u8, signal.pre.tool, spec.target_tool)) return true;
    if (!preDecision(spec, signal.pre)) return false;
    if (!signal.succeeded) return true;
    return switch (spec.effect_requirement) {
        .none => true,
        .file_mutation_v1_reobserved => signal.effect_valid and
            signal.has_file_mutation_v1 and signal.post_reobserved,
    };
}

fn validToolName(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_TOOL_NAME_BYTES) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

test "project rule spec denies target and requires grounded post effects" {
    const deny = Spec{
        .target_tool = "Bash",
        .deny_target = true,
        .max_input_bytes = 4096,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    };
    try validate(deny);
    try std.testing.expect(!preDecision(deny, .{
        .tool = "Bash",
        .input_bytes = 2,
        .agent_depth = 0,
        .authoritative = true,
    }));
    try std.testing.expect(preDecision(deny, .{
        .tool = "Read",
        .input_bytes = 2,
        .agent_depth = 0,
        .authoritative = true,
    }));

    const mutate = Spec{
        .target_tool = "Write",
        .deny_target = false,
        .max_input_bytes = 8192,
        .max_agent_depth = 2,
        .authoritative_only = true,
        .effect_requirement = .file_mutation_v1_reobserved,
    };
    try std.testing.expect(!postDecision(mutate, .{
        .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true },
        .succeeded = true,
        .effect_valid = true,
        .has_file_mutation_v1 = true,
        .post_reobserved = false,
    }));
    try std.testing.expect(postDecision(mutate, .{
        .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true },
        .succeeded = true,
        .effect_valid = true,
        .has_file_mutation_v1 = true,
        .post_reobserved = true,
    }));
}

test "existing-file scope blocks regular Write but admits a proven new file" {
    const spec = Spec{
        .target_tool = "Write",
        .target_scope = .existing_file,
        .deny_target = true,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    };
    try validate(spec);
    const base = PreSignal{
        .tool = "Write",
        .input_bytes = 128,
        .agent_depth = 0,
        .authoritative = true,
    };
    var signal = base;
    signal.file_target_state = .regular_existing;
    try std.testing.expect(!preDecision(spec, signal));
    signal.file_target_state = .missing;
    try std.testing.expect(preDecision(spec, signal));
    signal.file_target_state = .other_existing;
    try std.testing.expect(!preDecision(spec, signal));
    signal.file_target_state = .unavailable;
    try std.testing.expect(!preDecision(spec, signal));
    signal.file_target_state = .unobserved;
    try std.testing.expect(!preDecision(spec, signal));
}

test "existing-file scope is only valid for Write" {
    try std.testing.expectError(error.InvalidTargetScope, validate(.{
        .target_tool = "Edit",
        .target_scope = .existing_file,
        .deny_target = true,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    }));
}

test "project rule spec canonical JSON round-trips strictly" {
    const spec = Spec{
        .target_tool = "Edit",
        .deny_target = false,
        .max_input_bytes = 1234,
        .max_agent_depth = 3,
        .authoritative_only = false,
        .effect_requirement = .file_mutation_v1_reobserved,
    };
    const encoded = try renderCanonical(std.testing.allocator, spec);
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(Wire, std.testing.allocator, encoded, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const decoded = try fromWire(parsed.value);
    try std.testing.expectEqualStrings(spec.target_tool, decoded.target_tool);
    try std.testing.expectEqual(spec.effect_requirement, decoded.effect_requirement);
}
