//! The client side of a sealed Skill run, shaped as a model Provider
//! (doc/SEALED_SKILL_PROTOCOL.md §9 "Activation").
//!
//! A forked Skill runs the ordinary subagent loop; this Provider replaces the
//! model. Its first `sendStream` opens the run (`runs.start`) with everything
//! the fork's own model call would have carried — the system prompt, the tool
//! definitions the pin allows, the model, the request parameters and the
//! client's provider route — so the gateway's shadow of the fork makes the
//! same request the client would have (§9.1 "Mirror"), over the client's own
//! provider account (§8.1). Every later `sendStream` takes the `tool_result`
//! blocks the loop appended and sends them (`runs.continue`). Each Step comes
//! back as neutral stream events — `tool_use_start` per call, `usage`, `done`
//! — so dispatch, permission, sandbox, artifact storage and observation are
//! untouched. The brain's narration between calls never reaches the loop;
//! only a `final` Step carries text.
//!
//! What this module enforces on its own, because the gateway is untrusted:
//! the hash chain and `seq` of every Step (§8.3), the result size caps (§6.3),
//! the policy-violation count that cancels a run (§6.2), the cost cap (§6.5),
//! the ledger (§6.6), credential substitution and redaction (§6.4), and the
//! `confirm: true` marks handed to the child's permission context through
//! its confirm gate (§6.2). An `input_required` Step is put to the user with
//! the client's own `AskUserQuestion` tool over the session's UI requester
//! and the answer goes back as the one result of the next `runs.continue`
//! (§4.3). The tool allowlist itself is enforced by the Skill's policy frame
//! before dispatch; this module only classifies the refusal.

const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const pin_mod = @import("pin.zig");
const ledger = @import("ledger.zig");
const credentials = @import("credentials.zig");
const util_time = @import("../../util/time.zig");
const util_json = @import("../../util/json.zig");
const provider_mod = @import("../../api/provider.zig");
const api_stream = @import("../../api/stream.zig");
const api_request = @import("../../api/request.zig");
const types = @import("../../types.zig");
const json_mod = @import("../../json.zig");
const log = @import("../../util/log.zig");
const confirm_gate = @import("../../permission/confirm_gate.zig");
const ui_request = @import("../../core/protocol/ui_request.zig");
const tool_context = @import("../../tools/context.zig");
const ask_user = @import("../../tools/ask_user.zig");
const SessionId = @import("../../core/session_id.zig").SessionId;
const AbortSignal = @import("../../util/abort.zig").AbortSignal;

pub const DEFAULT_MAX_COST_MICROS: i64 = 500_000;
/// Admission retries (§2): how often a refused Step is resent before the
/// run fails, and the bounds on each wait the gateway may ask for.
pub const MAX_ADMISSION_RETRIES: u32 = 8;
pub const MIN_ADMISSION_WAIT_MS: u64 = 100;
pub const MAX_ADMISSION_WAIT_MS: u64 = 30_000;
pub const DEFAULT_MAX_STEPS: u64 = 200;
const POLICY_CANCEL_TEXT = "[sealed skill cancelled: the gateway requested tools outside the pinned policy (allowlist or egress classes)]";

/// §6.2: policy violations in one run before the client cancels it.
pub const MAX_POLICY_VIOLATIONS: u8 = 3;
/// Model name the loop sees; its price table is only ever an estimate here.
pub const MODEL_PREFIX = "sealed:";
/// Longest answer accepted for an `input_required` question.
pub const MAX_ANSWER_BYTES: usize = 64 * 1024;
/// The client's question tool: always advertised to the gateway, outside the
/// allowlist, because a question to the user is the user's to answer.
pub const ASK_USER_TOOL = "AskUserQuestion";
/// The context window the client's fork loop believes it has. The brain's
/// conversation lives on the gateway, which compacts it; the client's copy
/// is only a mirror for pairing results, so it must never compact.
const NO_COMPACTION_INPUT_TOKENS: u32 = 8_000_000;

pub const Error = error{
    OutOfMemory,
    /// The pinned digest is no longer current (§6.1); re-consent is needed.
    SealedManifestChanged,
    SealedUnauthorized,
    SealedSubscriptionRequired,
    /// Gateway or transport failure named in the log.
    SealedGatewayError,
    /// A Step broke the hash chain or sequence (§8.3, §8.4).
    SealedChainBroken,
    /// The loop called again after the run ended.
    SealedRunFinished,
    SealedNoPrompt,
    /// `<state root>/sealed-credentials.json` exists but cannot be read.
    SealedCredentialsUnreadable,
    /// The client's provider cannot be delegated to a gateway (§8.1): it has
    /// no route, or its authentication cannot be carried in a header.
    SealedProviderRouteUnavailable,
};

pub const Options = struct {
    /// Owned by the provider from here on.
    pin: pin_mod.ParsedPin,
    token: []const u8,
    max_cost_micros: i64 = DEFAULT_MAX_COST_MICROS,
    max_steps: u64 = DEFAULT_MAX_STEPS,
    session_id: []const u8,
    /// "" disables the ledger and the credential store (tests without a
    /// state root).
    state_root: []const u8,
    client_version: []const u8,
    client_platform: []const u8,
    locale: []const u8 = "",
    /// Where an `input_required` question is put to the user. Null means no
    /// channel: such a Step ends the run with the question as the fork's text.
    ui: ?ui_request.UiRequester = null,
    /// The session the question dialog is routed to.
    session: SessionId = .single,
    /// The client's own provider: the fork's model, whose capabilities,
    /// output cap and reasoning effort this provider answers for so the loop
    /// advertises to the gateway exactly what it would have advertised to it,
    /// and whose route (§8.1) is read **before every request** — a refreshed
    /// token or a switched key is picked up, never a stale copy. Must outlive
    /// this provider.
    origin: provider_mod.Provider,
    /// The pin directory: the Skill's base directory as the brain sees it,
    /// where its public assets were installed.
    base_dir: []const u8,
    /// The user's positional arguments, rendered into the body on the gateway
    /// exactly as a local fork would render them.
    arguments: []const []const u8 = &.{},
};

const PreRefusal = struct {
    refusal: protocol.Refusal,
    message: []const u8,
};

const CallRef = struct {
    id: []const u8,
    name: []const u8,
    result_limit_bytes: ?u64,
    confirm: bool,
    /// Credential references the call listed and this client bound; their
    /// values are substituted on the way in and redacted on the way out.
    credential_refs: []const []const u8,
    /// Set when the call must not reach dispatch (an unbound credential):
    /// no `tool_use` is streamed and this is its result.
    pre_refusal: ?PreRefusal,
};

const Run = struct {
    run_id: []const u8,
    run_state: []const u8,
    seq: u64,
    last_digest: []const u8,
    calls: []const CallRef,
    cumulative_cost_micros: i64 = 0,
    finished: bool = false,
    violations: u8 = 0,
    /// §8.3: the digest of the results sent for this Step, to be echoed by
    /// the next one; "" until `runs.continue` is sent.
    sent_results_digest: []const u8 = "",
};

pub const SealedSkillProvider = struct {
    allocator: std.mem.Allocator,
    transport: transport.Client,
    pin: pin_mod.ParsedPin,
    credentials: credentials.Store,
    max_cost_micros: i64,
    max_steps: u64,
    session_id: []u8,
    state_root: []u8,
    client_version: []u8,
    client_platform: []u8,
    model_name: []u8,
    ui: ?ui_request.UiRequester,
    session: SessionId,
    origin: provider_mod.Provider,
    base_dir: []u8,
    arguments: []const []u8,
    /// Everything the current run owns; reset per Step.
    run_arena: std.heap.ArenaAllocator,
    run: ?Run = null,
    /// Notes for the user that outlive the Step they arose in (a credential
    /// the Skill needed and the user has not bound); prepended to the final
    /// text so the person running the Skill sees what to do.
    notices: std.ArrayList([]u8) = .empty,
    /// The last failure `sendStream` returned. The child loop reports a model
    /// failure as an empty run; the fork reads this to surface the real cause.
    last_error: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*SealedSkillProvider {
        const self = try allocator.create(SealedSkillProvider);
        errdefer allocator.destroy(self);
        var pin = options.pin;
        errdefer pin.deinit();
        // Fail at activation, not at the first Step, when the session's
        // provider cannot be delegated at all; the route itself is re-read
        // before every request.
        _ = try routeOf(options.origin);
        const model_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ MODEL_PREFIX, pin.pin.entry.skill_id });
        errdefer allocator.free(model_name);
        const session_id = try allocator.dupe(u8, options.session_id);
        errdefer allocator.free(session_id);
        const state_root = try allocator.dupe(u8, options.state_root);
        errdefer allocator.free(state_root);
        const client_version = try allocator.dupe(u8, options.client_version);
        errdefer allocator.free(client_version);
        const client_platform = try allocator.dupe(u8, options.client_platform);
        errdefer allocator.free(client_platform);
        const base_dir = try allocator.dupe(u8, options.base_dir);
        errdefer allocator.free(base_dir);
        const arguments = try allocator.alloc([]u8, options.arguments.len);
        errdefer allocator.free(arguments);
        var copied: usize = 0;
        errdefer for (arguments[0..copied]) |argument| allocator.free(argument);
        for (options.arguments, arguments) |source, *slot| {
            slot.* = try allocator.dupe(u8, source);
            copied += 1;
        }
        var store = credentials.load(allocator, options.state_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("sealed", "credential store unreadable: {s}", .{@errorName(err)});
                return error.SealedCredentialsUnreadable;
            },
        };
        errdefer store.deinit();
        const client = try transport.Client.init(allocator, io, pin.pin.gateway_url, options.token);
        self.* = .{
            .allocator = allocator,
            .transport = client,
            .pin = pin,
            .credentials = store,
            .max_cost_micros = options.max_cost_micros,
            .max_steps = options.max_steps,
            .session_id = session_id,
            .state_root = state_root,
            .client_version = client_version,
            .client_platform = client_platform,
            .model_name = model_name,
            .ui = options.ui,
            .session = options.session,
            .origin = options.origin,
            .base_dir = base_dir,
            .arguments = arguments,
            .run_arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *SealedSkillProvider) void {
        // A run the loop abandoned (abort, error) is cancelled so the gateway
        // charges nothing further; best effort, the ledger already holds what
        // was charged up to the last Step.
        if (self.run) |run| if (!run.finished) self.cancelRun(.client_error, null);
        for (self.notices.items) |notice| self.allocator.free(notice);
        self.notices.deinit(self.allocator);
        self.run_arena.deinit();
        self.transport.deinit();
        self.credentials.deinit();
        self.pin.deinit();
        for (self.arguments) |argument| self.allocator.free(argument);
        self.allocator.free(self.arguments);
        self.allocator.free(self.base_dir);
        self.allocator.free(self.model_name);
        self.allocator.free(self.client_platform);
        self.allocator.free(self.client_version);
        self.allocator.free(self.state_root);
        self.allocator.free(self.session_id);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn provider(self: *SealedSkillProvider) provider_mod.Provider {
        return .{
            .ctx = @ptrCast(self),
            .modelFn = modelFn,
            .sendStreamFn = sendStreamFn,
            .sendStreamRetryFn = sendStreamRetryFn,
            .sendFn = sendFn,
            .cancelFn = cancelFn,
            .maxTokensFn = maxTokensFn,
            .maxInputTokensFn = maxInputTokensFn,
            .reasoningEffortFn = reasoningEffortFn,
            .supportsFn = supportsFn,
            .supportsForModelFn = supportsForModelFn,
            .endpointIdFn = endpointIdFn,
        };
    }

    /// The gate the child's permission context consults (§6.2 `confirm`):
    /// true for a call of the current Step the gateway marked `confirm: true`.
    pub fn confirmGate(self: *SealedSkillProvider) confirm_gate.ConfirmGate {
        return .{ .ctx = @ptrCast(self), .requiresFn = &confirmRequiresFn };
    }

    fn confirmRequiresFn(ctx: *anyopaque, tool_use_id: []const u8, _: []const u8) bool {
        const self = cast(ctx);
        const run = self.run orelse return false;
        const call = findCall(run.calls, tool_use_id) orelse return false;
        return call.confirm;
    }

    pub fn manifest(self: *const SealedSkillProvider) *const protocol.Manifest {
        return &self.pin.pin.entry.manifest;
    }

    /// The cap in the loop's own unit, for its secondary estimate-based stop.
    pub fn costBudgetUsd(self: *const SealedSkillProvider) ?f64 {
        if (self.max_cost_micros <= 0) return null;
        return @as(f64, @floatFromInt(self.max_cost_micros)) / 1_000_000.0;
    }

    /// The loop's turn cap for a sealed fork: the protocol's step cap. The
    /// brain's iteration belongs to the gateway; the client loop is its
    /// executor and sets no shorter limit of its own.
    pub fn maxTurns(self: *const SealedSkillProvider) u32 {
        return @intCast(@min(self.max_steps, std.math.maxInt(u32)));
    }

    pub fn cumulativeCostMicros(self: *const SealedSkillProvider) i64 {
        return if (self.run) |run| run.cumulative_cost_micros else 0;
    }

    // ── Provider vtable ───────────────────────────────────────────────────

    fn cast(ctx: *anyopaque) *SealedSkillProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn modelFn(ctx: *anyopaque) []const u8 {
        return cast(ctx).model_name;
    }

    fn endpointIdFn(ctx: *anyopaque) []const u8 {
        return cast(ctx).pin.pin.gateway_url;
    }

    fn sendStreamFn(
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        _: ?json_mod.ToolChoice,
        _: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        const self = cast(ctx);
        if (self.run) |run| if (run.finished) {
            self.last_error = error.SealedRunFinished;
            return error.SealedRunFinished;
        };
        const outcome = if (self.run != null) self.continueRun(messages, abort) else self.startRun(messages, system, tools, model_override, abort);
        return outcome catch |err| {
            self.last_error = err;
            return err;
        };
    }

    pub fn lastError(self: *const SealedSkillProvider) ?anyerror {
        return self.last_error;
    }

    fn sendStreamRetryFn(
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        _: u32,
        _: u64,
        _: ?provider_mod.RetryReporter,
        user_query: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        // A gateway call is not idempotent at the protocol level (§8.4: a
        // re-sent `seq` is rejected), so there is no transport retry here.
        return sendStreamFn(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }

    fn sendFn(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?[]const u8) anyerror!provider_mod.ApiResponse {
        // Compaction summaries would send the fork's conversation to the
        // gateway as free text; the brain's conversation is compacted on the
        // gateway, the client's mirror never is.
        return error.SealedProviderNoSummaries;
    }

    fn cancelFn(ctx: *anyopaque, signal: *const AbortSignal) void {
        cast(ctx).transport.cancel(signal);
    }

    // The fork's loop asks its provider what the model can do and how much
    // it may emit; the answers are the client's own provider's, so the loop
    // advertises and bounds exactly what a local fork would (§9.1).
    fn maxTokensFn(ctx: *anyopaque) u32 {
        return cast(ctx).origin.maxTokens();
    }

    fn maxInputTokensFn(_: *anyopaque) u32 {
        return NO_COMPACTION_INPUT_TOKENS;
    }

    fn reasoningEffortFn(ctx: *anyopaque) ?types.ReasoningEffort {
        return cast(ctx).origin.reasoningEffort();
    }

    fn supportsFn(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        return cast(ctx).origin.supports(cap);
    }

    fn supportsForModelFn(ctx: *anyopaque, cap: provider_mod.Capability, model: []const u8) bool {
        return cast(ctx).origin.supportsForModel(cap, model);
    }

    // ── Run lifecycle ─────────────────────────────────────────────────────

    fn startRun(
        self: *SealedSkillProvider,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        model_override: ?[]const u8,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const prompt = try firstUserText(arena, messages);
        if (prompt.len == 0) return error.SealedNoPrompt;
        const route = try self.currentRoute();
        defer self.transport.provider_credential = "";
        const split = try self.toolsJson(arena, tools orelse &.{});
        const arguments = try arena.alloc([]const u8, self.arguments.len);
        for (self.arguments, arguments) |argument, *slot| slot.* = argument;
        log.info("sealed", "runs.start skill={s} model={s} tools={d} provider_tools={d} max_steps={d} max_cost_micros={d} base_dir={s}", .{
            self.pin.pin.entry.skill_id, model_override orelse route.model, split.client_count, split.provider_count, self.max_steps, self.max_cost_micros, self.base_dir,
        });
        var params: std.Io.Writer.Allocating = .init(arena);
        try protocol.writeStartParams(&params.writer, .{
            .skill_id = self.pin.pin.entry.skill_id,
            .manifest_digest = self.pin.pin.entry.manifest_digest,
            .prompt = prompt,
            .arguments = arguments,
            .tools_json = split.client,
            .max_cost_micros = self.max_cost_micros,
            .max_steps = self.max_steps,
            .client_name = "metacodes",
            .client_version = self.client_version,
            .client_platform = self.client_platform,
            .run_ref = self.session_id,
            .system = system orelse "",
            .base_dir = self.base_dir,
            .provider_kind = @tagName(route.kind),
            .provider_base_url = route.base_url,
            .provider_openai_protocol = if (route.kind == .openai) @tagName(route.openai_protocol) else "",
            .provider_auth_json = try authJson(arena, route.auth_scheme),
            .provider_tools_json = split.provider,
            .model = model_override orelse route.model,
            .max_tokens = self.origin.maxTokensFor(model_override),
            .reasoning_effort = if (self.origin.reasoningEffort()) |effort| @tagName(effort) else "",
        });
        var response = try self.callAdmitted(.runs_start, params.written(), abort);
        defer response.deinit();
        return self.consumeResponse(&response, null);
    }

    fn continueRun(
        self: *SealedSkillProvider,
        messages: []const types.ApiMessage,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        var results: std.ArrayList(protocol.ResultEntry) = .empty;
        if (messages.len == 0) return error.SealedChainBroken;
        const last = messages[messages.len - 1];
        for (last.content) |block| switch (block) {
            .tool_result => |result| {
                const call = findCall(run.calls, result.tool_use_id) orelse continue;
                if (call.pre_refusal != null) continue; // never dispatched; answered below
                var entry: protocol.ResultEntry = .{
                    .tool_use_id = result.tool_use_id,
                    .content = result.content,
                    .is_error = result.is_error,
                };
                // §6.4: the secret's value never reaches the gateway. Redact
                // before truncation so a cut cannot leave part of it behind.
                if (call.credential_refs.len != 0) {
                    const redacted = try self.redact(arena, entry.content, call.credential_refs);
                    entry.content = redacted.content;
                    entry.redactions = redacted.refs;
                }
                const limit = @min(call.result_limit_bytes orelse std.math.maxInt(u64), self.manifest().egress_max_result_bytes);
                if (entry.content.len > limit) {
                    entry.content = try truncateResult(arena, entry.content, @intCast(limit));
                    entry.truncated = true;
                }
                if (!self.toolAllowed(call.name)) {
                    // The frame refused this before dispatch; the gateway is
                    // told so and the violation is counted (§6.2).
                    entry.refusal = .policy_violation;
                    entry.is_error = true;
                    run.violations +|= 1;
                } else if (entry.is_error and isPermissionDenied(entry.content)) {
                    // The user (or the permission chain) declined the call.
                    entry.refusal = .permission_denied;
                }
                try results.append(arena, entry);
            },
            else => {},
        };
        for (run.calls) |call| if (call.pre_refusal) |refusal| {
            try results.append(arena, .{
                .tool_use_id = call.id,
                .content = refusal.message,
                .is_error = true,
                .refusal = refusal.refusal,
            });
        };
        if (results.items.len != run.calls.len) {
            log.warn("sealed", "run {s}: {d} results for {d} calls", .{ run.run_id, results.items.len, run.calls.len });
            return error.SealedChainBroken;
        }
        if (run.violations >= MAX_POLICY_VIOLATIONS) {
            self.cancelRun(.policy, abort);
            return self.finishWithText(POLICY_CANCEL_TEXT);
        }
        return self.sendResults(arena, results.items, abort);
    }

    /// `runs.continue` with `results` for the current Step, then the next Step.
    fn sendResults(
        self: *SealedSkillProvider,
        arena: std.mem.Allocator,
        results: []const protocol.ResultEntry,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var errors: usize = 0;
        var refusals: usize = 0;
        for (results) |result| {
            if (result.is_error) errors += 1;
            if (result.refusal != null) refusals += 1;
        }
        log.info("sealed", "runs.continue run={s} seq={d} results={d} errors={d} refusals={d}", .{ run.run_id, run.seq, results.len, errors, refusals });
        _ = try self.currentRoute();
        defer self.transport.provider_credential = "";
        // §8.3: what we are about to send, as the gateway will digest it; the
        // next Step must echo it.
        const digest = try protocol.resultsDigest(arena, results);
        run.sent_results_digest = try self.run_arena.allocator().dupe(u8, digest);
        try self.recordResults(arena, results, digest);
        var params: std.Io.Writer.Allocating = .init(arena);
        try protocol.writeContinueParams(&params.writer, run.run_id, run.run_state, run.seq, results);
        var response = try self.callAdmitted(.runs_continue, params.written(), abort);
        defer response.deinit();
        return self.consumeResponse(&response, abort);
    }

    fn consumeResponse(
        self: *SealedSkillProvider,
        response: *protocol.ParsedResponse,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        switch (response.response) {
            .err => |err| {
                log.warn("sealed", "gateway error {d} ({s}): {s}", .{ err.code, if (err.known) |k| k.name() else "unknown", err.message });
                if (err.known) |known| switch (known) {
                    .manifest_changed => return error.SealedManifestChanged,
                    .unauthorized => return error.SealedUnauthorized,
                    .subscription_required => return error.SealedSubscriptionRequired,
                    .budget_exceeded => {
                        self.markFinished();
                        return self.finishWithText("[sealed skill stopped: the gateway reached the run's cost cap]");
                    },
                    else => {},
                };
                return error.SealedGatewayError;
            },
            .result => |result_json| {
                var parsed = protocol.parseStep(self.allocator, result_json) catch |err| {
                    log.warn("sealed", "unparseable step: {s}", .{@errorName(err)});
                    return error.SealedChainBroken;
                };
                defer parsed.deinit();
                return self.acceptStep(&parsed.step, abort);
            },
        }
    }

    fn acceptStep(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        // Chain and sequence checks (§8.3, §8.4) before anything is recorded.
        const expected_seq: u64 = if (self.run) |run| run.seq + 1 else 1;
        const expected_prev: []const u8 = if (self.run) |run| run.last_digest else protocol.GENESIS_DIGEST;
        if (step.seq != expected_seq or !std.mem.eql(u8, step.prev_digest, expected_prev)) {
            log.warn("sealed", "step chain broken: seq {d} (expected {d})", .{ step.seq, expected_seq });
            return error.SealedChainBroken;
        }
        if (self.run) |run| if (!std.mem.eql(u8, run.run_id, step.run_id)) return error.SealedChainBroken;
        // §8.3: the Step answering our `runs.continue` must bind exactly the
        // results we sent. A gateway that binds other results — or none — is
        // not continuing the conversation we had; the run ends.
        if (self.run) |run| if (run.sent_results_digest.len != 0 and !std.mem.eql(u8, run.sent_results_digest, step.results_digest)) {
            log.warn("sealed", "step {d} binds results_digest {s}, we sent {s}", .{ step.seq, step.results_digest, run.sent_results_digest });
            return error.SealedChainBroken;
        };
        const continues = step.kind == .tool_calls or step.kind == .input_required;
        if (continues and step.run_state.len == 0) return error.SealedChainBroken;

        // Adopt the Step: the previous Step's strings die with the arena.
        const previous_violations: u8 = if (self.run) |run| run.violations else 0;
        _ = self.run_arena.reset(.retain_capacity);
        const arena = self.run_arena.allocator();
        const calls = try arena.alloc(CallRef, step.calls.len);
        for (step.calls, calls) |call, *slot| slot.* = try self.adoptCall(arena, call);
        self.run = .{
            .run_id = try arena.dupe(u8, step.run_id),
            .run_state = try arena.dupe(u8, step.run_state),
            .seq = step.seq,
            .last_digest = try arena.dupe(u8, step.digest),
            .calls = calls,
            .cumulative_cost_micros = step.cumulative.cost_micros,
            .finished = !continues,
            .violations = previous_violations,
        };
        // A class refusal counts like an allowlist refusal (§6.2); the
        // third ends the run, in `continueRun` or `streamCalls`.
        for (calls) |call| {
            if (call.pre_refusal) |refusal| {
                if (refusal.refusal == .policy_violation) self.run.?.violations +|= 1;
            }
        }
        self.recordStep(step);
        if (step.disclosure_redactions != 0) {
            // §8.5: the gateway withheld passages of the Skill's own sealed
            // content; the user is told once, the ledger keeps the count.
            log.warn("sealed", "step {d}: the gateway redacted {d} passage(s) of the Skill's sealed content", .{ step.seq, step.disclosure_redactions });
            try self.addNotice("the gateway withheld passages of the Skill's own sealed content from this run's output; they read [sealed]");
        }
        log.info("sealed", "step run={s} seq={d} kind={s} calls={d} cost_micros={d} cumulative={d} usage in={d} out={d} cache_r={d}", .{
            step.run_id, step.seq, @tagName(step.kind), step.calls.len, step.usage.cost_micros, step.cumulative.cost_micros, step.usage.input_tokens, step.usage.output_tokens, step.usage.cache_read_input_tokens,
        });
        for (step.calls) |call| log.info("sealed", "  call id={s} name={s} confirm={} credentials={d} input_bytes={d}", .{ call.id, call.name, call.confirm, call.credentials.len, call.input_json.len });

        // §6.5: the client stops on its own as soon as the cap is passed.
        if (self.max_cost_micros > 0 and step.cumulative.cost_micros > self.max_cost_micros and continues) {
            self.cancelRun(.budget, abort);
            return self.finishWithText("[sealed skill stopped: cost cap reached before the run completed]");
        }
        if (continues and step.seq >= self.max_steps) {
            self.cancelRun(.client_error, abort);
            return self.finishWithText("[sealed skill stopped: step limit reached]");
        }

        switch (step.kind) {
            .tool_calls => return self.streamCalls(step, abort),
            .final => return self.finishWithText(step.text),
            .failed => {
                const text = try std.fmt.allocPrint(self.allocator, "[sealed skill failed: {s}{s}{s}]", .{
                    step.reason,
                    if (step.message.len != 0) ": " else "",
                    step.message,
                });
                defer self.allocator.free(text);
                return self.finishWithText(text);
            },
            .input_required => return self.answerQuestion(step, abort),
        }
    }

    /// Bind a Step's call to what this client will do with it: substitute the
    /// credentials it lists (§6.4), or refuse it before dispatch when one of
    /// them is not bound here.
    fn adoptCall(self: *SealedSkillProvider, arena: std.mem.Allocator, call: protocol.Call) !CallRef {
        var ref: CallRef = .{
            .id = try arena.dupe(u8, call.id),
            .name = try arena.dupe(u8, call.name),
            .result_limit_bytes = call.result_limit_bytes,
            .confirm = call.confirm,
            .credential_refs = &.{},
            .pre_refusal = null,
        };
        // §5, §6.2: a result the client can classify from the tool alone must
        // fall under a declared egress class; otherwise the call is refused
        // unexecuted, a policy violation like a call outside the allowlist.
        if (protocol.egressClassOfTool(call.name)) |class| {
            if (!protocol.manifestDeclaresEgress(self.manifest(), class)) {
                ref.pre_refusal = .{
                    .refusal = .policy_violation,
                    .message = try std.fmt.allocPrint(arena, "results of {s} ({s}) are not allowed to leave this machine: the pinned manifest declares no such egress class; the call was not executed", .{ call.name, class }),
                };
                log.warn("sealed", "call {s} ({s}) refused: egress class {s} is not declared", .{ call.id, call.name, class });
                return ref;
            }
        }
        if (call.credentials.len == 0) return ref;
        const skill_id = self.pin.pin.entry.skill_id;
        const skill_name = self.manifest().name;
        const refs = try arena.alloc([]const u8, call.credentials.len);
        for (call.credentials, refs) |name, *slot| {
            slot.* = try arena.dupe(u8, name);
            const declared = for (self.manifest().credentials) |declared| {
                if (std.mem.eql(u8, declared.ref, name)) break true;
            } else false;
            if (!declared) {
                ref.pre_refusal = .{
                    .refusal = .permission_denied,
                    .message = try std.fmt.allocPrint(arena, "credential reference '{s}' is not declared by the pinned manifest; the call was not executed", .{name}),
                };
                return ref;
            }
            if (!self.credentials.isBound(skill_id, name)) {
                const hint = try std.fmt.allocPrint(arena, "credential '{s}' is not bound on this client; bind it with: metacodes sealed bind {s} {s}", .{ name, skill_name, name });
                ref.pre_refusal = .{ .refusal = .permission_denied, .message = hint };
                try self.addNotice(hint);
                return ref;
            }
        }
        ref.credential_refs = refs;
        return ref;
    }

    fn addNotice(self: *SealedSkillProvider, text: []const u8) !void {
        for (self.notices.items) |known| if (std.mem.eql(u8, known, text)) return;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.notices.append(self.allocator, owned);
    }

    fn streamCalls(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var dispatched: usize = 0;
        for (run.calls) |call| {
            if (call.pre_refusal == null) dispatched += 1;
        }
        if (dispatched == 0) {
            if (run.violations >= MAX_POLICY_VIOLATIONS) {
                self.cancelRun(.policy, abort);
                return self.finishWithText(POLICY_CANCEL_TEXT);
            }
            // Nothing for the loop to run: answer the gateway now with the
            // refusals and go on to the next Step.
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const arena = scratch.allocator();
            var results: std.ArrayList(protocol.ResultEntry) = .empty;
            for (run.calls) |call| try results.append(arena, .{
                .tool_use_id = call.id,
                .content = call.pre_refusal.?.message,
                .is_error = true,
                .refusal = call.pre_refusal.?.refusal,
            });
            return self.sendResults(arena, results.items, abort);
        }
        // The brain's text between calls (if a gateway sends any) is its own
        // reasoning, not the Skill's result: it is not replayed.
        const stream = try StreamResponse.create(self.allocator, .tool_use);
        errdefer stream.destroy();
        for (step.calls, run.calls) |call, ref| {
            if (ref.pre_refusal != null) continue;
            if (ref.credential_refs.len == 0) {
                try stream.pushToolUse(call);
                continue;
            }
            const input = try self.substitute(self.allocator, call.input_json, ref.credential_refs);
            defer self.allocator.free(input);
            try stream.pushToolUse(.{ .id = call.id, .name = call.name, .input_json = input });
        }
        stream.pushUsage(step.usage);
        return stream.handle();
    }

    /// §6.4: `${SEALED_CRED:<ref>}` in `input_json` becomes the bound secret
    /// (JSON-escaped, so the document stays valid) for every ref in `refs`.
    fn substitute(self: *const SealedSkillProvider, allocator: std.mem.Allocator, input_json: []const u8, refs: []const []const u8) ![]u8 {
        var current = try allocator.dupe(u8, input_json);
        errdefer allocator.free(current);
        const skill_id = self.pin.pin.entry.skill_id;
        for (refs) |ref| {
            const secret = self.credentials.lookup(skill_id, ref) orelse continue;
            const needle = try credentials.placeholder(allocator, ref);
            defer allocator.free(needle);
            const escaped = try credentials.jsonEscaped(allocator, secret);
            defer @import("../../core/auth.zig").secureFree(allocator, escaped);
            const next = try credentials.replaceAll(allocator, current, needle, escaped);
            allocator.free(current);
            current = next;
        }
        return current;
    }

    const Redacted = struct { content: []const u8, refs: []const []const u8 };

    /// §6.4: every occurrence of a bound secret's value in `content` becomes
    /// `[redacted:<ref>]`; `refs` lists the references that were redacted.
    fn redact(self: *const SealedSkillProvider, arena: std.mem.Allocator, content: []const u8, refs: []const []const u8) !Redacted {
        var current = content;
        var redacted: std.ArrayList([]const u8) = .empty;
        const skill_id = self.pin.pin.entry.skill_id;
        for (refs) |ref| {
            const secret = self.credentials.lookup(skill_id, ref) orelse continue;
            if (secret.len == 0 or std.mem.indexOf(u8, current, secret) == null) continue;
            const marker = try std.fmt.allocPrint(arena, "[redacted:{s}]", .{ref});
            current = try credentials.replaceAll(arena, current, secret, marker);
            try redacted.append(arena, ref);
        }
        return .{ .content = current, .refs = redacted.items };
    }

    /// §4.3 `input_required`: put the question to the user and send the
    /// answer as the Step's one result. A question that carries the brain's
    /// `AskUserQuestion` input is answered by running that very tool here,
    /// so the brain gets the result shape it asked for; a bare message gets
    /// one dialog. Without a channel the run is released and the question
    /// becomes the fork's text.
    fn answerQuestion(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        const question = step.question.?;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const asked = self.askUser(arena, question) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => Asked{ .declined = @errorName(err) },
        };
        switch (asked) {
            .unavailable => {
                const text = try std.fmt.allocPrint(arena, "[sealed skill needs input] {s}", .{question.message});
                self.cancelRun(.client_error, abort);
                return self.finishWithText(text);
            },
            .declined => |why| {
                const content = try std.fmt.allocPrint(arena, "the user did not answer the question ({s})", .{why});
                const result: protocol.ResultEntry = .{
                    .tool_use_id = question.id,
                    .content = content,
                    .is_error = true,
                    .refusal = .aborted,
                };
                return self.sendResults(arena, &.{result}, abort);
            },
            .tool_error => |content| {
                const result: protocol.ResultEntry = .{ .tool_use_id = question.id, .content = content, .is_error = true };
                return self.sendResults(arena, &.{result}, abort);
            },
            .answered => |answer| {
                const result: protocol.ResultEntry = .{ .tool_use_id = question.id, .content = answer };
                return self.sendResults(arena, &.{result}, abort);
            },
        }
    }

    const Asked = union(enum) { unavailable, declined: []const u8, tool_error: []const u8, answered: []const u8 };

    fn askUser(self: *SealedSkillProvider, arena: std.mem.Allocator, question: protocol.Question) !Asked {
        const requester = self.ui orelse return .unavailable;
        if (question.tool_input_json.len != 0) {
            // The client's own AskUserQuestion, with the session's dialog.
            var ctx = tool_context.ToolContext.simple(arena);
            ctx.ui_requester = requester;
            ctx.session = self.session;
            const output = ask_user.execute(&ctx, question.tool_input_json) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InputAborted, error.UiCancelled => return .{ .declined = @errorName(err) },
                error.NotATty, error.UiPending => return .unavailable,
                else => return .{ .tool_error = try std.fmt.allocPrint(arena, "AskUserQuestion failed: {s}", .{@errorName(err)}) },
            };
            if (output.len > MAX_ANSWER_BYTES) return .{ .answered = output[0..MAX_ANSWER_BYTES] };
            return .{ .answered = output };
        }
        const options = try enumOptions(arena, question.schema_json);
        const header = try std.fmt.allocPrint(arena, "/{s}", .{self.manifest().name});
        const questions = [_]tool_context.AskQuestion{.{
            .question = question.message,
            .header = header,
            .multi = false,
            .options = options,
        }};
        const req = ui_request.UiRequest{ .ask_question = &questions };
        var resp: ui_request.UiResponse = undefined;
        const outcome = try requester.request(self.session, arena, &req, &resp);
        switch (outcome) {
            .answered => {},
            // An asynchronous front end stashed the question; a provider
            // cannot suspend the fork, so this run cannot take the answer.
            // A front end that cannot render questions never shows it.
            .pending, .unavailable, .unrenderable => return .unavailable,
        }
        switch (resp) {
            .answers => |answers| {
                if (answers.len == 0) return .{ .declined = "no answer" };
                const answer = answers[0];
                if (answer.len == 0) return .{ .declined = "empty answer" };
                if (answer.len > MAX_ANSWER_BYTES) return .{ .answered = answer[0..MAX_ANSWER_BYTES] };
                return .{ .answered = answer };
            },
            else => return .{ .declined = "no answer" },
        }
    }

    fn finishWithText(self: *SealedSkillProvider, text: []const u8) anyerror!provider_mod.StreamHandle {
        const stream = try StreamResponse.create(self.allocator, .end_turn);
        errdefer stream.destroy();
        for (self.notices.items) |notice| {
            const line = try std.fmt.allocPrint(self.allocator, "[sealed skill] {s}\n", .{notice});
            defer self.allocator.free(line);
            try stream.pushText(line);
        }
        if (text.len != 0) try stream.pushText(text);
        return stream.handle();
    }

    fn markFinished(self: *SealedSkillProvider) void {
        if (self.run) |*run| run.finished = true;
    }

    fn cancelRun(self: *SealedSkillProvider, reason: protocol.CancelReason, abort: ?*const AbortSignal) void {
        const run = &(self.run orelse return);
        if (run.finished) return;
        run.finished = true;
        log.info("sealed", "runs.cancel run={s} seq={d} reason={s}", .{ run.run_id, run.seq, @tagName(reason) });
        // A cancel makes no model call (§3.6): no credential travels with it.
        self.transport.provider_credential = "";
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        protocol.writeCancelParams(&params.writer, run.run_id, run.run_state, reason) catch return;
        var response = self.transport.call(.runs_cancel, params.written(), abort) catch |err| {
            log.warn("sealed", "cancel of run {s} failed: {s}", .{ run.run_id, @errorName(err) });
            return;
        };
        defer response.deinit();
        if (response.response == .result) {
            var parsed = protocol.parseStep(self.allocator, response.response.result) catch return;
            defer parsed.deinit();
            self.recordStep(&parsed.step);
        }
    }

    /// §2 and §8.4: an admission rejection — HTTP 503 with `Retry-After`, or
    /// the JSON-RPC `rate_limited` error with `retry_after_ms` — means the
    /// gateway did not process the request, so it is resent unchanged after
    /// the wait it named. Bounded in attempts and per-wait, abortable.
    fn callAdmitted(self: *SealedSkillProvider, method: protocol.Method, params_json: []const u8, abort: ?*const AbortSignal) anyerror!protocol.ParsedResponse {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            var response = self.transport.call(method, params_json, abort) catch |err| switch (err) {
                error.Overloaded => {
                    if (attempt >= MAX_ADMISSION_RETRIES) return self.transportFailure(err);
                    try self.waitAdmission(self.transport.last_retry_after_ms, abort, "at capacity");
                    continue;
                },
                else => return self.transportFailure(err),
            };
            if (response.response == .err) {
                if (response.response.err.known) |known| if (known == .rate_limited and attempt < MAX_ADMISSION_RETRIES) {
                    const wait = util_json.extractIntField(response.response.err.data_json, "retry_after_ms");
                    response.deinit();
                    try self.waitAdmission(wait, abort, "model slots busy");
                    continue;
                };
            }
            return response;
        }
    }

    fn waitAdmission(self: *SealedSkillProvider, requested_ms: u64, abort: ?*const AbortSignal, why: []const u8) anyerror!void {
        const wait_ms = @min(@max(requested_ms, MIN_ADMISSION_WAIT_MS), MAX_ADMISSION_WAIT_MS);
        log.info("sealed", "gateway {s} {s}; resending in {d} ms", .{ self.pin.pin.gateway_url, why, wait_ms });
        var waited: u64 = 0;
        while (waited < wait_ms) : (waited += 50) {
            if (abort) |signal| if (signal.isAborted()) return error.Aborted;
            util_time.sleepMs(@min(50, wait_ms - waited));
        }
    }

    fn transportFailure(self: *SealedSkillProvider, err: transport.Error) anyerror {
        log.warn("sealed", "gateway {s}: {s} (http {d})", .{ self.pin.pin.gateway_url, @errorName(err), self.transport.last_http_status });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Aborted => error.Aborted,
            error.Unauthorized => error.SealedUnauthorized,
            else => error.SealedGatewayError,
        };
    }

    fn recordStep(self: *SealedSkillProvider, step: *const protocol.Step) void {
        if (self.state_root.len == 0) return;
        const entry = &self.pin.pin.entry;
        const now: i64 = @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms));
        // §6.6: the call ids and names, so the audit shows what was asked.
        const owned_calls: ?[]ledger.CallRef = self.allocator.alloc(ledger.CallRef, step.calls.len) catch null;
        defer if (owned_calls) |owned| self.allocator.free(owned);
        if (owned_calls) |owned| for (step.calls, owned) |call, *slot| {
            slot.* = .{ .id = call.id, .name = call.name };
        };
        const tool_calls: []const ledger.CallRef = owned_calls orelse &.{};
        ledger.append(self.allocator, self.state_root, .{
            .kind = .step,
            .ts = now,
            .session_id = self.session_id,
            .gateway = self.pin.pin.gateway_url,
            .skill_id = entry.skill_id,
            .run_id = step.run_id,
            .seq = step.seq,
            .step_kind = @tagName(step.kind),
            .model = step.usage.model,
            .input_tokens = step.usage.input_tokens,
            .output_tokens = step.usage.output_tokens,
            .cache_read_tokens = step.usage.cache_read_input_tokens,
            .cache_creation_tokens = step.usage.cache_creation_input_tokens,
            .cost_micros = step.usage.cost_micros,
            .cumulative_cost_micros = step.cumulative.cost_micros,
            .currency = step.usage.currency,
            .digest = step.digest,
            .prev_digest = step.prev_digest,
            .issuer_skill_host = step.issuer_skill_host,
            .issuer_inference_gateway = step.issuer_inference_gateway,
            .calls = step.calls.len,
            .tool_calls = tool_calls,
            .results_digest = step.results_digest,
            .disclosure_redactions = step.disclosure_redactions,
        }) catch |err| log.warn("sealed", "ledger append failed: {s}", .{@errorName(err)});
        if (step.charge) |charge| {
            ledger.append(self.allocator, self.state_root, .{
                .kind = .charge,
                .ts = now,
                .session_id = self.session_id,
                .gateway = self.pin.pin.gateway_url,
                .skill_id = entry.skill_id,
                .run_id = charge.run_id,
                .seq = step.seq,
                .step_kind = @tagName(step.kind),
                .cost_micros = charge.cost_micros,
                .cumulative_cost_micros = charge.cost_micros,
                .currency = charge.currency,
                .digest = charge.digest,
                .issuer_skill_host = step.issuer_skill_host,
                .issuer_inference_gateway = step.issuer_inference_gateway,
                .calls = charge.steps,
            }) catch |err| log.warn("sealed", "ledger append failed: {s}", .{@errorName(err)});
        }
    }

    // ── Tool projection ───────────────────────────────────────────────────

    /// §6.6: a digest of each result as sent (after redaction and truncation),
    /// with its size and flags, keyed by the Step it answers.
    fn recordResults(self: *SealedSkillProvider, arena: std.mem.Allocator, results: []const protocol.ResultEntry, digest: []const u8) !void {
        if (self.state_root.len == 0) return;
        const run = &self.run.?;
        const entry = &self.pin.pin.entry;
        const refs = try arena.alloc(ledger.ResultRef, results.len);
        for (results, refs) |result, *slot| slot.* = .{
            .tool_use_id = result.tool_use_id,
            .sha256 = try protocol.digestHex(arena, result.content),
            .bytes = result.content.len,
            .is_error = result.is_error,
            .truncated = result.truncated,
            .refusal = if (result.refusal) |refusal| @tagName(refusal) else "",
            .redactions = result.redactions,
        };
        ledger.append(self.allocator, self.state_root, .{
            .kind = .results,
            .ts = @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms)),
            .session_id = self.session_id,
            .gateway = self.pin.pin.gateway_url,
            .skill_id = entry.skill_id,
            .run_id = run.run_id,
            .seq = run.seq,
            .calls = results.len,
            .results = refs,
            .results_digest = digest,
        }) catch |err| log.warn("sealed", "ledger append failed: {s}", .{@errorName(err)});
    }

    /// The session provider's route as of now, with its credential set on
    /// the transport for the request about to go out (§8.1), and cleared
    /// again by the caller once it has. Read before every call, so a
    /// refreshed OAuth token or a switched key is what the gateway gets and
    /// the transport never holds a credential between requests.
    fn currentRoute(self: *SealedSkillProvider) !provider_mod.ProviderRoute {
        const route = try routeOf(self.origin);
        self.transport.provider_credential = route.credential;
        return route;
    }

    const ToolsJson = struct { client: []const u8, provider: []const u8, client_count: usize = 0, provider_count: usize = 0 };

    /// The definitions the gateway's shadow may call, in the client's own
    /// schema dialect: the client tools the pinned allowlist admits plus
    /// `AskUserQuestion` (§3.4 `tools`), and the provider-side server tools
    /// the fork's own request would carry (§3.4 `provider_tools`). The list
    /// is exactly what the loop handed this provider — deferred tools
    /// included, flagged `"deferred":true` so the shadow's loop treats them
    /// as this loop would — because the shadow's request must be the fork's.
    fn toolsJson(self: *const SealedSkillProvider, arena: std.mem.Allocator, tools: []const json_mod.ToolDefinition) !ToolsJson {
        var client: std.ArrayList(u8) = .empty;
        var provider_tools: std.ArrayList(u8) = .empty;
        try client.append(arena, '[');
        try provider_tools.append(arena, '[');
        var client_count: usize = 0;
        var provider_count: usize = 0;
        for (tools) |tool| {
            if (tool.server_type != null) {
                if (provider_count != 0) try provider_tools.append(arena, ',');
                provider_count += 1;
                try api_request.serializeOneTool(tool, &provider_tools, arena);
                continue;
            }
            if (!self.toolAllowed(tool.name)) continue;
            if (client_count != 0) try client.append(arena, ',');
            client_count += 1;
            try api_request.serializeOneTool(tool, &client, arena);
            if (tool.deferred) {
                // Inside the object just written: replace its closing brace.
                client.items[client.items.len - 1] = ',';
                try client.appendSlice(arena, "\"deferred\":true}");
            }
        }
        try client.append(arena, ']');
        try provider_tools.append(arena, ']');
        return .{ .client = client.items, .provider = provider_tools.items, .client_count = client_count, .provider_count = provider_count };
    }

    /// §5: whether the fork's codebase context — the CLAUDE.md chain and git
    /// status the client's own forks carry in their system prompt — may
    /// travel to the gateway: only under the egress class the user consented
    /// to at install (`repository_structure`).
    pub fn sendsCodebaseContext(self: *const SealedSkillProvider) bool {
        return protocol.manifestDeclaresEgress(self.manifest(), protocol.EGRESS_CODEBASE_CONTEXT_CLASS);
    }

    /// Name-level admission against the pinned manifest: a `deny` rule that
    /// names the whole tool wins, then any `allow` rule for the tool admits
    /// it (argument patterns are the policy frame's job at dispatch time).
    /// `AskUserQuestion` is always admitted: it never dispatches through the
    /// frame, it is the user answering their own Skill.
    pub fn toolAllowed(self: *const SealedSkillProvider, tool_name: []const u8) bool {
        if (std.mem.eql(u8, tool_name, ASK_USER_TOOL)) return true;
        return protocol.manifestAllowsTool(self.manifest(), tool_name);
    }
};

/// A provider's route, or the reason it cannot be delegated (§8.1): no route
/// at all, a transport `provider.kind` has no value for, no credential, or a
/// signing scheme that cannot travel in a header.
fn routeOf(origin: provider_mod.Provider) !provider_mod.ProviderRoute {
    const route = origin.route() orelse return error.SealedProviderRouteUnavailable;
    if (!protocolKind(route.kind)) return error.SealedProviderRouteUnavailable;
    if (route.credential.len == 0) return error.SealedProviderRouteUnavailable;
    if (route.auth_scheme) |scheme| if (scheme == .signed_adapter) return error.SealedProviderRouteUnavailable;
    return route;
}

/// Whether SSP/1 has a `provider.kind` for this transport (§3.4: `anthropic`,
/// `openai`, `gemini`). A Bedrock route is not delegable: the gateway would
/// need the Converse transport, and the protocol would need a new kind.
fn protocolKind(kind: @import("../../types.zig").ProviderKind) bool {
    return switch (kind) {
        .anthropic, .openai, .gemini => true,
        .bedrock => false,
    };
}

/// The route's authentication as the `provider.auth` object (§3.4); "" for
/// the kind's default header.
fn authJson(arena: std.mem.Allocator, scheme: ?@import("../../api/auth_header.zig").AuthScheme) ![]const u8 {
    const selected = scheme orelse return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    switch (selected) {
        .bearer => try w.writeAll("{\"scheme\":\"bearer\"}"),
        .api_key_header => |name| {
            try w.writeAll("{\"scheme\":\"api_key_header\",\"header\":");
            try protocol.writeString(w, name);
            try w.writeByte('}');
        },
        .custom_header => |custom| {
            try w.writeAll("{\"scheme\":\"custom_header\",\"header\":");
            try protocol.writeString(w, custom.name);
            try w.writeAll(",\"value_prefix\":");
            try protocol.writeString(w, custom.value_prefix);
            try w.writeByte('}');
        },
        .signed_adapter => return error.SealedProviderRouteUnavailable,
    }
    return out.written();
}

fn findCall(calls: []const CallRef, id: []const u8) ?*const CallRef {
    for (calls) |*call| if (std.mem.eql(u8, call.id, id)) return call;
    return null;
}

/// Whether an error result is the loop's permission denial (user prompt or
/// permission chain): `{"error":{"code":"permission_denied",…}}`.
fn isPermissionDenied(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "\"code\":\"permission_denied\"") != null;
}

/// Options for a bare `input_required` dialog from an elicitation schema whose
/// single property is an enum (`{"type":"object","properties":{"x":{"enum":
/// ["a","b"]}}}`); anything else yields no options, and the dialog's own
/// free-text entry takes the answer.
fn enumOptions(arena: std.mem.Allocator, schema_json: []const u8) ![]const tool_context.AskOption {
    if (schema_json.len == 0) return &.{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const properties = parsed.object.get("properties") orelse return &.{};
    if (properties != .object or properties.object.count() != 1) return &.{};
    const only = properties.object.values()[0];
    if (only != .object) return &.{};
    const values = only.object.get("enum") orelse return &.{};
    if (values != .array or values.array.items.len == 0) return &.{};
    const options = try arena.alloc(tool_context.AskOption, values.array.items.len);
    for (values.array.items, options) |value, *slot| {
        if (value != .string) return &.{};
        slot.* = .{ .label = value.string, .description = "" };
    }
    return options;
}

/// All text blocks of the first user message, joined with blank lines.
fn firstUserText(arena: std.mem.Allocator, messages: []const types.ApiMessage) ![]const u8 {
    for (messages) |message| {
        if (message.role != .user) continue;
        var out: std.ArrayList(u8) = .empty;
        for (message.content) |block| switch (block) {
            .text => |text| {
                if (out.items.len != 0) try out.appendSlice(arena, "\n\n");
                try out.appendSlice(arena, text);
            },
            else => {},
        };
        return out.items;
    }
    return "";
}

/// Head of the result plus a marker and a short tail, within `limit` bytes.
fn truncateResult(arena: std.mem.Allocator, content: []const u8, limit: usize) ![]const u8 {
    const marker = "\n…[truncated by client result cap]…\n";
    if (limit <= marker.len + 64) return content[0..@min(content.len, limit)];
    const tail_len: usize = @min(256, (limit - marker.len) / 4);
    const head_len = limit - marker.len - tail_len;
    return std.mem.concat(arena, u8, &.{ content[0..head_len], marker, content[content.len - tail_len ..] });
}

// ── Stream replay of one Step ─────────────────────────────────────────────

const StreamResponse = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(api_stream.StreamEvent) = .empty,
    index: usize = 0,
    stop: api_stream.StopReason,
    request_id: log.RequestId,

    fn create(allocator: std.mem.Allocator, stop: api_stream.StopReason) !*StreamResponse {
        const self = try allocator.create(StreamResponse);
        self.* = .{ .allocator = allocator, .stop = stop, .request_id = log.genRequestId() };
        return self;
    }

    fn destroy(self: *StreamResponse) void {
        // Events the consumer has not taken are still ours (`index` runs one
        // past the end once `.done` has been handed out).
        const taken = @min(self.index, self.events.items.len);
        for (self.events.items[taken..]) |event| freeEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn pushText(self: *StreamResponse, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.events.append(self.allocator, .{ .text = owned });
    }

    fn pushToolUse(self: *StreamResponse, call: protocol.Call) !void {
        const id = try self.allocator.dupe(u8, call.id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, call.name);
        errdefer self.allocator.free(name);
        const input = try self.allocator.dupe(u8, call.input_json);
        errdefer self.allocator.free(input);
        try self.events.append(self.allocator, .{ .tool_use_start = .{ .id = id, .name = name, .input_json = input } });
    }

    fn pushUsage(self: *StreamResponse, usage: protocol.Usage) void {
        self.events.append(self.allocator, .{ .usage = .{
            .input_tokens = usage.input_tokens,
            .output_tokens = usage.output_tokens,
            .cache_read_input_tokens = usage.cache_read_input_tokens,
            .cache_creation_input_tokens = usage.cache_creation_input_tokens,
        } }) catch {};
    }

    fn handle(self: *StreamResponse) provider_mod.StreamHandle {
        return .{
            .ctx = @ptrCast(self),
            .image_placeholder_ids = &.{},
            .nextFn = nextFn,
            .deinitFn = deinitFn,
            .stopReasonFn = stopReasonFn,
            .requestIdFn = requestIdFn,
        };
    }

    fn cast(ctx: *anyopaque) *StreamResponse {
        return @ptrCast(@alignCast(ctx));
    }

    fn nextFn(ctx: *anyopaque) anyerror!?api_stream.StreamEvent {
        const self = cast(ctx);
        if (self.index < self.events.items.len) {
            const event = self.events.items[self.index];
            self.index += 1;
            return event;
        }
        if (self.index == self.events.items.len) {
            self.index += 1;
            return .done;
        }
        return null;
    }

    fn deinitFn(ctx: *anyopaque) void {
        cast(ctx).destroy();
    }

    fn stopReasonFn(ctx: *anyopaque) api_stream.StopReason {
        return cast(ctx).stop;
    }

    fn requestIdFn(ctx: *anyopaque) log.RequestId {
        return cast(ctx).request_id;
    }
};

fn freeEvent(allocator: std.mem.Allocator, event: api_stream.StreamEvent) void {
    switch (event) {
        .text => |text| allocator.free(text),
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
        },
        else => {},
    }
}

test "result truncation keeps a head, a marker and a tail within the cap" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const content = "x" ** 1000 ++ "TAIL";
    const out = try truncateResult(arena.allocator(), content, 300);
    try std.testing.expect(out.len <= 300);
    try std.testing.expect(std.mem.endsWith(u8, out, "TAIL"));
    try std.testing.expect(std.mem.indexOf(u8, out, "truncated by client") != null);
}

test "a permission denial in a tool result is recognized by its error code" {
    try std.testing.expect(isPermissionDenied("{\"error\":{\"code\":\"permission_denied\",\"category\":\"safety\",\"detail\":\"user declined 'Read' via prompt\",\"recoverable\":false}}"));
    try std.testing.expect(!isPermissionDenied("{\"error\":{\"code\":\"not_found\",\"detail\":\"x\"}}"));
    try std.testing.expect(!isPermissionDenied("plain output"));
}

test "input_required options come from a single enum property only" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const with_enum = try enumOptions(arena.allocator(), "{\"type\":\"object\",\"properties\":{\"ledger\":{\"type\":\"string\",\"enum\":[\"main\",\"test\"]}}}");
    try std.testing.expectEqual(@as(usize, 2), with_enum.len);
    try std.testing.expectEqualStrings("test", with_enum[1].label);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}")).len);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "not json")).len);
}

test "the provider route's authentication travels as the auth object" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try authJson(arena.allocator(), null));
    try std.testing.expectEqualStrings("{\"scheme\":\"bearer\"}", try authJson(arena.allocator(), .bearer));
    try std.testing.expectEqualStrings("{\"scheme\":\"api_key_header\",\"header\":\"x-api-key\"}", try authJson(arena.allocator(), .{ .api_key_header = "x-api-key" }));
    try std.testing.expectError(error.SealedProviderRouteUnavailable, authJson(arena.allocator(), .{ .signed_adapter = "aws" }));
}

test "a Bedrock route is not delegated to a gateway: SSP/1 has no kind for it" {
    const a = std.testing.allocator;
    var bedrock = try @import("../../api/provider_factory.zig").makeProvider(a, .bedrock, "brk-key", "us.anthropic.claude-sonnet-4-6", null);
    defer bedrock.deinit();
    // The route itself is complete: kind, origin, model and a bearer credential.
    const route = bedrock.provider().route() orelse return error.TestExpectedRoute;
    try std.testing.expectEqual(@import("../../types.zig").ProviderKind.bedrock, route.kind);
    try std.testing.expectEqualStrings("brk-key", route.credential);
    // `create` and every Step read the route through `routeOf`.
    try std.testing.expectError(error.SealedProviderRouteUnavailable, routeOf(bedrock.provider()));

    var anthropic = try @import("../../api/provider_factory.zig").makeProvider(a, .anthropic, "ant-key", "claude-sonnet-4-6", null);
    defer anthropic.deinit();
    try std.testing.expectEqual(@import("../../types.zig").ProviderKind.anthropic, (try routeOf(anthropic.provider())).kind);
}

test "stream replays calls, usage, then done" {
    const a = std.testing.allocator;
    const stream = try StreamResponse.create(a, .tool_use);
    try stream.pushText("hi");
    try stream.pushToolUse(.{ .id = "c1", .name = "Read", .input_json = "{}" });
    stream.pushUsage(.{ .input_tokens = 3 });
    const h = stream.handle();
    defer h.deinit();
    const first = (try h.next()).?;
    try std.testing.expectEqualStrings("hi", first.text);
    a.free(first.text);
    const second = (try h.next()).?;
    try std.testing.expectEqualStrings("Read", second.tool_use_start.name);
    freeEvent(a, second);
    const third = (try h.next()).?;
    try std.testing.expectEqual(@as(u64, 3), third.usage.input_tokens);
    try std.testing.expect((try h.next()).? == .done);
    try std.testing.expect((try h.next()) == null);
    try std.testing.expectEqual(api_stream.StopReason.tool_use, h.stopReason());
}
