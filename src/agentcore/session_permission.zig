//! AgentCore-owned Revision 6 Permission vocabulary and canonical identities.
//!
//! This module deliberately contains no product settings persistence and no
//! UI policy. It defines the bounded facts used by the Session decision,
//! callback and checkpoint layers that follow.

const std = @import("std");
const core = @import("metacodes-core");
const util_json = @import("../util/json.zig");

pub const ARGUMENT_DIGEST_BYTES: usize = 32;
pub const REQUEST_ID_BYTES: usize = 32;
pub const RULE_ID_BYTES: usize = 32;
pub const MAX_SESSION_RULES: usize = 128;
pub const MAX_AUDIT_RECORDS: usize = 64;
pub const MAX_TOOL_CALL_ID_BYTES: usize = 1024;
pub const DEFAULT_MAX_ARGUMENT_BYTES: usize = 1024 * 1024;
pub const DEFAULT_MAX_JSON_DEPTH: u16 = 64;
pub const DEFAULT_MAX_JSON_NODES: u32 = 65_536;
pub const MAX_TOOL_IDENTITY_BYTES: usize = 512;
pub const CHECKPOINT_STATE_REVISION: u16 = 1;

const checkpoint_magic = "R6PERM\x00\x00";
const checkpoint_header_bytes: usize = 96;
const checkpoint_rule_bytes: usize = 112;

pub const Error = error{
    OutOfMemory,
    InvalidArguments,
    InvalidIdentity,
    InvalidResponse,
    ResourceLimit,
};

pub const Decision = enum(u8) {
    deny,
    ask,
    allow,
};

pub const Response = enum(u8) {
    deny_once,
    deny_session,
    allow_once,
    allow_session,
};

pub const CallbackOutcome = enum(u8) {
    answered,
    user_cancelled,
    unavailable,
    contract_failure,
};

pub const DecisionSource = enum(u8) {
    core_safety,
    active_skill,
    explicit_deny,
    session_deny,
    explicit_ask,
    explicit_allow,
    session_allow,
    builtin_classification,
    mode_fallback,
    callback,
};

pub const ToolNamespace = enum(u8) {
    builtin,
    host,
    mcp,
};

pub const ArgumentsDigest = [ARGUMENT_DIGEST_BYTES]u8;
pub const PermissionRequestId = [REQUEST_ID_BYTES]u8;
pub const RuleId = [RULE_ID_BYTES]u8;
pub const PolicyFingerprint = [32]u8;

/// `binding` is zero for built-ins. Host and MCP integrations use it to bind
/// a display name to the current executor/schema authority rather than
/// granting every future tool that happens to reuse the same name.
pub const ToolIdentity = struct {
    namespace: ToolNamespace,
    name: []const u8,
    binding: [32]u8 = [_]u8{0} ** 32,

    pub fn validate(self: ToolIdentity) Error!void {
        if (self.name.len == 0 or
            self.name.len > MAX_TOOL_IDENTITY_BYTES or
            !std.unicode.utf8ValidateSlice(self.name))
            return error.InvalidIdentity;
        for (self.name) |byte| {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidIdentity;
        }
        if (self.namespace == .builtin and !allZero(&self.binding))
            return error.InvalidIdentity;
        if (self.namespace != .builtin and allZero(&self.binding))
            return error.InvalidIdentity;
    }

    pub fn eql(a: ToolIdentity, b: ToolIdentity) bool {
        return a.namespace == b.namespace and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, &a.binding, &b.binding);
    }
};

pub const CandidateScope = enum(u8) {
    /// The narrowest safe first implementation: the same stable Tool identity
    /// and the same canonical argument value. Broader semantic candidates may
    /// be added only by a Tool-specific canonicalizer.
    exact_arguments,
};

pub const RuleCandidate = struct {
    rule_id: RuleId,
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
    scope: CandidateScope = .exact_arguments,
};

pub const SessionRuleAction = enum(u8) {
    deny,
    allow,
};

pub const ExplicitAction = enum(u8) {
    undecided,
    deny,
    ask,
    allow,
};

/// Evaluate Host-imported rules using the Revision 6 action ordering. The
/// product settings evaluator intentionally keeps its own allow-before-ask
/// behavior; AgentCore must not inherit that separate product policy.
pub fn evaluateExplicit(
    settings: ?*const core.permission_settings.MergedSettings,
    match_context: *const core.permission_rule_spec.MatchContext,
    tool_name: []const u8,
    arguments_json: []const u8,
) ExplicitAction {
    const merged = settings orelse return .undecided;
    for (merged.layers) |layer| {
        for (layer.deny) |rule| {
            if (core.permission_rule_spec.matchesMode(
                &rule.spec,
                match_context,
                tool_name,
                arguments_json,
                .deny,
            )) return .deny;
        }
    }
    for (merged.layers) |layer| {
        for (layer.ask) |rule| {
            if (core.permission_rule_spec.matchesMode(
                &rule.spec,
                match_context,
                tool_name,
                arguments_json,
                .ask,
            )) return .ask;
        }
    }
    for (merged.layers) |layer| {
        for (layer.allow) |rule| {
            if (core.permission_rule_spec.matchesMode(
                &rule.spec,
                match_context,
                tool_name,
                arguments_json,
                .allow,
            )) return .allow;
        }
    }
    return .undecided;
}

pub const Fallback = struct {
    decision: Decision,
    source: DecisionSource,
};

pub const DecisionResult = struct {
    decision: Decision,
    source: DecisionSource,
    matched_rule_id: ?RuleId = null,
    used_session_rule: bool = false,
};

pub const RememberResult = enum {
    added,
    already_present,
};

const SessionRule = struct {
    rule_id: RuleId,
    action: SessionRuleAction,
    namespace: ToolNamespace,
    tool_name: []u8,
    binding: [32]u8,
    arguments_digest: ArgumentsDigest,
    policy_generation: u64,

    fn deinit(self: *SessionRule, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }

    fn matches(
        self: *const SessionRule,
        tool: ToolIdentity,
        arguments_digest: ArgumentsDigest,
        policy_generation: u64,
    ) bool {
        return self.policy_generation == policy_generation and
            self.namespace == tool.namespace and
            std.mem.eql(u8, self.tool_name, tool.name) and
            std.mem.eql(u8, &self.binding, &tool.binding) and
            std.mem.eql(u8, &self.arguments_digest, &arguments_digest);
    }
};

/// Logical-Session scoped, bounded and zero-persistence Permission memory.
/// The Host may checkpoint it later, but this state never reads or writes a
/// product settings path.
pub const State = struct {
    allocator: std.mem.Allocator,
    mutex: @import("platform").sync.Mutex = .{},
    policy_generation: u64,
    rules: std.ArrayList(SessionRule) = .empty,

    pub fn init(allocator: std.mem.Allocator, policy_generation: u64) Error!State {
        if (policy_generation == 0) return error.InvalidIdentity;
        return .{
            .allocator = allocator,
            .policy_generation = policy_generation,
        };
    }

    pub fn deinit(self: *State) void {
        self.mutex.lock();
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn generation(self: *State) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.policy_generation;
    }

    pub fn ruleCount(self: *State) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.rules.items.len;
    }

    /// Replace the logical Session policy view after a successful idle Host
    /// rule mutation. The caller holds the facade mutation gate, so clearing
    /// rules and publishing the new generation is the transaction commit.
    pub fn replaceGeneration(
        self: *State,
        next_generation: u64,
    ) Error!void {
        if (next_generation == 0) return error.InvalidIdentity;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (next_generation <= self.policy_generation)
            return error.InvalidIdentity;
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.clearRetainingCapacity();
        self.policy_generation = next_generation;
    }

    pub fn encodeCheckpoint(
        self: *State,
        output_allocator: std.mem.Allocator,
        mode: core.types.PermissionMode,
        fingerprint: PolicyFingerprint,
    ) Error![]u8 {
        if (!isCanonicalMode(mode)) return error.InvalidIdentity;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.policy_generation == 0 or
            self.rules.items.len > MAX_SESSION_RULES)
            return error.InvalidIdentity;

        var total_bytes = checkpoint_header_bytes;
        for (self.rules.items) |rule| {
            total_bytes = std.math.add(
                usize,
                total_bytes,
                checkpoint_rule_bytes,
            ) catch return error.ResourceLimit;
            total_bytes = std.math.add(
                usize,
                total_bytes,
                rule.tool_name.len,
            ) catch return error.ResourceLimit;
        }
        const encoded = output_allocator.alloc(u8, total_bytes) catch
            return error.OutOfMemory;
        errdefer output_allocator.free(encoded);
        @memset(encoded, 0);
        @memcpy(encoded[0..checkpoint_magic.len], checkpoint_magic);
        std.mem.writeInt(
            u16,
            encoded[8..10],
            CHECKPOINT_STATE_REVISION,
            .little,
        );
        encoded[10] = modeByte(mode) orelse return error.InvalidIdentity;
        std.mem.writeInt(
            u32,
            encoded[12..16],
            @intCast(self.rules.items.len),
            .little,
        );
        std.mem.writeInt(
            u64,
            encoded[16..24],
            self.policy_generation,
            .little,
        );
        @memcpy(encoded[24..56], &fingerprint);

        var offset = checkpoint_header_bytes;
        for (self.rules.items) |rule| {
            const entry = encoded[offset..][0..checkpoint_rule_bytes];
            entry[0] = @intFromEnum(rule.action);
            entry[1] = @intFromEnum(rule.namespace);
            entry[2] = @intFromEnum(CandidateScope.exact_arguments);
            std.mem.writeInt(
                u32,
                entry[4..8],
                @intCast(rule.tool_name.len),
                .little,
            );
            @memcpy(entry[8..40], &rule.binding);
            @memcpy(entry[40..72], &rule.arguments_digest);
            @memcpy(entry[72..104], &rule.rule_id);
            offset += checkpoint_rule_bytes;
            @memcpy(encoded[offset..][0..rule.tool_name.len], rule.tool_name);
            offset += rule.tool_name.len;
        }
        std.debug.assert(offset == encoded.len);
        return encoded;
    }

    pub fn remember(
        self: *State,
        response: Response,
        candidate: RuleCandidate,
        expected_policy_generation: u64,
    ) Error!RememberResult {
        const action: SessionRuleAction = switch (response) {
            .deny_session => .deny,
            .allow_session => .allow,
            .deny_once, .allow_once => return error.InvalidIdentity,
        };
        try candidate.tool.validate();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (expected_policy_generation != self.policy_generation)
            return error.InvalidIdentity;
        for (self.rules.items) |*existing| {
            if (existing.action == action and
                std.mem.eql(u8, &existing.rule_id, &candidate.rule_id))
                return .already_present;
        }
        if (self.rules.items.len == MAX_SESSION_RULES)
            return error.ResourceLimit;
        const name = self.allocator.dupe(u8, candidate.tool.name) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(name);
        self.rules.append(self.allocator, .{
            .rule_id = candidate.rule_id,
            .action = action,
            .namespace = candidate.tool.namespace,
            .tool_name = name,
            .binding = candidate.tool.binding,
            .arguments_digest = candidate.arguments_digest,
            .policy_generation = self.policy_generation,
        }) catch return error.OutOfMemory;
        return .added;
    }

    pub fn decide(
        self: *State,
        tool: ToolIdentity,
        arguments_digest: ArgumentsDigest,
        explicit: ExplicitAction,
        fallback: Fallback,
    ) Error!DecisionResult {
        try tool.validate();
        self.mutex.lock();
        defer self.mutex.unlock();

        if (explicit == .deny) return .{
            .decision = .deny,
            .source = .explicit_deny,
        };
        if (self.matchingRule(.deny, tool, arguments_digest)) |rule| return .{
            .decision = .deny,
            .source = .session_deny,
            .matched_rule_id = rule.rule_id,
            .used_session_rule = true,
        };
        if (explicit == .ask) return .{
            .decision = .ask,
            .source = .explicit_ask,
        };
        if (explicit == .allow) return .{
            .decision = .allow,
            .source = .explicit_allow,
        };
        if (self.matchingRule(.allow, tool, arguments_digest)) |rule| return .{
            .decision = .allow,
            .source = .session_allow,
            .matched_rule_id = rule.rule_id,
            .used_session_rule = true,
        };
        return .{
            .decision = fallback.decision,
            .source = fallback.source,
        };
    }

    /// Remove stale grants for one external authority namespace without
    /// changing policy generation or disturbing unrelated Session decisions.
    /// The facade calls this only behind its idle mutation gate.
    pub fn invalidateUnresolvable(
        self: *State,
        namespace: ToolNamespace,
        resolver: ExternalIdentityResolver,
    ) u32 {
        std.debug.assert(namespace != .builtin);
        self.mutex.lock();
        defer self.mutex.unlock();
        var invalidated: u32 = 0;
        var index: usize = 0;
        while (index < self.rules.items.len) {
            const rule = &self.rules.items[index];
            if (rule.namespace != namespace or resolver.isResolvable(.{
                .namespace = rule.namespace,
                .name = rule.tool_name,
                .binding = rule.binding,
            })) {
                index += 1;
                continue;
            }
            var removed = self.rules.orderedRemove(index);
            removed.deinit(self.allocator);
            invalidated += 1;
        }
        return invalidated;
    }

    /// Build the post-invalidation rule set without mutating the live Session.
    /// The AgentCore facade publishes this prepared value only after every
    /// other authority replacement and durable-budget check has succeeded.
    pub fn prepareInvalidation(
        self: *State,
        namespace: ToolNamespace,
        resolver: ExternalIdentityResolver,
    ) Error!PreparedInvalidation {
        std.debug.assert(namespace != .builtin);
        self.mutex.lock();
        defer self.mutex.unlock();

        var replacement = try State.init(self.allocator, self.policy_generation);
        errdefer replacement.deinit();
        var invalidated: u32 = 0;
        for (self.rules.items) |rule| {
            const tool = ToolIdentity{
                .namespace = rule.namespace,
                .name = rule.tool_name,
                .binding = rule.binding,
            };
            if (rule.namespace == namespace and !resolver.isResolvable(tool)) {
                invalidated += 1;
                continue;
            }
            _ = try replacement.remember(
                if (rule.action == .allow) .allow_session else .deny_session,
                .{
                    .rule_id = rule.rule_id,
                    .tool = tool,
                    .arguments_digest = rule.arguments_digest,
                },
                self.policy_generation,
            );
        }
        return .{
            .state = replacement,
            .invalidated = invalidated,
        };
    }

    /// Infallible publication of a fully prepared rule set. Keep the live
    /// mutex and allocator in place so readers never observe a moved lock.
    /// `replacement` receives the old rules and can be deinitialized after
    /// the surrounding facade transaction has published its other fields.
    pub fn commitPrepared(self: *State, replacement: *State) void {
        std.debug.assert(self.policy_generation == replacement.policy_generation);
        self.mutex.lock();
        defer self.mutex.unlock();
        std.mem.swap(std.ArrayList(SessionRule), &self.rules, &replacement.rules);
    }

    fn matchingRule(
        self: *State,
        action: SessionRuleAction,
        tool: ToolIdentity,
        arguments_digest: ArgumentsDigest,
    ) ?*const SessionRule {
        for (self.rules.items) |*rule| {
            if (rule.action == action and rule.matches(
                tool,
                arguments_digest,
                self.policy_generation,
            )) return rule;
        }
        return null;
    }
};

pub const PreparedInvalidation = struct {
    state: State,
    invalidated: u32,

    pub fn deinit(self: *PreparedInvalidation) void {
        self.state.deinit();
        self.* = undefined;
    }
};

/// Exact canonical checkpoint growth of one newly remembered Session rule.
/// Callers use it to reserve durable bytes before publishing the rule.
pub fn checkpointRuleDeltaBytes(tool: ToolIdentity) Error!u64 {
    try tool.validate();
    return std.math.add(
        u64,
        checkpoint_rule_bytes,
        tool.name.len,
    ) catch error.ResourceLimit;
}

pub const DurableRule = struct {
    action: SessionRuleAction,
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
    rule_id: RuleId,

    fn deinit(self: *DurableRule, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.tool.name));
        self.* = undefined;
    }
};

pub const DecodedCheckpoint = struct {
    allocator: std.mem.Allocator,
    mode: core.types.PermissionMode,
    policy_generation: u64,
    policy_fingerprint: PolicyFingerprint,
    rules: []DurableRule,

    pub fn deinit(self: *DecodedCheckpoint) void {
        for (self.rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.rules);
        self.* = undefined;
    }
};

pub const Reconciliation = struct {
    state: ?State,
    policy_generation: u64,
    restored: u32,
    invalidated: u32,
    fingerprint_compatible: bool,

    pub fn takeState(self: *Reconciliation) State {
        const state = self.state.?;
        self.state = null;
        return state;
    }

    pub fn deinit(self: *Reconciliation) void {
        if (self.state) |*state| state.deinit();
        self.* = undefined;
    }
};

pub const ExternalIdentityResolver = struct {
    ctx: *const anyopaque,
    is_resolvable_fn: *const fn (ctx: *const anyopaque, tool: ToolIdentity) bool,

    pub fn isResolvable(self: ExternalIdentityResolver, tool: ToolIdentity) bool {
        return self.is_resolvable_fn(self.ctx, tool);
    }
};

pub fn decodeCheckpoint(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) Error!DecodedCheckpoint {
    if (encoded.len < checkpoint_header_bytes or
        !std.mem.eql(u8, encoded[0..checkpoint_magic.len], checkpoint_magic) or
        std.mem.readInt(u16, encoded[8..10], .little) != CHECKPOINT_STATE_REVISION or
        encoded[11] != 0 or
        !allZero(encoded[56..checkpoint_header_bytes]))
        return error.InvalidArguments;
    const mode = modeFromByte(encoded[10]) orelse
        return error.InvalidArguments;
    const count: usize = @intCast(std.mem.readInt(
        u32,
        encoded[12..16],
        .little,
    ));
    if (count > MAX_SESSION_RULES) return error.ResourceLimit;
    const generation = std.mem.readInt(u64, encoded[16..24], .little);
    if (generation == 0) return error.InvalidArguments;
    const rules = allocator.alloc(DurableRule, count) catch
        return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (rules[0..initialized]) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    var offset = checkpoint_header_bytes;
    while (initialized < count) : (initialized += 1) {
        if (encoded.len - offset < checkpoint_rule_bytes)
            return error.InvalidArguments;
        const entry = encoded[offset..][0..checkpoint_rule_bytes];
        if (entry[3] != 0 or !allZero(entry[104..checkpoint_rule_bytes]))
            return error.InvalidArguments;
        const action: SessionRuleAction = switch (entry[0]) {
            0 => .deny,
            1 => .allow,
            else => return error.InvalidArguments,
        };
        const namespace: ToolNamespace = switch (entry[1]) {
            0 => .builtin,
            1 => .host,
            2 => .mcp,
            else => return error.InvalidArguments,
        };
        if (entry[2] != @intFromEnum(CandidateScope.exact_arguments))
            return error.InvalidArguments;
        const name_len: usize = @intCast(std.mem.readInt(
            u32,
            entry[4..8],
            .little,
        ));
        if (name_len == 0 or name_len > MAX_TOOL_IDENTITY_BYTES)
            return error.InvalidArguments;
        offset += checkpoint_rule_bytes;
        if (encoded.len - offset < name_len) return error.InvalidArguments;
        const name = allocator.dupe(u8, encoded[offset..][0..name_len]) catch
            return error.OutOfMemory;
        errdefer allocator.free(name);
        offset += name_len;
        const tool = ToolIdentity{
            .namespace = namespace,
            .name = name,
            .binding = entry[8..40].*,
        };
        try tool.validate();
        const arguments_digest: ArgumentsDigest = entry[40..72].*;
        const rule_id: RuleId = entry[72..104].*;
        const derived = (try deriveRuleCandidate(
            tool,
            arguments_digest,
        )) orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, &derived.rule_id, &rule_id))
            return error.InvalidArguments;
        for (rules[0..initialized]) |previous| {
            if (previous.action == action and
                std.mem.eql(u8, &previous.rule_id, &rule_id))
                return error.InvalidArguments;
        }
        rules[initialized] = .{
            .action = action,
            .tool = tool,
            .arguments_digest = arguments_digest,
            .rule_id = rule_id,
        };
    }
    if (offset != encoded.len) return error.InvalidArguments;
    return .{
        .allocator = allocator,
        .mode = mode,
        .policy_generation = generation,
        .policy_fingerprint = encoded[24..56].*,
        .rules = rules,
    };
}

/// Revalidate checkpoint grants against current authority. A policy mismatch
/// restores the Conversation under a fresh generation with no grants. Rules
/// whose external Tool binding is not currently resolvable are invalidated
/// individually. The resolver-aware entry point below covers Host and MCP
/// identities without teaching this canonical state machine either registry.
pub fn reconcileCheckpoint(
    allocator: std.mem.Allocator,
    decoded: *const DecodedCheckpoint,
    current_mode: core.types.PermissionMode,
    current_fingerprint: PolicyFingerprint,
    current_allowed_tools: []const []const u8,
) Error!Reconciliation {
    return reconcileCheckpointWithResolver(
        allocator,
        decoded,
        current_mode,
        current_fingerprint,
        current_allowed_tools,
        null,
    );
}

pub fn reconcileCheckpointWithResolver(
    allocator: std.mem.Allocator,
    decoded: *const DecodedCheckpoint,
    current_mode: core.types.PermissionMode,
    current_fingerprint: PolicyFingerprint,
    current_allowed_tools: []const []const u8,
    external_resolver: ?ExternalIdentityResolver,
) Error!Reconciliation {
    const compatible = decoded.mode == current_mode and std.mem.eql(
        u8,
        &decoded.policy_fingerprint,
        &current_fingerprint,
    );
    if (!compatible) {
        const next_generation = std.math.add(
            u64,
            decoded.policy_generation,
            1,
        ) catch return error.ResourceLimit;
        return .{
            .state = try State.init(allocator, next_generation),
            .policy_generation = next_generation,
            .restored = 0,
            .invalidated = @intCast(decoded.rules.len),
            .fingerprint_compatible = false,
        };
    }

    var state = try State.init(allocator, decoded.policy_generation);
    errdefer state.deinit();
    var restored: u32 = 0;
    var invalidated: u32 = 0;
    for (decoded.rules) |rule| {
        const resolvable = if (rule.tool.namespace == .builtin)
            isKnownBuiltin(rule.tool.name) and
                containsString(current_allowed_tools, rule.tool.name)
        else if (external_resolver) |resolver|
            resolver.isResolvable(rule.tool)
        else
            false;
        if (!resolvable) {
            invalidated += 1;
            continue;
        }
        const candidate = RuleCandidate{
            .rule_id = rule.rule_id,
            .tool = rule.tool,
            .arguments_digest = rule.arguments_digest,
        };
        _ = try state.remember(
            if (rule.action == .allow) .allow_session else .deny_session,
            candidate,
            decoded.policy_generation,
        );
        restored += 1;
    }
    return .{
        .state = state,
        .policy_generation = decoded.policy_generation,
        .restored = restored,
        .invalidated = invalidated,
        .fingerprint_compatible = true,
    };
}

pub const PermissionRequest = struct {
    session_id: core.session_id.SessionId,
    run_id: u64,
    tool_call_id: []const u8,
    /// Model-facing alias used only to correlate the internal policy event.
    /// Public Permission identity remains the canonical `tool` below.
    model_tool_name: []const u8,
    request_id: PermissionRequestId,
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
    policy_generation: u64,
    candidate: ?RuleCandidate,
};

pub const Provenance = struct {
    decision: Decision,
    source: DecisionSource,
    matched_rule_id: ?RuleId = null,
    session_id: core.session_id.SessionId,
    run_id: u64,
    tool_call_id: []const u8,
    request_id: ?PermissionRequestId = null,
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
    policy_generation: u64,
    used_session_rule: bool = false,
    callback_outcome: ?CallbackOutcome = null,
    response: ?Response = null,
};

pub const OwnedProvenance = struct {
    decision: Decision,
    source: DecisionSource,
    matched_rule_id: ?RuleId,
    session_id: core.session_id.SessionId,
    run_id: u64,
    tool_call_id: []u8,
    request_id: ?PermissionRequestId,
    tool_namespace: ToolNamespace,
    tool_name: []u8,
    binding: [32]u8,
    arguments_digest: ArgumentsDigest,
    policy_generation: u64,
    used_session_rule: bool,
    callback_outcome: ?CallbackOutcome,
    response: ?Response,

    fn init(allocator: std.mem.Allocator, source: Provenance) Error!OwnedProvenance {
        if (source.tool_call_id.len == 0 or
            source.tool_call_id.len > MAX_TOOL_CALL_ID_BYTES)
            return error.InvalidIdentity;
        try source.tool.validate();
        const tool_call_id = allocator.dupe(u8, source.tool_call_id) catch
            return error.OutOfMemory;
        errdefer allocator.free(tool_call_id);
        const tool_name = allocator.dupe(u8, source.tool.name) catch
            return error.OutOfMemory;
        return .{
            .decision = source.decision,
            .source = source.source,
            .matched_rule_id = source.matched_rule_id,
            .session_id = source.session_id,
            .run_id = source.run_id,
            .tool_call_id = tool_call_id,
            .request_id = source.request_id,
            .tool_namespace = source.tool.namespace,
            .tool_name = tool_name,
            .binding = source.tool.binding,
            .arguments_digest = source.arguments_digest,
            .policy_generation = source.policy_generation,
            .used_session_rule = source.used_session_rule,
            .callback_outcome = source.callback_outcome,
            .response = source.response,
        };
    }

    pub fn deinit(self: *OwnedProvenance, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedProvenance) Provenance {
        return .{
            .decision = self.decision,
            .source = self.source,
            .matched_rule_id = self.matched_rule_id,
            .session_id = self.session_id,
            .run_id = self.run_id,
            .tool_call_id = self.tool_call_id,
            .request_id = self.request_id,
            .tool = .{
                .namespace = self.tool_namespace,
                .name = self.tool_name,
                .binding = self.binding,
            },
            .arguments_digest = self.arguments_digest,
            .policy_generation = self.policy_generation,
            .used_session_rule = self.used_session_rule,
            .callback_outcome = self.callback_outcome,
            .response = self.response,
        };
    }
};

/// A bounded in-memory source for the later public normalized audit event.
/// It is deliberately excluded from checkpoint authority and product storage.
pub const AuditTrail = struct {
    allocator: std.mem.Allocator,
    mutex: @import("platform").sync.Mutex = .{},
    records: std.ArrayList(OwnedProvenance),

    pub fn init(allocator: std.mem.Allocator) Error!AuditTrail {
        return .{
            .allocator = allocator,
            .records = std.ArrayList(OwnedProvenance).initCapacity(
                allocator,
                MAX_AUDIT_RECORDS,
            ) catch return error.OutOfMemory,
        };
    }

    pub fn deinit(self: *AuditTrail) void {
        self.mutex.lock();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    /// Allocate an audit record without publishing it.  Permission callbacks
    /// use this before mutating Session grants so an allocation failure cannot
    /// create authority that has no corresponding audit receipt.
    pub fn prepare(self: *AuditTrail, source: Provenance) Error!OwnedProvenance {
        return OwnedProvenance.init(self.allocator, source);
    }

    /// Publish a prepared receipt without allocation. Ownership transfers to
    /// the trail and `prepared` becomes undefined.
    pub fn commit(self: *AuditTrail, prepared: *OwnedProvenance) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.items.len == MAX_AUDIT_RECORDS) {
            var removed = self.records.orderedRemove(0);
            removed.deinit(self.allocator);
        }
        self.records.appendAssumeCapacity(prepared.*);
        prepared.* = undefined;
    }

    pub fn discard(self: *AuditTrail, prepared: *OwnedProvenance) void {
        prepared.deinit(self.allocator);
    }

    pub fn append(self: *AuditTrail, source: Provenance) Error!void {
        var prepared = try self.prepare(source);
        errdefer self.discard(&prepared);
        self.commit(&prepared);
    }

    pub fn count(self: *AuditTrail) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.items.len;
    }

    pub fn cloneLast(
        self: *AuditTrail,
        output_allocator: std.mem.Allocator,
    ) Error!?OwnedProvenance {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.items.len == 0) return null;
        return try OwnedProvenance.init(
            output_allocator,
            self.records.items[self.records.items.len - 1].view(),
        );
    }
};

pub const CallbackEncodingOptions = struct {
    /// Explicit ask and Core safety may still accept a one-shot allow, but a
    /// Session allow would be ineffective on the next invocation. Do not
    /// advertise a response whose grant cannot participate in the decision
    /// chain.
    allow_session_response: bool = true,
};

const CallbackToolDto = struct {
    namespace: []const u8,
    name: []const u8,
    binding: []const u8,
};

const CallbackCandidateDto = struct {
    rule_id: []const u8,
    scope: []const u8,
};

const CallbackRequestDto = struct {
    type: []const u8 = "permission",
    request_id: []const u8,
    session_id: []const u8,
    run_id: u64,
    tool_call_id: []const u8,
    tool: CallbackToolDto,
    canonical_arguments_digest: []const u8,
    policy_generation: u64,
    arguments_json: []const u8,
    responses: []const []const u8,
    candidate: ?CallbackCandidateDto,
};

const CallbackResponseDto = struct {
    permission: []const u8,
    request_id: []const u8,
    policy_generation: u64,
    rule_id: ?[]const u8 = null,
};

pub const DigestLimits = struct {
    max_input_bytes: usize = DEFAULT_MAX_ARGUMENT_BYTES,
    max_depth: u16 = DEFAULT_MAX_JSON_DEPTH,
    max_nodes: u32 = DEFAULT_MAX_JSON_NODES,

    pub fn validate(self: DigestLimits) Error!void {
        if (self.max_input_bytes == 0 or
            self.max_input_bytes > DEFAULT_MAX_ARGUMENT_BYTES or
            self.max_depth == 0 or
            self.max_nodes == 0)
            return error.ResourceLimit;
    }
};

/// Hash the JSON value, not its incidental whitespace or object-key order.
/// Numeric lexemes outside Zig's integer/float range remain exact-lexeme
/// bound; that is deliberately more restrictive, never more permissive.
pub fn digestCanonicalArguments(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    limits: DigestLimits,
) Error!ArgumentsDigest {
    try limits.validate();
    if (encoded.len == 0 or encoded.len > limits.max_input_bytes)
        return error.ResourceLimit;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.max_input_bytes,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var nodes: u32 = 0;
    try hashValue(
        allocator,
        &hasher,
        parsed.value,
        1,
        &nodes,
        limits,
    );
    var digest: ArgumentsDigest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn deriveRuleCandidate(
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
) Error!?RuleCandidate {
    try tool.validate();
    if (!supportsSessionCandidate(tool)) return null;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-permission-rule\x00");
    hashToolIdentity(&hasher, tool);
    hasher.update(&.{@intFromEnum(CandidateScope.exact_arguments)});
    hasher.update(&arguments_digest);
    var rule_id: RuleId = undefined;
    hasher.final(&rule_id);
    return .{
        .rule_id = rule_id,
        .tool = tool,
        .arguments_digest = arguments_digest,
    };
}

/// Until Host tool definitions can supply a canonical specifier builder,
/// their Session response remains unavailable. Built-ins are known by Core;
/// MCP identity includes its non-zero server/schema binding.
fn supportsSessionCandidate(tool: ToolIdentity) bool {
    return switch (tool.namespace) {
        .builtin => isKnownBuiltin(tool.name),
        .host => false,
        .mcp => true,
    };
}

pub fn deriveRequestId(
    session_id: core.session_id.SessionId,
    run_id: u64,
    tool_call_id: []const u8,
    tool: ToolIdentity,
    arguments_digest: ArgumentsDigest,
    policy_generation: u64,
    request_sequence: u64,
) Error!PermissionRequestId {
    try tool.validate();
    if (run_id == 0 or tool_call_id.len == 0 or request_sequence == 0)
        return error.InvalidIdentity;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-permission-request\x00");
    hashBytes(&hasher, session_id.asSlice());
    hashU64(&hasher, run_id);
    hashBytes(&hasher, tool_call_id);
    hashToolIdentity(&hasher, tool);
    hasher.update(&arguments_digest);
    hashU64(&hasher, policy_generation);
    hashU64(&hasher, request_sequence);
    var request_id: PermissionRequestId = undefined;
    hasher.final(&request_id);
    return request_id;
}

/// Revision 6's temporary Host binding is stable for the same Runtime tool
/// name and semantic input schema. Host tools remain once-only until the
/// public Runtime descriptor supplies an explicit authority identity and a
/// Tool-specific Session candidate canonicalizer.
pub fn deriveHostBinding(
    allocator: std.mem.Allocator,
    name: []const u8,
    schema_json: []const u8,
) Error![32]u8 {
    if (name.len == 0 or name.len > MAX_TOOL_IDENTITY_BYTES)
        return error.InvalidIdentity;
    const schema_digest = try digestCanonicalArguments(
        allocator,
        schema_json,
        .{},
    );
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-host-tool-binding\x00");
    hashBytes(&hasher, name);
    hasher.update(&schema_digest);
    var binding: [32]u8 = undefined;
    hasher.final(&binding);
    // The all-zero value is reserved for built-ins. Keep the derivation total
    // even for the cryptographically negligible zero-digest case.
    if (allZero(&binding)) binding[0] = 1;
    return binding;
}

/// Fingerprint the effective Host-provided Permission authority inputs. Rule
/// order inside allow/ask/deny and Runtime tool advertisement order are not
/// semantic, so each set is sorted before hashing. A mismatch can only clear
/// Session grants; it can never make an incompatible checkpoint authoritative.
pub fn computePolicyFingerprint(
    allocator: std.mem.Allocator,
    mode: core.types.PermissionMode,
    optional_rules: ?core.permission_settings.RuleSetInput,
    workspace: core.agent_session.WorkspaceConfig,
    allowed_tools: []const []const u8,
) Error!PolicyFingerprint {
    if (!isCanonicalMode(mode) or workspace.root.len == 0 or
        !std.unicode.utf8ValidateSlice(workspace.root) or
        !std.unicode.utf8ValidateSlice(workspace.home))
        return error.InvalidIdentity;
    const rules = optional_rules orelse core.permission_settings.RuleSetInput{};
    var rule_count: usize = 0;
    var rule_bytes: usize = 0;
    for ([_][]const []const u8{ rules.deny, rules.ask, rules.allow }) |set| {
        rule_count = std.math.add(usize, rule_count, set.len) catch
            return error.ResourceLimit;
        if (rule_count > MAX_SESSION_RULES * 8) return error.ResourceLimit;
        for (set) |rule| {
            if (rule.len == 0 or
                rule.len > (core.permission_settings.RuleSetLimits{}).max_rule_bytes or
                !std.unicode.utf8ValidateSlice(rule))
                return error.InvalidIdentity;
            rule_bytes = std.math.add(usize, rule_bytes, rule.len) catch
                return error.ResourceLimit;
            if (rule_bytes > (core.permission_settings.RuleSetLimits{}).max_total_bytes)
                return error.ResourceLimit;
        }
    }
    if (allowed_tools.len > 1024) return error.ResourceLimit;
    for (allowed_tools) |name| {
        if (name.len == 0 or name.len > MAX_TOOL_IDENTITY_BYTES or
            !std.unicode.utf8ValidateSlice(name))
            return error.InvalidIdentity;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-policy-fingerprint\x00");
    hasher.update(&.{modeByte(mode) orelse return error.InvalidIdentity});
    hashBytes(&hasher, workspace.root);
    hashBytes(&hasher, workspace.home);
    hasher.update(&.{@intFromEnum(workspace.shell)});
    try hashSortedStrings(allocator, &hasher, "deny", rules.deny);
    try hashSortedStrings(allocator, &hasher, "ask", rules.ask);
    try hashSortedStrings(allocator, &hasher, "allow", rules.allow);
    try hashSortedStrings(allocator, &hasher, "tools", allowed_tools);
    var fingerprint: PolicyFingerprint = undefined;
    hasher.final(&fingerprint);
    return fingerprint;
}

fn hashSortedStrings(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    label: []const u8,
    values: []const []const u8,
) Error!void {
    const sorted = allocator.alloc([]const u8, values.len) catch
        return error.OutOfMemory;
    defer allocator.free(sorted);
    @memcpy(sorted, values);
    std.mem.sort([]const u8, sorted, {}, stringLessThan);
    hashBytes(hasher, label);
    hashU64(hasher, @intCast(sorted.len));
    for (sorted) |value| hashBytes(hasher, value);
}

/// Encode the AgentCore-owned Permission callback contract. The public ABI
/// projection is frozen only after all canonical seams close; this function
/// keeps request binding and response vocabulary independent from product UI
/// DTOs in the meantime.
pub fn encodeCallbackRequest(
    allocator: std.mem.Allocator,
    request: PermissionRequest,
    arguments_json: []const u8,
    options: CallbackEncodingOptions,
) Error![]u8 {
    try request.tool.validate();
    if (request.run_id == 0 or request.tool_call_id.len == 0 or
        request.policy_generation == 0 or arguments_json.len == 0)
        return error.InvalidIdentity;
    if (!std.unicode.utf8ValidateSlice(request.tool_call_id))
        return error.InvalidIdentity;
    if (!std.unicode.utf8ValidateSlice(arguments_json))
        return error.InvalidArguments;
    if (arguments_json.len > DEFAULT_MAX_ARGUMENT_BYTES)
        return error.ResourceLimit;

    const request_hex = std.fmt.bytesToHex(request.request_id, .lower);
    const binding_hex = std.fmt.bytesToHex(request.tool.binding, .lower);
    const arguments_hex = std.fmt.bytesToHex(
        request.arguments_digest,
        .lower,
    );
    var rule_hex: [RULE_ID_BYTES * 2]u8 = undefined;
    var candidate_dto: ?CallbackCandidateDto = null;
    if (request.candidate) |candidate| {
        if (!ToolIdentity.eql(candidate.tool, request.tool) or
            !std.mem.eql(
                u8,
                &candidate.arguments_digest,
                &request.arguments_digest,
            )) return error.InvalidIdentity;
        rule_hex = std.fmt.bytesToHex(candidate.rule_id, .lower);
        candidate_dto = .{
            .rule_id = &rule_hex,
            .scope = "exact_arguments",
        };
    }

    var responses_buffer: [4][]const u8 = undefined;
    var response_count: usize = 0;
    responses_buffer[response_count] = "deny_once";
    response_count += 1;
    if (request.candidate != null) {
        responses_buffer[response_count] = "deny_session";
        response_count += 1;
    }
    responses_buffer[response_count] = "allow_once";
    response_count += 1;
    if (request.candidate != null and options.allow_session_response) {
        responses_buffer[response_count] = "allow_session";
        response_count += 1;
    }

    const dto = CallbackRequestDto{
        .request_id = &request_hex,
        .session_id = request.session_id.asSlice(),
        .run_id = request.run_id,
        .tool_call_id = request.tool_call_id,
        .tool = .{
            .namespace = @tagName(request.tool.namespace),
            .name = request.tool.name,
            .binding = &binding_hex,
        },
        .canonical_arguments_digest = &arguments_hex,
        .policy_generation = request.policy_generation,
        .arguments_json = arguments_json,
        .responses = responses_buffer[0..response_count],
        .candidate = candidate_dto,
    };
    const raw = std.json.Stringify.valueAlloc(allocator, dto, .{}) catch
        return error.OutOfMemory;
    defer allocator.free(raw);
    return util_json.repairJsonUtf8(allocator, raw) catch
        return error.OutOfMemory;
}

/// Parse and bind a Host response to the exact pending request. Session-scoped
/// responses additionally echo the candidate identity; a Host cannot broaden
/// the candidate or replay a response from a different Run/generation.
pub fn decodeCallbackResponse(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    request: PermissionRequest,
    options: CallbackEncodingOptions,
) Error!Response {
    if (encoded.len == 0 or encoded.len > 16 * 1024)
        return error.InvalidResponse;
    var parsed = std.json.parseFromSlice(
        CallbackResponseDto,
        allocator,
        encoded,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
    defer parsed.deinit();
    var echoed_request_id: PermissionRequestId = undefined;
    decodeLowerHex(parsed.value.request_id, &echoed_request_id) catch
        return error.InvalidResponse;
    if (!std.mem.eql(u8, &echoed_request_id, &request.request_id) or
        parsed.value.policy_generation != request.policy_generation)
        return error.InvalidResponse;

    const response: Response = if (std.mem.eql(
        u8,
        parsed.value.permission,
        "deny_once",
    ))
        .deny_once
    else if (std.mem.eql(
        u8,
        parsed.value.permission,
        "deny_session",
    ))
        .deny_session
    else if (std.mem.eql(
        u8,
        parsed.value.permission,
        "allow_once",
    ))
        .allow_once
    else if (std.mem.eql(
        u8,
        parsed.value.permission,
        "allow_session",
    ))
        .allow_session
    else
        return error.InvalidResponse;

    switch (response) {
        .deny_once, .allow_once => if (parsed.value.rule_id != null)
            return error.InvalidResponse,
        .deny_session, .allow_session => {
            if (response == .allow_session and !options.allow_session_response)
                return error.InvalidResponse;
            const candidate = request.candidate orelse
                return error.InvalidResponse;
            const encoded_rule = parsed.value.rule_id orelse
                return error.InvalidResponse;
            var echoed_rule_id: RuleId = undefined;
            decodeLowerHex(encoded_rule, &echoed_rule_id) catch
                return error.InvalidResponse;
            if (!std.mem.eql(u8, &echoed_rule_id, &candidate.rule_id))
                return error.InvalidResponse;
        },
    }
    return response;
}

fn decodeLowerHex(encoded: []const u8, out: []u8) !void {
    if (encoded.len != out.len * 2) return error.InvalidHex;
    for (out, 0..) |*dest, index| {
        const high = lowerHexNibble(encoded[index * 2]) orelse
            return error.InvalidHex;
        const low = lowerHexNibble(encoded[index * 2 + 1]) orelse
            return error.InvalidHex;
        dest.* = (high << 4) | low;
    }
}

fn lowerHexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn hashValue(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    value: std.json.Value,
    depth: u16,
    nodes: *u32,
    limits: DigestLimits,
) Error!void {
    if (depth > limits.max_depth or nodes.* == limits.max_nodes)
        return error.ResourceLimit;
    nodes.* += 1;
    switch (value) {
        .null => hasher.update("n"),
        .bool => |item| hasher.update(if (item) "t" else "f"),
        .integer => |item| {
            hasher.update("i");
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &bytes, item, .little);
            hasher.update(&bytes);
        },
        .float => |item| {
            hasher.update("d");
            const normalized: f64 = if (item == 0) 0 else item;
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, @bitCast(normalized), .little);
            hasher.update(&bytes);
        },
        .number_string => |item| {
            hasher.update("q");
            hashBytes(hasher, item);
        },
        .string => |item| {
            hasher.update("s");
            hashBytes(hasher, item);
        },
        .array => |items| {
            hasher.update("a");
            hashU64(hasher, @intCast(items.items.len));
            for (items.items) |item|
                try hashValue(allocator, hasher, item, depth + 1, nodes, limits);
        },
        .object => |object| {
            hasher.update("o");
            hashU64(hasher, @intCast(object.count()));
            const keys = allocator.alloc([]const u8, object.count()) catch
                return error.OutOfMemory;
            defer allocator.free(keys);
            var iterator = object.iterator();
            var key_index: usize = 0;
            while (iterator.next()) |entry| : (key_index += 1)
                keys[key_index] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, stringLessThan);
            for (keys) |key| {
                hashBytes(hasher, key);
                try hashValue(
                    allocator,
                    hasher,
                    object.get(key).?,
                    depth + 1,
                    nodes,
                    limits,
                );
            }
        },
    }
}

pub fn isKnownBuiltin(name: []const u8) bool {
    return core.agent_session.isSessionBuiltin(name);
}

fn hashToolIdentity(hasher: *std.crypto.hash.sha2.Sha256, tool: ToolIdentity) void {
    hasher.update(&.{@intFromEnum(tool.namespace)});
    hashBytes(hasher, tool.name);
    hasher.update(&tool.binding);
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn isCanonicalMode(mode: core.types.PermissionMode) bool {
    return modeByte(mode) != null;
}

fn modeByte(mode: core.types.PermissionMode) ?u8 {
    return switch (mode) {
        .default => 0,
        .accept_edits => 1,
        .plan => 2,
        .auto => 3,
        .dont_ask => 4,
        .bypass_permissions => 5,
        .prompt, .bypass => null,
    };
}

fn modeFromByte(raw: u8) ?core.types.PermissionMode {
    const mode: core.types.PermissionMode = switch (raw) {
        0 => .default,
        1 => .accept_edits,
        2 => .plan,
        3 => .auto,
        4 => .dont_ask,
        5 => .bypass_permissions,
        else => return null,
    };
    return mode;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "Revision 6 Permission argument digest is semantic and bounded" {
    const allocator = std.testing.allocator;
    const first = try digestCanonicalArguments(
        allocator,
        "{\"path\":\"a\",\"options\":{\"b\":2,\"a\":1},\"items\":[true,null]}",
        .{},
    );
    const reordered = try digestCanonicalArguments(
        allocator,
        " { \"items\" : [ true , null ], \"options\" : {\"a\":1,\"b\":2}, \"path\":\"a\" } ",
        .{},
    );
    try std.testing.expectEqualSlices(u8, &first, &reordered);

    const different_order = try digestCanonicalArguments(
        allocator,
        "{\"items\":[null,true],\"options\":{\"a\":1,\"b\":2},\"path\":\"a\"}",
        .{},
    );
    try std.testing.expect(!std.mem.eql(u8, &first, &different_order));
    try std.testing.expectError(
        error.InvalidArguments,
        digestCanonicalArguments(allocator, "[]", .{}),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        digestCanonicalArguments(allocator, "{\"a\":1,\"a\":2}", .{}),
    );
    try std.testing.expectError(
        error.ResourceLimit,
        digestCanonicalArguments(allocator, "{\"a\":1}", .{ .max_input_bytes = 4 }),
    );
    try std.testing.expectError(
        error.ResourceLimit,
        digestCanonicalArguments(
            allocator,
            "{\"a\":{\"b\":1}}",
            .{ .max_depth = 1 },
        ),
    );
}

test "Revision 6 Permission candidates never invent Host canonicalizers" {
    const digest = [_]u8{0x5a} ** ARGUMENT_DIGEST_BYTES;
    const builtin = (try deriveRuleCandidate(.{
        .namespace = .builtin,
        .name = "Bash",
    }, digest)).?;
    try std.testing.expectEqual(CandidateScope.exact_arguments, builtin.scope);

    const host_binding = [_]u8{0x11} ** 32;
    try std.testing.expect((try deriveRuleCandidate(.{
        .namespace = .host,
        .name = "Deploy",
        .binding = host_binding,
    }, digest)) == null);

    const mcp_binding = [_]u8{0x22} ** 32;
    try std.testing.expect((try deriveRuleCandidate(.{
        .namespace = .mcp,
        .name = "mcp__repo__search",
        .binding = mcp_binding,
    }, digest)) != null);
    try std.testing.expectError(error.InvalidIdentity, deriveRuleCandidate(.{
        .namespace = .host,
        .name = "Deploy",
    }, digest));
}

test "Revision 6 Permission request identity binds every execution fact" {
    const session_id = core.session_id.SessionId.fromSlice(
        "0000000000000000000000aa",
    ).?;
    const digest = [_]u8{0x33} ** ARGUMENT_DIGEST_BYTES;
    const tool = ToolIdentity{ .namespace = .builtin, .name = "Write" };
    const first = try deriveRequestId(
        session_id,
        7,
        "tool-call-1",
        tool,
        digest,
        4,
        1,
    );
    const next_generation = try deriveRequestId(
        session_id,
        7,
        "tool-call-1",
        tool,
        digest,
        5,
        1,
    );
    const next_request = try deriveRequestId(
        session_id,
        7,
        "tool-call-1",
        tool,
        digest,
        4,
        2,
    );
    try std.testing.expect(!std.mem.eql(u8, &first, &next_generation));
    try std.testing.expect(!std.mem.eql(u8, &first, &next_request));
    try std.testing.expectError(error.InvalidIdentity, deriveRequestId(
        session_id,
        0,
        "tool-call-1",
        tool,
        digest,
        4,
        1,
    ));
}

test "Revision 6 Permission callback binds response to request and candidate" {
    const allocator = std.testing.allocator;
    const session_id = core.session_id.SessionId.fromSlice(
        "0000000000000000000000ab",
    ).?;
    const digest = [_]u8{0x61} ** ARGUMENT_DIGEST_BYTES;
    const tool = ToolIdentity{ .namespace = .builtin, .name = "Bash" };
    const candidate = (try deriveRuleCandidate(tool, digest)).?;
    const request_id = try deriveRequestId(
        session_id,
        8,
        "tool-call-bound",
        tool,
        digest,
        3,
        1,
    );
    const request = PermissionRequest{
        .session_id = session_id,
        .run_id = 8,
        .tool_call_id = "tool-call-bound",
        .model_tool_name = "Bash",
        .request_id = request_id,
        .tool = tool,
        .arguments_digest = digest,
        .policy_generation = 3,
        .candidate = candidate,
    };
    const encoded = try encodeCallbackRequest(
        allocator,
        request,
        "{\"command\":\"git status\"}",
        .{},
    );
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "allow_session",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "tool-call-bound",
    ) != null);

    const request_hex = std.fmt.bytesToHex(request_id, .lower);
    const rule_hex = std.fmt.bytesToHex(candidate.rule_id, .lower);
    const response_json = try std.fmt.allocPrint(
        allocator,
        "{{\"permission\":\"allow_session\",\"request_id\":\"{s}\",\"policy_generation\":3,\"rule_id\":\"{s}\"}}",
        .{ request_hex, rule_hex },
    );
    defer allocator.free(response_json);
    try std.testing.expectEqual(
        Response.allow_session,
        try decodeCallbackResponse(allocator, response_json, request, .{}),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        decodeCallbackResponse(
            allocator,
            response_json,
            request,
            .{ .allow_session_response = false },
        ),
    );

    const stale_response = try std.fmt.allocPrint(
        allocator,
        "{{\"permission\":\"allow_once\",\"request_id\":\"{s}\",\"policy_generation\":4}}",
        .{request_hex},
    );
    defer allocator.free(stale_response);
    try std.testing.expectError(
        error.InvalidResponse,
        decodeCallbackResponse(allocator, stale_response, request, .{}),
    );

    var malformed_identity = request;
    const malformed_tool_call_id = [_]u8{0x80};
    malformed_identity.tool_call_id = malformed_tool_call_id[0..];
    try std.testing.expectError(
        error.InvalidIdentity,
        encodeCallbackRequest(allocator, malformed_identity, "{\"command\":\"git status\"}", .{}),
    );
    const malformed_arguments = [_]u8{ '{', '"', 'x', '"', ':', 0xC3, '}' };
    try std.testing.expectError(
        error.InvalidArguments,
        encodeCallbackRequest(allocator, request, malformed_arguments[0..], .{}),
    );
}

test "Revision 6 Permission Host binding uses semantic schema identity" {
    const allocator = std.testing.allocator;
    const first = try deriveHostBinding(
        allocator,
        "Deploy",
        "{\"type\":\"object\",\"properties\":{\"env\":{\"type\":\"string\"}}}",
    );
    const reordered = try deriveHostBinding(
        allocator,
        "Deploy",
        "{ \"properties\" : {\"env\":{\"type\":\"string\"}}, \"type\":\"object\" }",
    );
    try std.testing.expectEqualSlices(u8, &first, &reordered);
    try std.testing.expect(!allZero(&first));
}

test "Revision 6 Permission explicit action priority ignores narrower allow" {
    var settings = try core.permission_settings.buildRuleSet(
        std.testing.allocator,
        .{
            .allow = &.{"Bash(git *)"},
            .ask = &.{"Bash(*)"},
        },
        .{},
    );
    defer settings.deinit();
    const context = core.permission_rule_spec.MatchContext{};
    try std.testing.expectEqual(
        ExplicitAction.ask,
        evaluateExplicit(
            &settings,
            &context,
            "Bash",
            "{\"command\":\"git status\"}",
        ),
    );

    var denied = try core.permission_settings.buildRuleSet(
        std.testing.allocator,
        .{
            .allow = &.{"Bash(git *)"},
            .ask = &.{"Bash(*)"},
            .deny = &.{"Bash(git status)"},
        },
        .{},
    );
    defer denied.deinit();
    try std.testing.expectEqual(
        ExplicitAction.deny,
        evaluateExplicit(
            &denied,
            &context,
            "Bash",
            "{\"command\":\"git status\"}",
        ),
    );
}

test "Revision 6 Permission Session state implements fixed action priority" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 3);
    defer state.deinit();
    const tool = ToolIdentity{ .namespace = .builtin, .name = "Bash" };
    const digest = [_]u8{0x44} ** ARGUMENT_DIGEST_BYTES;
    const candidate = (try deriveRuleCandidate(tool, digest)).?;
    _ = try state.remember(.allow_session, candidate, 3);

    var result = try state.decide(tool, digest, .ask, .{
        .decision = .deny,
        .source = .mode_fallback,
    });
    try std.testing.expectEqual(Decision.ask, result.decision);
    try std.testing.expectEqual(DecisionSource.explicit_ask, result.source);

    result = try state.decide(tool, digest, .undecided, .{
        .decision = .ask,
        .source = .mode_fallback,
    });
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(DecisionSource.session_allow, result.source);
    try std.testing.expect(result.used_session_rule);

    _ = try state.remember(.deny_session, candidate, 3);
    result = try state.decide(tool, digest, .allow, .{
        .decision = .allow,
        .source = .mode_fallback,
    });
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqual(DecisionSource.session_deny, result.source);
    try std.testing.expectEqual(@as(usize, 2), state.ruleCount());

    const other_digest = [_]u8{0x45} ** ARGUMENT_DIGEST_BYTES;
    result = try state.decide(tool, other_digest, .undecided, .{
        .decision = .ask,
        .source = .mode_fallback,
    });
    try std.testing.expectEqual(Decision.ask, result.decision);
    try std.testing.expect(!result.used_session_rule);
}

test "Revision 6 Permission Session state is generation-bound and bounded" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 9);
    defer state.deinit();
    const tool = ToolIdentity{ .namespace = .builtin, .name = "Write" };
    const digest = [_]u8{0x52} ** ARGUMENT_DIGEST_BYTES;
    const candidate = (try deriveRuleCandidate(tool, digest)).?;
    try std.testing.expectError(
        error.InvalidIdentity,
        state.remember(.allow_session, candidate, 8),
    );
    try std.testing.expectEqual(
        RememberResult.added,
        try state.remember(.allow_session, candidate, 9),
    );
    try std.testing.expectEqual(
        RememberResult.already_present,
        try state.remember(.allow_session, candidate, 9),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        state.remember(.allow_once, candidate, 9),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        state.remember(.deny_once, candidate, 9),
    );
}

test "Revision 6 Permission concurrent Sessions isolate grants" {
    const Worker = struct {
        state: *State,
        tool: ToolIdentity,
        digest: ArgumentsDigest,
        expected: Decision,
        failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var iteration: usize = 0;
            while (iteration < 2_000) : (iteration += 1) {
                const result = self.state.decide(
                    self.tool,
                    self.digest,
                    .undecided,
                    .{ .decision = .ask, .source = .mode_fallback },
                ) catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (result.decision != self.expected) {
                    self.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var first = try State.init(std.testing.allocator, 1);
    defer first.deinit();
    var second = try State.init(std.testing.allocator, 1);
    defer second.deinit();
    const tool = ToolIdentity{ .namespace = .builtin, .name = "Bash" };
    const digest = [_]u8{0x61} ** ARGUMENT_DIGEST_BYTES;
    const candidate = (try deriveRuleCandidate(tool, digest)).?;
    _ = try first.remember(.allow_session, candidate, 1);
    var failed = std.atomic.Value(bool).init(false);
    var first_worker = Worker{
        .state = &first,
        .tool = tool,
        .digest = digest,
        .expected = .allow,
        .failed = &failed,
    };
    var second_worker = Worker{
        .state = &second,
        .tool = tool,
        .digest = digest,
        .expected = .ask,
        .failed = &failed,
    };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first_worker});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second_worker});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "Revision 6 Permission policy fingerprint is semantic over rule and tool order" {
    const allocator = std.testing.allocator;
    const workspace = core.agent_session.WorkspaceConfig{
        .root = "/workspace",
        .home = "/home/test",
        .shell = .sandboxed,
    };
    const first = try computePolicyFingerprint(
        allocator,
        .default,
        .{
            .allow = &.{ "Read(*)", "Bash(git status:*)" },
            .deny = &.{"Write(.env)"},
        },
        workspace,
        &.{ "Read", "Bash", "Write" },
    );
    const reordered = try computePolicyFingerprint(
        allocator,
        .default,
        .{
            .allow = &.{ "Bash(git status:*)", "Read(*)" },
            .deny = &.{"Write(.env)"},
        },
        workspace,
        &.{ "Write", "Read", "Bash" },
    );
    try std.testing.expectEqualSlices(u8, &first, &reordered);
    const changed = try computePolicyFingerprint(
        allocator,
        .default,
        .{ .deny = &.{"Write(*)"} },
        workspace,
        &.{ "Read", "Bash", "Write" },
    );
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "Revision 6 Permission checkpoint restores compatible rules or starts a new generation" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 9);
    defer state.deinit();
    const bash = ToolIdentity{ .namespace = .builtin, .name = "Bash" };
    const write = ToolIdentity{ .namespace = .builtin, .name = "Write" };
    const bash_digest = [_]u8{0x71} ** ARGUMENT_DIGEST_BYTES;
    const write_digest = [_]u8{0x72} ** ARGUMENT_DIGEST_BYTES;
    _ = try state.remember(
        .allow_session,
        (try deriveRuleCandidate(bash, bash_digest)).?,
        9,
    );
    _ = try state.remember(
        .deny_session,
        (try deriveRuleCandidate(write, write_digest)).?,
        9,
    );
    const fingerprint = [_]u8{0x73} ** 32;
    const encoded = try state.encodeCheckpoint(
        allocator,
        .default,
        fingerprint,
    );
    defer allocator.free(encoded);
    var decoded = try decodeCheckpoint(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 9), decoded.policy_generation);
    try std.testing.expectEqual(@as(usize, 2), decoded.rules.len);

    var compatible = try reconcileCheckpoint(
        allocator,
        &decoded,
        .default,
        fingerprint,
        // Current authority is deliberately wider than the checkpoint. Only
        // persisted Session rules may be reconstructed; newly available Edit
        // authority remains governed by the current fallback/rules.
        &.{ "Bash", "Write", "Edit" },
    );
    defer compatible.deinit();
    try std.testing.expect(compatible.fingerprint_compatible);
    try std.testing.expectEqual(@as(u64, 9), compatible.policy_generation);
    try std.testing.expectEqual(@as(u32, 2), compatible.restored);
    var decision = try compatible.state.?.decide(
        bash,
        bash_digest,
        .undecided,
        .{ .decision = .ask, .source = .mode_fallback },
    );
    try std.testing.expectEqual(Decision.allow, decision.decision);
    decision = try compatible.state.?.decide(
        write,
        write_digest,
        .allow,
        .{ .decision = .allow, .source = .mode_fallback },
    );
    try std.testing.expectEqual(Decision.deny, decision.decision);
    decision = try compatible.state.?.decide(
        .{ .namespace = .builtin, .name = "Edit" },
        [_]u8{0x73} ** ARGUMENT_DIGEST_BYTES,
        .undecided,
        .{ .decision = .ask, .source = .mode_fallback },
    );
    try std.testing.expectEqual(Decision.ask, decision.decision);
    try std.testing.expect(!decision.used_session_rule);
    try std.testing.expect(decision.matched_rule_id == null);

    var incompatible = try reconcileCheckpoint(
        allocator,
        &decoded,
        .dont_ask,
        [_]u8{0x74} ** 32,
        &.{ "Bash", "Write" },
    );
    defer incompatible.deinit();
    try std.testing.expect(!incompatible.fingerprint_compatible);
    try std.testing.expectEqual(@as(u64, 10), incompatible.policy_generation);
    try std.testing.expectEqual(@as(u32, 0), incompatible.restored);
    try std.testing.expectEqual(@as(u32, 2), incompatible.invalidated);

    const corrupt = try allocator.dupe(u8, encoded);
    defer allocator.free(corrupt);
    corrupt[checkpoint_header_bytes + 72] ^= 1;
    try std.testing.expectError(
        error.InvalidArguments,
        decodeCheckpoint(allocator, corrupt),
    );
}

test "Revision 6 Permission successful policy replacement clears Session grants" {
    var state = try State.init(std.testing.allocator, 4);
    defer state.deinit();
    const digest = [_]u8{0x75} ** ARGUMENT_DIGEST_BYTES;
    _ = try state.remember(
        .allow_session,
        (try deriveRuleCandidate(.{
            .namespace = .builtin,
            .name = "Read",
        }, digest)).?,
        4,
    );
    try state.replaceGeneration(5);
    try std.testing.expectEqual(@as(u64, 5), state.generation());
    try std.testing.expectEqual(@as(usize, 0), state.ruleCount());
    try std.testing.expectError(
        error.InvalidIdentity,
        state.replaceGeneration(5),
    );
}
