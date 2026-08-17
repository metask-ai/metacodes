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

pub const SCHEMA_VERSION = "metacodes-project-rule-spec-v3";
pub const MAX_TOOL_NAME_BYTES: usize = 128;
pub const MAX_INPUT_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_AGENT_DEPTH: u8 = 16;

pub const EffectRequirement = enum {
    none,
    file_mutation_v1_reobserved,
};

/// A governed effect class names the *outcome* a rule is about, so one rule
/// covers every tool that can produce it. Tool-name targeting alone let an
/// advisory plane (memory/prompt) route the same effect through an uncovered
/// tool: the paid factorial block saw a memory-steered direct Edit rewrite an
/// existing file while every active rule targeted Write and was statically
/// pruned. The class is a closed enum for the same reason TargetScope is: the
/// fixed kernel, not candidate Lean source, owns the applicability predicate.
pub const EffectClass = enum {
    existing_file_rewrite,
};

pub const TargetKind = enum { tool, effect_class };

pub const Target = union(TargetKind) {
    tool: []const u8,
    effect_class: EffectClass,
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
    target: Target,
    target_scope: TargetScope = .all,
    deny_target: bool,
    max_input_bytes: u64,
    max_agent_depth: u8,
    authoritative_only: bool,
    effect_requirement: EffectRequirement,
};

/// Wire keeps the union as a (kind, name) discriminator pair so the strict
/// positional Lean parser and the byte-for-byte canonical comparison stay
/// trivial. Field order is the canonical JSON order — do not reorder.
pub const Wire = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    target_kind: TargetKind,
    target: []const u8,
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
    /// Host-owned fact: the dispatched tool is one whose primary operation
    /// mutates a single observed file target (Write/Edit/NotebookEdit). The
    /// kernel cannot know the tool roster; it only trusts this bit the same
    /// way it trusts file_target_state. Bash and other opaque tools stay
    /// false and are therefore outside effect-class coverage — that hole is
    /// reported post-hoc by the rule_coverage_gap signal, not hidden.
    file_mutating: bool = false,
    /// Containment of the EFFECTIVE (symlink-resolved) target inside the
    /// project root. Wire order: keep LAST — the kernel's positional parser
    /// reads it after file_mutating. Mirrors Lean `PreSignal.withinRoot`.
    within_root: bool = true,
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
    switch (spec.target) {
        .tool => |name| {
            if (!validToolName(name)) return error.InvalidTargetTool;
            if (spec.target_scope == .existing_file and
                !std.mem.eql(u8, name, "Write"))
                return error.InvalidTargetScope;
        },
        .effect_class => {
            // The class itself encodes the file-state condition; a scope on
            // top would double-encode it and invite contradictions.
            if (spec.target_scope != .all) return error.InvalidTargetScope;
            // Phase restriction, not a final answer: deny-on-effect-class
            // would also deny the exact-edit recovery rail (the rail ends in
            // an Edit, which matches the class), and a deny without a
            // recovery protocol manufactures escape routes — the WorkBuddy
            // false intervention showed the model answering a bare block
            // with a Bash heredoc. Until deny carries a class-shaped
            // recovery design, effect-class rules are verification-only.
            if (spec.deny_target) return error.EffectClassDenyUnsupported;
        },
    }
    if (spec.max_input_bytes == 0 or spec.max_input_bytes > MAX_INPUT_BYTES)
        return error.InvalidInputBound;
    if (spec.max_agent_depth > MAX_AGENT_DEPTH) return error.InvalidDepthBound;
    if (spec.deny_target and spec.effect_requirement != .none)
        return error.UnreachableEffectRequirement;
}

pub fn toWire(spec: Spec) Wire {
    return .{
        .target_kind = std.meta.activeTag(spec.target),
        .target = switch (spec.target) {
            .tool => |name| name,
            .effect_class => |cls| @tagName(cls),
        },
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
    const target: Target = switch (wire.target_kind) {
        .tool => .{ .tool = wire.target },
        .effect_class => .{
            .effect_class = std.meta.stringToEnum(EffectClass, wire.target) orelse
                return error.UnsupportedEffectClass,
        },
    };
    const spec = Spec{
        .target = target,
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

/// True when this dispatch is one the rule is *about*. This predicate — not
/// the tool-name string — is what static pruning must key on; the paired Lean
/// theorem `target_mismatch_admits_both` proves pruning on its negation is
/// semantics-preserving.
pub fn targetMatchesPre(spec: Spec, signal: PreSignal) bool {
    return switch (spec.target) {
        .tool => |name| std.mem.eql(u8, signal.tool, name),
        .effect_class => |cls| switch (cls) {
            .existing_file_rewrite => signal.file_mutating,
        },
    };
}

/// Wire-level applicability used for static pruning at the gate. This must
/// stay total: an uninterpretable target deliberately counts as "matches", so
/// a malformed rule reaches the kernel and faults there instead of being
/// silently pruned into a no-op.
pub fn wireTargetMatchesPre(wire: Wire, signal: PreSignal) bool {
    switch (wire.target_kind) {
        .tool => return std.mem.eql(u8, signal.tool, wire.target),
        .effect_class => {
            const cls = std.meta.stringToEnum(EffectClass, wire.target) orelse
                return true;
            return switch (cls) {
                .existing_file_rewrite => signal.file_mutating,
            };
        },
    }
}

pub fn preDecision(spec: Spec, signal: PreSignal) bool {
    if (!targetMatchesPre(spec, signal)) return true;
    switch (spec.target) {
        .tool => switch (spec.target_scope) {
            .all => {},
            .existing_file => {
                if (!signal.within_root) return false;
                switch (signal.file_target_state) {
                    // A missing target is outside this rule's scope.  Every
                    // state that fails to prove a regular existing file is
                    // conservative except the explicit, host-observed
                    // missing state.
                    .missing => return true,
                    .regular_existing => {},
                    .unobserved, .other_existing, .unavailable => return false,
                }
            },
        },
        .effect_class => |cls| switch (cls) {
            // Same conservative ladder as the existing_file scope: a mutating
            // tool over an ambiguous target state cannot be proven not to be
            // rewriting an existing file, so it fails closed.  Containment is
            // judged first: an effective target outside the project root
            // never admits (Lean: escaping_resolution_fails_closed).
            .existing_file_rewrite => {
                if (!signal.within_root) return false;
                switch (signal.file_target_state) {
                    .missing => return true,
                    .regular_existing => {},
                    .unobserved, .other_existing, .unavailable => return false,
                }
            },
        },
    }
    if (spec.deny_target) return false;
    // Verify-only rules admit matched dispatches: obligations bind at post
    // time, and the input/depth bounds are the author's reasoned envelope,
    // not a safety verdict. Conflating the two blocked a legitimate 14KB
    // new-file deliverable twice in independent paid runs and pushed the
    // model into an ungoverned Bash escape. Overflow is reported by the
    // gate as an observation, never enforced here.
    if (spec.authoritative_only and !signal.authoritative) return false;
    return true;
}

/// The reasoned envelope, exceeded. Instrumentation only — must never feed
/// preDecision/postDecision.
pub fn boundsOverflow(spec: Spec, signal: PreSignal) bool {
    return signal.input_bytes > spec.max_input_bytes or
        signal.agent_depth > spec.max_agent_depth;
}

/// Wire-level overflow check for the gate (which holds Wire entries).
pub fn wireBoundsOverflow(wire: Wire, signal: PreSignal) bool {
    return signal.input_bytes > wire.max_input_bytes or
        signal.agent_depth > wire.max_agent_depth;
}

pub fn postDecision(spec: Spec, signal: PostSignal) bool {
    if (!targetMatchesPre(spec, signal.pre)) return true;
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
        .target = .{ .tool = "Bash" },
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
        .target = .{ .tool = "Write" },
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
        .target = .{ .tool = "Write" },
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
        .target = .{ .tool = "Edit" },
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
        .target = .{ .tool = "Edit" },
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
    try std.testing.expectEqualStrings(spec.target.tool, decoded.target.tool);
    try std.testing.expectEqual(spec.effect_requirement, decoded.effect_requirement);
}

test "effect-class rule covers every mutating tool and ignores the rest" {
    const spec = Spec{
        .target = .{ .effect_class = .existing_file_rewrite },
        .deny_target = false,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .file_mutation_v1_reobserved,
    };
    try validate(spec);
    // Any mutating tool over an existing regular file is in scope — the tool
    // name never appears in the predicate.
    for ([_][]const u8{ "Write", "Edit", "NotebookEdit" }) |tool| {
        const matched = PreSignal{
            .tool = tool,
            .input_bytes = 128,
            .agent_depth = 0,
            .authoritative = true,
            .file_target_state = .regular_existing,
            .file_mutating = true,
        };
        try std.testing.expect(targetMatchesPre(spec, matched));
        try std.testing.expect(preDecision(spec, matched));
        // The verification obligation binds at post time.
        try std.testing.expect(!postDecision(spec, .{
            .pre = matched,
            .succeeded = true,
            .effect_valid = true,
            .has_file_mutation_v1 = true,
            .post_reobserved = false,
        }));
        try std.testing.expect(postDecision(spec, .{
            .pre = matched,
            .succeeded = true,
            .effect_valid = true,
            .has_file_mutation_v1 = true,
            .post_reobserved = true,
        }));
    }
    // Creating a new file is not this effect class.
    var fresh = PreSignal{
        .tool = "Write",
        .input_bytes = 128,
        .agent_depth = 0,
        .authoritative = true,
        .file_target_state = .missing,
        .file_mutating = true,
    };
    try std.testing.expect(preDecision(spec, fresh));
    // Ambiguous target state on a mutating tool fails closed.
    fresh.file_target_state = .unavailable;
    try std.testing.expect(!preDecision(spec, fresh));
    // Non-mutating tools are outside the class entirely.
    const opaque_tool = PreSignal{
        .tool = "Bash",
        .input_bytes = 128,
        .agent_depth = 0,
        .authoritative = true,
        .file_mutating = false,
    };
    try std.testing.expect(!targetMatchesPre(spec, opaque_tool));
    try std.testing.expect(preDecision(spec, opaque_tool));
}

test "effect-class rules reject deny and non-all scope until recovery exists" {
    try std.testing.expectError(error.EffectClassDenyUnsupported, validate(.{
        .target = .{ .effect_class = .existing_file_rewrite },
        .deny_target = true,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    }));
    try std.testing.expectError(error.InvalidTargetScope, validate(.{
        .target = .{ .effect_class = .existing_file_rewrite },
        .target_scope = .existing_file,
        .deny_target = false,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .file_mutation_v1_reobserved,
    }));
}

test "effect-class wire round-trips and rejects unknown classes" {
    const spec = Spec{
        .target = .{ .effect_class = .existing_file_rewrite },
        .deny_target = false,
        .max_input_bytes = 4096,
        .max_agent_depth = 2,
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
    try std.testing.expectEqual(
        EffectClass.existing_file_rewrite,
        decoded.target.effect_class,
    );
    var bogus = parsed.value;
    bogus.target = "grow_arbitrary_state";
    try std.testing.expectError(error.UnsupportedEffectClass, fromWire(bogus));
}
