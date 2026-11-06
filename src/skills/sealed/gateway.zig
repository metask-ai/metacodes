//! Reference SSP/1 gateway: the server side of doc/SEALED_SKILL_PROTOCOL.md.
//!
//! `metacodes sealed serve` loads Skill packages (`<dir>/<name>/SKILL.md` +
//! `manifest.json`, public assets, a `sealed/` directory of private reference
//! files) and answers the protocol methods over a small HTTP/1.1 loop.
//!
//! The brain of a run is a *shadow* of the client's fork (§9.1 "Mirror"): the
//! same `agent_loop` the client would have run, fed the system prompt, tool
//! definitions, model and request parameters the client sends, calling the
//! model over the **client's own provider route and credential** (§8.1). The
//! gateway has no provider of its own. Every tool use the loop produces is
//! captured instead of executed: the loop suspends on the batch, the batch
//! becomes a `tool_calls` Step, and the client's results resume the loop. The
//! only tool the gateway serves itself is a `Read` of the Skill's own sealed
//! reference files, which exist nowhere else. An `AskUserQuestion` call
//! becomes an `input_required` Step the client answers with its own dialog.
//!
//! The gateway is stateless per run: the loop's continuation — the whole
//! conversation, the pending batch, totals, caps — travels in `run_state`,
//! sealed with XChaCha20-Poly1305 under a process key, so a tampered or
//! replayed blob fails closed and any gateway instance with the key can serve
//! any Step. Nothing about a run is stored server-side, which is what
//! `egress.retention: "run"` promises, and the client's credential lives only
//! as long as the request that carried it.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const credentials = @import("credentials.zig");
const disclosure = @import("disclosure.zig");
const definition = @import("../runtime/definition.zig");
const render = @import("../render.zig");
const provider_mod = @import("../../api/provider.zig");
const provider_factory = @import("../../api/provider_factory.zig");
const provider_pool = @import("provider_pool.zig");
const connection_gate = @import("../../api/connection_gate.zig");
const psync = @import("platform").sync;
const util_time = @import("../../util/time.zig");
const dialect_mod = @import("../../api/dialect.zig");
const auth_header_mod = @import("../../api/auth_header.zig");
const types = @import("../../types.zig");
const json_mod = @import("../../json.zig");
const pricing = @import("../../util/pricing.zig");
const log = @import("../../util/log.zig");
const agent_loop = @import("../../core/agent_loop.zig");
const Conversation = @import("../../core/conversation.zig").Conversation;
const transcript = @import("../../core/transcript.zig");
const msg = @import("../../core/message.zig");
const writer_backend = @import("../../core/writer_backend.zig");
const usage_mod = @import("../../core/usage.zig");
const permission_mod = @import("../../permission.zig");
const category_mod = @import("../../permission/category.zig");
const tool_context = @import("../../tools/context.zig");
const tool_result = @import("../../core/tool_result.zig");
const tool_common = @import("../../tools/common.zig");
const glob_tool = @import("../../tools/glob.zig");
const grep_tool = @import("../../tools/grep.zig");
const read_state = @import("../../core/read_state.zig");
const net = @import("platform").net;
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Base64 = std.base64.url_safe_no_pad;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DEFAULT_OPERATOR = "metacodes";
/// A request carries the run's whole conversation (§4.4): sized like a model
/// context, matched by the client's `protocol.MAX_MESSAGE_BYTES`.
pub const MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_STATE_BYTES: usize = 12 * 1024 * 1024;
/// First allocation for a request; grown toward `MAX_REQUEST_BYTES` only as
/// the declared body length demands.
pub const INITIAL_REQUEST_BYTES: usize = 64 * 1024;
/// Policy violations reported by the client before the gateway fails the run.
pub const MAX_POLICY_VIOLATIONS: u32 = 3;
/// The package directory whose files only the gateway ever reads (§5, §12).
pub const SEALED_DIR = "sealed";
/// The client's question tool: a call becomes an `input_required` Step (§4.3).
pub const ASK_USER_TOOL = "AskUserQuestion";
/// Model turns the loop may take inside one Step (sealed reads, compaction,
/// retries) before the gateway gives up on it.
pub const INTERNAL_TURN_CAP: u32 = 16;
pub const MAX_SEALED_READ_BYTES: usize = 1024 * 1024;
const PENDING_REMOTE_KIND = "sealed_remote";
const PENDING_QUESTION_KIND = "sealed_question";

pub const Error = error{
    OutOfMemory,
    SkillsDirUnreadable,
    InvalidPackage,
};

pub const Asset = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
};

/// One published Skill: its manifest as served, the body that becomes the
/// fork's first user turn, its public assets and its sealed reference files.
/// The body and the sealed files never leave this process.
pub const Package = struct {
    name: []const u8,
    dir: []const u8,
    body: []const u8,
    entry_json: []const u8,
    entry: protocol.Entry,
    assets: []const Asset,
    /// Paths relative to `<dir>/sealed/`.
    sealed_files: []const []const u8,
    /// §8.5: the token windows the disclosure screen matches the brain's
    /// output against — the body (the Skill's instructions) and the `sealed/`
    /// reference files, each under its own manifest policy.
    disclosure_body: disclosure.Corpus,
    disclosure_references: disclosure.Corpus,

    pub fn findAsset(self: *const Package, path: []const u8) ?*const Asset {
        for (self.assets) |*asset| if (std.mem.eql(u8, asset.path, path)) return asset;
        return null;
    }
};

pub const Options = struct {
    operator_id: []const u8 = DEFAULT_OPERATOR,
    /// Shared bearer token every client must present; "" accepts any caller
    /// (loopback development only).
    token: []const u8 = "",
    /// Process key for `run_state`; random when null.
    state_key: ?[32]u8 = null,
    currency: []const u8 = "USD",
    /// Idle window a client's built provider (with its upstream connections)
    /// stays cached for, keyed by route and credential (design §4). 0 builds
    /// and discards one per request.
    provider_cache_ms: u64 = provider_pool.DEFAULT_IDLE_TTL_MS,
    provider_cache_max: usize = provider_pool.DEFAULT_MAX_ENTRIES,
};

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    packages: []const Package,
    operator_id: []const u8,
    token: []const u8,
    currency: []const u8,
    state_key: [32]u8,
    pool: provider_pool.Pool,
    next_run: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// Timing counters (milliseconds, summed) for `sealed:bench` and
    /// diagnostics: whole `handle` calls, the shadow loop inside them (model
    /// wait included), and how many Steps they cover.
    timing_handle_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timing_loop_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timing_steps: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, skills_dir: []const u8, options: Options) Error!*Gateway {
        const self = allocator.create(Gateway) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .packages = &.{},
            .operator_id = "",
            .token = "",
            .currency = "",
            .state_key = undefined,
            .pool = provider_pool.Pool.init(allocator, options.provider_cache_ms, options.provider_cache_max),
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.operator_id = arena.dupe(u8, options.operator_id) catch return error.OutOfMemory;
        self.token = arena.dupe(u8, options.token) catch return error.OutOfMemory;
        self.currency = arena.dupe(u8, options.currency) catch return error.OutOfMemory;
        if (options.state_key) |key| self.state_key = key else try fillRandom(&self.state_key);
        self.packages = try loadPackages(arena, skills_dir);
        return self;
    }

    pub fn deinit(self: *Gateway) void {
        self.pool.deinit();
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Route-cache counters (hits, misses, expiries, evictions, size).
    pub fn poolStats(self: *Gateway) provider_pool.Stats {
        return self.pool.snapshot();
    }

    pub fn findPackage(self: *const Gateway, skill_id: []const u8) ?*const Package {
        for (self.packages) |*package| if (std.mem.eql(u8, package.entry.skill_id, skill_id)) return package;
        return null;
    }

    /// Whether `authorization` (the raw header value, or null) admits a caller.
    pub fn authorized(self: *const Gateway, authorization: ?[]const u8) bool {
        if (self.token.len == 0) return true;
        const header = authorization orelse return false;
        const prefix = "Bearer ";
        if (!std.ascii.startsWithIgnoreCase(header, prefix)) return false;
        const presented = std.mem.trim(u8, header[prefix.len..], " ");
        if (presented.len != self.token.len) return false;
        var diff: u8 = 0;
        for (presented, self.token) |lhs, rhs| diff |= lhs ^ rhs;
        return diff == 0;
    }

    /// Handle one JSON-RPC request body; the response document is owned by
    /// the caller. `credential` is the client's provider credential for this
    /// request (the `Sealed-Provider-Credential` header, "" when absent); it
    /// is used for the model calls of this request and nowhere else.
    pub fn handle(self: *Gateway, allocator: std.mem.Allocator, body: []const u8, credential: []const u8) ![]u8 {
        const started = util_time.nowMs();
        defer _ = self.timing_handle_ms.fetchAdd(@intCast(util_time.nowMs() - started), .monotonic);
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const request = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return rpcError(allocator, null, -32700, "parse error", null, null);
        };
        if (request != .object) return rpcError(allocator, null, -32600, "invalid request", null, null);
        const id = request.object.get("id");
        const method_value = request.object.get("method") orelse return rpcError(allocator, id, -32600, "invalid request", null, null);
        if (method_value != .string) return rpcError(allocator, id, -32600, "invalid request", null, null);
        const params = request.object.get("params") orelse std.json.Value{ .object = .{} };
        const method = method_value.string;
        const result: []const u8 = blk: {
            if (std.mem.eql(u8, method, protocol.Method.discover.wire())) break :blk try self.discover(arena);
            if (std.mem.eql(u8, method, protocol.Method.skills_list.wire())) break :blk try self.skillsList(arena);
            if (std.mem.eql(u8, method, protocol.Method.skills_get.wire())) break :blk self.skillsGet(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.skills_asset.wire())) break :blk self.skillsAsset(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_start.wire())) break :blk self.runsStart(arena, params, credential) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_continue.wire())) break :blk self.runsContinue(arena, params, credential) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_cancel.wire())) break :blk self.runsCancel(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            return rpcError(allocator, id, -32601, "method not found", null, null);
        };
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(&out.writer, id);
        try out.writer.writeAll(",\"result\":");
        try out.writer.writeAll(result);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    const MethodError = error{
        OutOfMemory,
        InvalidParams,
        SkillNotFound,
        ManifestChanged,
        RunStateInvalid,
        UpstreamUnavailable,
        /// `Sealed-Provider-Credential` is missing on a method that calls the model.
        CredentialMissing,
        /// `provider_tools` is not empty: the shadow loop, like the client's
        /// fork, cannot represent provider server tools (§3.4).
        ProviderToolsUnsupported,
    };

    fn rpcFailure(self: *Gateway, allocator: std.mem.Allocator, id: ?std.json.Value, err: MethodError) ![]u8 {
        _ = self;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidParams => rpcError(allocator, id, -32602, "invalid params", null, null),
            error.CredentialMissing => rpcError(allocator, id, -32602, protocol.PROVIDER_CREDENTIAL_HEADER ++ " header required: the gateway calls the model with the client's provider", null, null),
            error.ProviderToolsUnsupported => rpcError(allocator, id, -32602, "provider_tools must be empty: the agent loop does not support provider server tools", null, null),
            error.SkillNotFound => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.skill_not_found), "unknown skill", .skill_not_found, null),
            error.ManifestChanged => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.manifest_changed), "pinned manifest is not current", .manifest_changed, null),
            error.RunStateInvalid => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.run_state_invalid), "run state rejected", .run_state_invalid, null),
            error.UpstreamUnavailable => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.upstream_unavailable), "model provider failed", .upstream_unavailable, null),
        };
    }

    // ── Methods ───────────────────────────────────────────────────────────

    fn discover(self: *Gateway, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll("{\"protocol\":\"" ++ protocol.PROTOCOL_ID ++ "\",\"revisions\":[\"" ++ protocol.REVISION ++ "\"],\"operator\":{\"id\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"display_name\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"identities\":{\"skill_host\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"inference_gateway\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"sealing_issuer\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"billing\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"capabilities\":{\"run_state\":\"opaque\",\"step_signature\":false,\"input_required\":true,\"client_provider\":true,\"prefetch\":false,\"client_sealed\":false,\"currencies\":[");
        try protocol.writeString(w, self.currency);
        try w.writeAll("]}}");
        return out.written();
    }

    fn skillsList(self: *Gateway, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll("{\"skills\":[");
        for (self.packages, 0..) |package, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll(package.entry_json);
        }
        try w.writeAll("]}");
        return out.written();
    }

    fn skillsGet(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        _ = arena;
        const skill_id = paramString(params, "skill_id") orelse return error.InvalidParams;
        const package = self.findPackage(skill_id) orelse return error.SkillNotFound;
        return package.entry_json;
    }

    /// One public asset of a package, base64 in JSON: the client installs it
    /// into the pin directory and verifies the digest (§5 `assets`).
    fn skillsAsset(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        const skill_id = paramString(params, "skill_id") orelse return error.InvalidParams;
        const path = paramString(params, "path") orelse return error.InvalidParams;
        const package = self.findPackage(skill_id) orelse return error.SkillNotFound;
        const asset = package.findAsset(path) orelse return error.InvalidParams;
        const full = joinRelative(arena, package.dir, asset.path) catch return error.OutOfMemory;
        const bytes = readFile(arena, full, protocol.MAX_ASSET_BYTES) catch return error.InvalidParams;
        const encoded = arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch return error.OutOfMemory;
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"path\":") catch return error.OutOfMemory;
        protocol.writeString(w, asset.path) catch return error.OutOfMemory;
        w.writeAll(",\"sha256\":") catch return error.OutOfMemory;
        protocol.writeString(w, asset.sha256) catch return error.OutOfMemory;
        w.writeAll(",\"content_base64\":") catch return error.OutOfMemory;
        protocol.writeString(w, encoded) catch return error.OutOfMemory;
        w.writeByte('}') catch return error.OutOfMemory;
        return out.written();
    }

    fn runsStart(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value, credential: []const u8) MethodError![]const u8 {
        const skill_id = paramString(params, "skill_id") orelse return error.InvalidParams;
        const digest = paramString(params, "manifest_digest") orelse return error.InvalidParams;
        const prompt = paramString(params, "prompt") orelse return error.InvalidParams;
        const package = self.findPackage(skill_id) orelse return error.SkillNotFound;
        if (!std.mem.eql(u8, digest, package.entry.manifest_digest)) return error.ManifestChanged;
        if (params != .object) return error.InvalidParams;
        if (credential.len == 0) return error.CredentialMissing;
        const tools_value = params.object.get("tools") orelse std.json.Value{ .array = std.json.Array.init(arena) };
        if (tools_value != .array) return error.InvalidParams;
        const provider_tools_value = params.object.get("provider_tools") orelse std.json.Value{ .array = std.json.Array.init(arena) };
        if (provider_tools_value != .array) return error.InvalidParams;
        if (provider_tools_value.array.items.len != 0) return error.ProviderToolsUnsupported;
        var max_cost: i64 = 0;
        var max_steps: u64 = protocol_default_max_steps;
        if (params.object.get("budget")) |budget| {
            if (budget != .object) return error.InvalidParams;
            if (budget.object.get("max_cost_micros")) |v| {
                if (v != .integer or v.integer < 0) return error.InvalidParams;
                max_cost = v.integer;
            }
            if (budget.object.get("max_steps")) |v| {
                if (v != .integer or v.integer <= 0) return error.InvalidParams;
                max_steps = @intCast(v.integer);
            }
        }
        var confirm_all = false;
        if (params.object.get("confirmation")) |c| {
            if (c != .string) return error.InvalidParams;
            confirm_all = std.mem.eql(u8, c.string, "always");
        }
        const provider_spec = try providerSpecFromParams(params.object.get("provider") orelse return error.InvalidParams);
        const request_value = params.object.get("request") orelse return error.InvalidParams;
        const model = valueString(request_value, "model") orelse return error.InvalidParams;
        if (model.len == 0) return error.InvalidParams;
        var max_tokens: u32 = 0;
        if (valueUnsigned(request_value, "max_tokens")) |v| max_tokens = @intCast(@min(v, std.math.maxInt(u32)));
        const reasoning_effort = valueString(request_value, "reasoning_effort") orelse "";
        const base_dir = paramString(params, "base_dir") orelse package.name;
        const arguments = try stringList(arena, params.object.get("arguments"));

        const run_number = self.next_run.fetchAdd(1, .monotonic);
        var nonce: [8]u8 = undefined;
        fillRandom(&nonce) catch return error.OutOfMemory;
        const run_id = std.fmt.allocPrint(arena, "run_{d}_{s}", .{ run_number, std.fmt.bytesToHex(nonce, .lower) }) catch return error.OutOfMemory;

        var state = RunState{
            .run_id = run_id,
            .skill_id = skill_id,
            .seq = 0,
            .last_digest = protocol.GENESIS_DIGEST,
            .max_cost_micros = max_cost,
            .max_steps = max_steps,
            .confirm_all = confirm_all,
            .system = paramString(params, "system") orelse "",
            .base_dir = base_dir,
            .model = model,
            .max_tokens = max_tokens,
            .reasoning_effort = reasoning_effort,
            .provider = provider_spec,
            .tools = tools_value,
            .provider_tools = provider_tools_value,
            .messages = std.json.Array.init(arena),
            .pending = &.{},
            .completed = &.{},
        };
        // The first user turn is byte-for-byte what a local fork of this
        // Skill would have sent (§9.1): the base directory line and the body
        // rendered with the user's arguments, plus what only a sealed Skill
        // needs to be told — its sealed reference files and the credential
        // placeholders it may use.
        const task = try self.firstUserTurn(arena, package, base_dir, if (arguments.len != 0) arguments else &.{prompt});
        var text_block = std.json.ObjectMap{};
        text_block.put(arena, "type", .{ .string = "text" }) catch return error.OutOfMemory;
        text_block.put(arena, "text", .{ .string = task }) catch return error.OutOfMemory;
        var blocks = std.json.Array.init(arena);
        blocks.append(.{ .object = text_block }) catch return error.OutOfMemory;
        var message = std.json.ObjectMap{};
        message.put(arena, "role", .{ .string = "user" }) catch return error.OutOfMemory;
        message.put(arena, "delivered", .{ .bool = false }) catch return error.OutOfMemory;
        message.put(arena, "blocks", .{ .array = blocks }) catch return error.OutOfMemory;
        state.messages.append(.{ .object = message }) catch return error.OutOfMemory;
        return self.advance(arena, package, &state, credential, null);
    }

    fn firstUserTurn(self: *Gateway, arena: std.mem.Allocator, package: *const Package, base_dir: []const u8, arguments: []const []const u8) MethodError![]const u8 {
        _ = self;
        const manifest = &package.entry.manifest;
        // Shell injection (`!cmd`) would run on the gateway; it is disabled, as
        // §12 requires of a sealed body. `@file` includes resolve inside the
        // package, which is where a sealed Skill keeps what it includes.
        const rendered = render.renderBody(arena, package.body, .{
            .arguments = arguments,
            .arg_names = manifest.arguments,
            .skill_dir = package.dir,
            .disable_shell_execution = true,
        }) catch return error.InvalidParams;
        var out: std.ArrayList(u8) = .empty;
        out.print(arena, "Base directory for this skill: {s}\n\n{s}", .{ base_dir, rendered }) catch return error.OutOfMemory;
        if (package.sealed_files.len != 0) {
            out.appendSlice(arena, "\n\nSealed reference files of this Skill (Read, Glob and Grep work on them like on any other file):\n") catch return error.OutOfMemory;
            for (package.sealed_files) |path| {
                out.print(arena, "- {s}/" ++ SEALED_DIR ++ "/{s}\n", .{ base_dir, path }) catch return error.OutOfMemory;
            }
        }
        if (manifest.credentials.len != 0) {
            out.appendSlice(arena, "\n\nCredential references bound on this machine. Write the placeholder literally wherever a tool input needs the value; it is substituted before execution and redacted from the result, and you never see it:\n") catch return error.OutOfMemory;
            for (manifest.credentials) |credential| {
                out.print(arena, "- `{s}{s}{s}`", .{ credentials.PLACEHOLDER_PREFIX, credential.ref, credentials.PLACEHOLDER_SUFFIX }) catch return error.OutOfMemory;
                if (credential.purpose.len != 0) out.print(arena, " — {s}", .{credential.purpose}) catch return error.OutOfMemory;
                out.append(arena, '\n') catch return error.OutOfMemory;
            }
        }
        return out.items;
    }

    fn runsContinue(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value, credential: []const u8) MethodError![]const u8 {
        const run_id = paramString(params, "run_id") orelse return error.InvalidParams;
        const blob = paramString(params, "run_state") orelse return error.InvalidParams;
        if (params != .object) return error.InvalidParams;
        const seq_value = params.object.get("seq") orelse return error.InvalidParams;
        if (seq_value != .integer or seq_value.integer <= 0) return error.InvalidParams;
        const results = params.object.get("results") orelse return error.InvalidParams;
        if (results != .array) return error.InvalidParams;
        if (credential.len == 0) return error.CredentialMissing;

        var state = try self.openState(arena, blob, run_id);
        if (!std.mem.eql(u8, state.run_id, run_id)) return error.RunStateInvalid;
        if (@as(u64, @intCast(seq_value.integer)) != state.seq) return error.RunStateInvalid;
        if (state.pending.len == 0) return error.RunStateInvalid;
        const package = self.findPackage(state.skill_id) orelse return error.SkillNotFound;

        // One result per pending call or question, matched by id, plus the
        // results the gateway produced itself (sealed reads) and the calls it
        // answers itself (a call issued beside a question, §4.3). Together
        // they are the one user turn that resumes the loop.
        var resume_results: std.ArrayList(agent_loop.SuspendInfo.CompletedResult) = .empty;
        var matched: usize = 0;
        for (state.pending) |pending| {
            var content: []const u8 = skippedResultText(pending.kind);
            var is_error = true;
            if (pending.kind == .call or pending.kind == .question) {
                const result = findResult(results.array.items, pending.id) orelse return error.RunStateInvalid;
                matched += 1;
                content = valueString(result, "content") orelse "";
                is_error = valueBool(result, "is_error") orelse false;
                if (valueString(result, "refusal")) |refusal| {
                    if (std.mem.eql(u8, refusal, "policy_violation")) state.violations += 1;
                }
            }
            resume_results.append(arena, .{ .tool_use_id = pending.id, .content = content, .is_error = is_error }) catch return error.OutOfMemory;
        }
        if (matched != results.array.items.len) return error.RunStateInvalid;
        for (state.completed) |completed| {
            resume_results.append(arena, .{ .tool_use_id = completed.id, .content = completed.content, .is_error = completed.is_error }) catch return error.OutOfMemory;
        }
        state.pending = &.{};
        state.completed = &.{};
        // §8.3: the next Step is derived from these results; bind them into
        // the chain so the client can check the gateway saw what it sent.
        state.results_digest = protocol.resultsDigestOfValue(arena, results) catch return error.OutOfMemory;
        if (state.violations >= MAX_POLICY_VIOLATIONS) {
            return self.finishRun(arena, &state, "policy_violation", "the client refused calls outside the pinned allowlist");
        }
        return self.advance(arena, package, &state, credential, resume_results.items);
    }

    fn runsCancel(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        const run_id = paramString(params, "run_id") orelse return error.InvalidParams;
        const blob = paramString(params, "run_state") orelse return error.InvalidParams;
        var state = try self.openState(arena, blob, run_id);
        if (!std.mem.eql(u8, state.run_id, run_id)) return error.RunStateInvalid;
        return self.finishRun(arena, &state, "cancelled", "cancelled by the client");
    }

    // ── Run state ─────────────────────────────────────────────────────────

    /// What a pending id waits for: a client result (`call`, `question`), or
    /// nothing — the gateway answers it itself on continue (`skipped`: a call
    /// issued beside a question).
    const PendingKind = enum { call, question, skipped };
    const Pending = struct { id: []const u8, name: []const u8, kind: PendingKind = .call };
    /// A result the gateway produced itself in the suspended batch (a sealed
    /// read); it joins the client's results in the resuming user turn.
    const Completed = struct { id: []const u8, content: []const u8, is_error: bool };

    fn skippedResultText(kind: PendingKind) []const u8 {
        return switch (kind) {
            .call, .question => "",
            .skipped => "not executed: the Skill asked the user in the same turn; call it again now that the answer is in",
        };
    }

    const AuthSpec = struct {
        scheme: []const u8 = "",
        header: []const u8 = "",
        value_prefix: []const u8 = "",

        fn toScheme(self: AuthSpec) ?auth_header_mod.AuthScheme {
            if (std.mem.eql(u8, self.scheme, "bearer")) return .bearer;
            if (std.mem.eql(u8, self.scheme, "api_key_header")) return .{ .api_key_header = self.header };
            if (std.mem.eql(u8, self.scheme, "custom_header")) return .{ .custom_header = .{ .name = self.header, .value_prefix = self.value_prefix } };
            return null;
        }
    };

    /// The client's provider route (§8.1), minus the credential, which never
    /// enters the state.
    const ProviderSpec = struct {
        kind: types.ProviderKind,
        base_url: []const u8,
        openai_protocol: types.OpenAIProtocol,
        auth: AuthSpec,
    };

    /// The `provider.kind` values of §3.4. Spelled out rather than read off
    /// `types.ProviderKind`: a transport added there (Bedrock) does not become
    /// part of the protocol by existing.
    fn protocolKind(text: []const u8) ?types.ProviderKind {
        const table = [_]struct { []const u8, types.ProviderKind }{
            .{ "anthropic", .anthropic },
            .{ "openai", .openai },
            .{ "gemini", .gemini },
        };
        for (table) |row| if (std.mem.eql(u8, text, row[0])) return row[1];
        return null;
    }

    fn providerSpecFromParams(value: std.json.Value) MethodError!ProviderSpec {
        if (value != .object) return error.InvalidParams;
        const kind_text = valueString(value, "kind") orelse return error.InvalidParams;
        const kind = protocolKind(kind_text) orelse return error.InvalidParams;
        var spec: ProviderSpec = .{
            .kind = kind,
            .base_url = valueString(value, "base_url") orelse "",
            .openai_protocol = .chat_completions,
            .auth = .{},
        };
        if (valueString(value, "openai_protocol")) |raw| {
            spec.openai_protocol = types.OpenAIProtocol.parse(raw) orelse return error.InvalidParams;
        }
        if (value.object.get("auth")) |auth| {
            if (auth != .object) return error.InvalidParams;
            spec.auth = .{
                .scheme = valueString(auth, "scheme") orelse "",
                .header = valueString(auth, "header") orelse "",
                .value_prefix = valueString(auth, "value_prefix") orelse "",
            };
            // An empty scheme is the kind's default; a named one must be known.
            if (spec.auth.scheme.len != 0 and spec.auth.toScheme() == null) return error.InvalidParams;
        }
        return spec;
    }

    /// The loop's continuation between two Steps. Everything in here is the
    /// client's own data (its prompt, its tools, its results, the model's
    /// replies it has seen as Steps) except the model's text between calls
    /// and the sealed reads; the body itself is re-read from the package.
    const RunState = struct {
        run_id: []const u8,
        skill_id: []const u8,
        seq: u64,
        last_digest: []const u8,
        max_cost_micros: i64,
        max_steps: u64,
        confirm_all: bool,
        cost_micros: i64 = 0,
        input_tokens: u64 = 0,
        output_tokens: u64 = 0,
        violations: u32 = 0,
        system: []const u8,
        base_dir: []const u8,
        model: []const u8,
        max_tokens: u32,
        reasoning_effort: []const u8,
        provider: ProviderSpec,
        tools: std.json.Value,
        provider_tools: std.json.Value,
        /// The summary standing for everything the loop compacted away.
        compact_summary: ?[]const u8 = null,
        /// Transcript-shaped message objects (`transcript.Writer.renderMessageJson`)
        /// of the **active window** only: everything before the compaction
        /// boundary lives on as `compact_summary`.
        messages: std.json.Array,
        pending: []const Pending,
        completed: []const Completed,
        /// Request-scoped, never sealed: the digest of the `results` the Step
        /// being produced derives from (§8.3); "" for `runs.start`.
        results_digest: []const u8 = "",
    };

    /// Serialize, seal and encode a run state (§4.4).
    fn sealState(self: *Gateway, arena: std.mem.Allocator, state: *const RunState) MethodError![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        writeState(w, state) catch return error.OutOfMemory;
        const plain = out.written();
        if (plain.len > MAX_STATE_BYTES) return error.RunStateInvalid;

        const raw = arena.alloc(u8, Aead.nonce_length + plain.len + Aead.tag_length) catch return error.OutOfMemory;
        const nonce = raw[0..Aead.nonce_length];
        fillRandom(nonce) catch return error.RunStateInvalid;
        const ciphertext = raw[Aead.nonce_length .. Aead.nonce_length + plain.len];
        const tag = raw[Aead.nonce_length + plain.len ..][0..Aead.tag_length];
        Aead.encrypt(ciphertext, tag, plain, state.run_id, nonce.*, self.state_key);
        const encoded = arena.alloc(u8, Base64.Encoder.calcSize(raw.len)) catch return error.OutOfMemory;
        return Base64.Encoder.encode(encoded, raw);
    }

    fn writeState(w: *std.Io.Writer, state: *const RunState) !void {
        try w.writeAll("{\"v\":2,\"run_id\":");
        try protocol.writeString(w, state.run_id);
        try w.writeAll(",\"skill_id\":");
        try protocol.writeString(w, state.skill_id);
        try w.print(",\"seq\":{d},\"last_digest\":", .{state.seq});
        try protocol.writeString(w, state.last_digest);
        try w.print(",\"max_cost_micros\":{d},\"max_steps\":{d},\"confirm_all\":{},\"cost_micros\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"violations\":{d}", .{
            state.max_cost_micros, state.max_steps, state.confirm_all, state.cost_micros, state.input_tokens, state.output_tokens, state.violations,
        });
        try w.writeAll(",\"system\":");
        try protocol.writeString(w, state.system);
        try w.writeAll(",\"base_dir\":");
        try protocol.writeString(w, state.base_dir);
        try w.writeAll(",\"model\":");
        try protocol.writeString(w, state.model);
        try w.print(",\"max_tokens\":{d},\"reasoning_effort\":", .{state.max_tokens});
        try protocol.writeString(w, state.reasoning_effort);
        try w.print(",\"provider\":{{\"kind\":\"{s}\",\"base_url\":", .{@tagName(state.provider.kind)});
        try protocol.writeString(w, state.provider.base_url);
        try w.print(",\"openai_protocol\":\"{s}\",\"auth\":{{\"scheme\":", .{@tagName(state.provider.openai_protocol)});
        try protocol.writeString(w, state.provider.auth.scheme);
        try w.writeAll(",\"header\":");
        try protocol.writeString(w, state.provider.auth.header);
        try w.writeAll(",\"value_prefix\":");
        try protocol.writeString(w, state.provider.auth.value_prefix);
        try w.writeAll("}},\"tools\":");
        try std.json.Stringify.value(state.tools, .{}, w);
        try w.writeAll(",\"provider_tools\":");
        try std.json.Stringify.value(state.provider_tools, .{}, w);
        try w.writeAll(",\"compact_summary\":");
        if (state.compact_summary) |summary| try protocol.writeString(w, summary) else try w.writeAll("null");
        try w.writeAll(",\"messages\":");
        try std.json.Stringify.value(std.json.Value{ .array = state.messages }, .{}, w);
        try w.writeAll(",\"pending\":[");
        for (state.pending, 0..) |pending, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try protocol.writeString(w, pending.id);
            try w.writeAll(",\"name\":");
            try protocol.writeString(w, pending.name);
            try w.print(",\"kind\":\"{s}\"}}", .{@tagName(pending.kind)});
        }
        try w.writeAll("],\"completed\":[");
        for (state.completed, 0..) |completed, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try protocol.writeString(w, completed.id);
            try w.writeAll(",\"content\":");
            try protocol.writeString(w, completed.content);
            try w.print(",\"is_error\":{}}}", .{completed.is_error});
        }
        try w.writeAll("]}");
    }

    /// Decode, authenticate and parse a run state. The run id the request
    /// claims is the AEAD's associated data, so a blob presented under another
    /// run's id fails authentication rather than being parsed.
    fn openState(self: *Gateway, arena: std.mem.Allocator, blob: []const u8, claimed_run_id: []const u8) MethodError!RunState {
        const raw_len = Base64.Decoder.calcSizeForSlice(blob) catch return error.RunStateInvalid;
        if (raw_len < Aead.nonce_length + Aead.tag_length) return error.RunStateInvalid;
        const raw = arena.alloc(u8, raw_len) catch return error.OutOfMemory;
        Base64.Decoder.decode(raw, blob) catch return error.RunStateInvalid;
        const nonce = raw[0..Aead.nonce_length];
        const plain_len = raw_len - Aead.nonce_length - Aead.tag_length;
        const ciphertext = raw[Aead.nonce_length .. Aead.nonce_length + plain_len];
        const tag = raw[Aead.nonce_length + plain_len ..][0..Aead.tag_length];
        const plain = arena.alloc(u8, plain_len) catch return error.OutOfMemory;
        Aead.decrypt(plain, ciphertext, tag.*, claimed_run_id, nonce.*, self.state_key) catch return error.RunStateInvalid;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, plain, .{}) catch return error.RunStateInvalid;
        if (parsed != .object) return error.RunStateInvalid;
        if ((valueUnsigned(parsed, "v") orelse 0) != 2) return error.RunStateInvalid;
        const messages_value = parsed.object.get("messages") orelse return error.RunStateInvalid;
        if (messages_value != .array) return error.RunStateInvalid;
        const pending_value = parsed.object.get("pending") orelse return error.RunStateInvalid;
        if (pending_value != .array) return error.RunStateInvalid;
        const pending = arena.alloc(Pending, pending_value.array.items.len) catch return error.OutOfMemory;
        for (pending_value.array.items, pending) |item, *slot| {
            const kind_text = valueString(item, "kind") orelse "call";
            slot.* = .{
                .id = valueString(item, "id") orelse return error.RunStateInvalid,
                .name = valueString(item, "name") orelse return error.RunStateInvalid,
                .kind = std.meta.stringToEnum(PendingKind, kind_text) orelse return error.RunStateInvalid,
            };
        }
        const completed_value = parsed.object.get("completed") orelse return error.RunStateInvalid;
        if (completed_value != .array) return error.RunStateInvalid;
        const completed = arena.alloc(Completed, completed_value.array.items.len) catch return error.OutOfMemory;
        for (completed_value.array.items, completed) |item, *slot| {
            slot.* = .{
                .id = valueString(item, "id") orelse return error.RunStateInvalid,
                .content = valueString(item, "content") orelse "",
                .is_error = valueBool(item, "is_error") orelse false,
            };
        }
        const provider_value = parsed.object.get("provider") orelse return error.RunStateInvalid;
        const provider_spec = providerSpecFromParams(provider_value) catch return error.RunStateInvalid;
        const summary_value = parsed.object.get("compact_summary");
        return .{
            .run_id = valueString(parsed, "run_id") orelse return error.RunStateInvalid,
            .skill_id = valueString(parsed, "skill_id") orelse return error.RunStateInvalid,
            .seq = valueUnsigned(parsed, "seq") orelse return error.RunStateInvalid,
            .last_digest = valueString(parsed, "last_digest") orelse return error.RunStateInvalid,
            .max_cost_micros = valueInteger(parsed, "max_cost_micros") orelse 0,
            .max_steps = valueUnsigned(parsed, "max_steps") orelse protocol_default_max_steps,
            .confirm_all = valueBool(parsed, "confirm_all") orelse false,
            .cost_micros = valueInteger(parsed, "cost_micros") orelse 0,
            .input_tokens = valueUnsigned(parsed, "input_tokens") orelse 0,
            .output_tokens = valueUnsigned(parsed, "output_tokens") orelse 0,
            .violations = @intCast(valueUnsigned(parsed, "violations") orelse 0),
            .system = valueString(parsed, "system") orelse "",
            .base_dir = valueString(parsed, "base_dir") orelse "",
            .model = valueString(parsed, "model") orelse return error.RunStateInvalid,
            .max_tokens = @intCast(@min(valueUnsigned(parsed, "max_tokens") orelse 0, std.math.maxInt(u32))),
            .reasoning_effort = valueString(parsed, "reasoning_effort") orelse "",
            .provider = provider_spec,
            .tools = parsed.object.get("tools") orelse std.json.Value{ .array = std.json.Array.init(arena) },
            .provider_tools = parsed.object.get("provider_tools") orelse std.json.Value{ .array = std.json.Array.init(arena) },
            .compact_summary = if (summary_value != null and summary_value.? == .string) summary_value.?.string else null,
            .messages = messages_value.array,
            .pending = pending,
            .completed = completed,
        };
    }

    // ── The shadow loop ───────────────────────────────────────────────────

    /// Run the client's fork loop until it needs the client: rebuild the
    /// conversation from the state, call the model over the client's route,
    /// serve sealed reads in place, and stop at the first batch of remote
    /// tool uses (a Step) or at the end of the run.
    /// Everything `provider_pool.Pool.borrow` needs to build a client's
    /// provider on a cache miss.
    const ProviderBuild = struct {
        allocator: std.mem.Allocator,
        spec: ProviderSpec,
        credential: []const u8,
        model: []const u8,
        max_tokens: u32,

        /// Runs on a cache miss. The provider borrows the strings it is given
        /// for as long as it lives, and the request they came from is gone by
        /// the next lease, so every one is copied into the entry's allocator.
        fn build(self: ProviderBuild, entry_allocator: std.mem.Allocator) anyerror!provider_pool.Built {
            const secret = try entry_allocator.dupe(u8, self.credential);
            const kept: ProviderSpec = .{
                .kind = self.spec.kind,
                .base_url = try entry_allocator.dupe(u8, self.spec.base_url),
                .openai_protocol = self.spec.openai_protocol,
                .auth = .{
                    .scheme = try entry_allocator.dupe(u8, self.spec.auth.scheme),
                    .header = try entry_allocator.dupe(u8, self.spec.auth.header),
                    .value_prefix = try entry_allocator.dupe(u8, self.spec.auth.value_prefix),
                },
            };
            const model = try entry_allocator.dupe(u8, self.model);
            const owned = try provider_factory.makeProviderWithOptions(
                self.allocator,
                kept.kind,
                .{ .fixed = secret },
                model,
                if (kept.base_url.len != 0) kept.base_url else null,
                kept.openai_protocol,
                dialect_mod.Resolver.builtin(),
                .{
                    .auth_scheme = kept.auth.toScheme(),
                    .limits = if (self.max_tokens != 0) .{ .max_tokens_override = self.max_tokens } else null,
                },
            );
            return .{ .owned = owned, .secret = secret };
        }
    };

    fn advance(
        self: *Gateway,
        arena: std.mem.Allocator,
        package: *const Package,
        state: *RunState,
        credential: []const u8,
        resume_results: ?[]const agent_loop.SuspendInfo.CompletedResult,
    ) MethodError![]const u8 {
        if (state.seq + 1 > state.max_steps) return self.finishRun(arena, state, "max_steps", "step limit reached");

        // The conversation, owned by the loop's allocator for the request.
        var conversation = Conversation.init(self.allocator);
        defer conversation.deinit();
        restoreConversation(arena, &conversation, state.messages, state.compact_summary) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RunStateInvalid,
        };

        // The client's provider for this request (§8.1), lent from the route
        // cache so consecutive Steps reuse the upstream connection (design
        // §4). The key covers everything that shapes the route, the
        // credential included; the lease is exclusive for the request.
        const key = provider_pool.fingerprint(&.{
            @tagName(state.provider.kind),
            state.provider.base_url,
            @tagName(state.provider.openai_protocol),
            state.provider.auth.scheme,
            state.provider.auth.header,
            state.provider.auth.value_prefix,
            state.model,
            std.mem.asBytes(&state.max_tokens),
            credential,
        });
        const lease = self.pool.borrow(key, ProviderBuild{
            .allocator = self.allocator,
            .spec = state.provider,
            .credential = credential,
            .model = state.model,
            .max_tokens = state.max_tokens,
        }, ProviderBuild.build) catch |err| {
            log.warn("sealed-gw", "provider setup failed: {s}", .{@errorName(err)});
            return error.UpstreamUnavailable;
        };
        defer lease.release();
        const prov = lease.provider();
        // A cached provider keeps the last request's effort; set it every time.
        if (prov.setReasoningEffortFn) |set| {
            const effort: ?types.ReasoningEffort = if (state.reasoning_effort.len != 0)
                std.meta.stringToEnum(types.ReasoningEffort, state.reasoning_effort)
            else
                null;
            set(prov.ctx, effort);
        }

        const defs = try toolDefinitions(arena, state.tools, state.provider_tools);
        var dispatcher = RemoteDispatcher{ .package = package, .base_dir = state.base_dir, .defs = defs };
        var totals: usage_mod.UsageTotals = .{};
        var wb = writer_backend.WriterBackend.initNullWithUsage(&totals);
        const backend = wb.backend();
        // The client is the permission authority (§6.2); the shadow's own
        // chain never prompts and never executes.
        const permission = permission_mod.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = self.allocator };
        const opts: agent_loop.Options = .{
            .max_turns = INTERNAL_TURN_CAP,
            .system_prompt = if (state.system.len != 0) state.system else null,
            .tool_defs = defs,
            .tool_dispatcher = dispatcher.dispatcher(),
            .suspend_all_pending = true,
            .agent_depth = 1,
            .colorize = false,
            .session_id = state.run_id,
        };
        const loop_started = util_time.nowMs();
        defer {
            _ = self.timing_loop_ms.fetchAdd(@intCast(util_time.nowMs() - loop_started), .monotonic);
            _ = self.timing_steps.fetchAdd(1, .monotonic);
        }
        const outcome = (if (resume_results) |results|
            agent_loop.resumeRunWithResults(&conversation, prov, defs, &permission, results, opts, &backend, self.allocator)
        else
            agent_loop.run(&conversation, prov, defs, &permission, opts, &backend, self.allocator)) catch |err| {
            log.warn("sealed-gw", "shadow loop failed: {s}", .{@errorName(err)});
            return error.UpstreamUnavailable;
        };
        defer if (outcome.suspend_info) |info| info.deinit();

        // Metering: informational under the client's own account (§8.2), but
        // still the number the client's cap and ledger see.
        const rates = pricing.rateFor(state.model);
        const cost_usd = pricing.computeCost(rates, totals.input_tokens, totals.output_tokens, totals.cache_read_input_tokens, totals.cache_creation_input_tokens);
        const step_cost: i64 = @intFromFloat(@round(cost_usd * 1_000_000.0));
        state.cost_micros += step_cost;
        state.input_tokens += totals.input_tokens;
        state.output_tokens += totals.output_tokens;
        state.seq += 1;
        const step_usage: protocol.Usage = .{
            .model = state.model,
            .input_tokens = totals.input_tokens,
            .output_tokens = totals.output_tokens,
            .cache_read_input_tokens = totals.cache_read_input_tokens,
            .cache_creation_input_tokens = totals.cache_creation_input_tokens,
            .cost_micros = step_cost,
            .currency = self.currency,
        };

        // The continuation: the conversation as the loop left it.
        try self.storeConversation(arena, state, &conversation);

        if (state.max_cost_micros > 0 and state.cost_micros > state.max_cost_micros) {
            return self.emitStep(arena, state, .{ .kind = .failed, .reason = "budget_exceeded", .message = "the run's cost cap was reached", .usage = step_usage });
        }
        switch (outcome.stop_reason) {
            .suspended => {
                const info = outcome.suspend_info orelse return error.UpstreamUnavailable;
                return self.emitSuspended(arena, package, state, &conversation, info, step_usage);
            },
            .end_turn => {
                const text = lastAssistantText(arena, &conversation) catch return error.OutOfMemory;
                return self.emitStep(arena, state, .{ .kind = .final, .text = text, .usage = step_usage });
            },
            .api_error => return self.emitStep(arena, state, .{ .kind = .failed, .reason = "upstream_unavailable", .message = "the model provider failed", .usage = step_usage }),
            .max_turns => return self.emitStep(arena, state, .{ .kind = .failed, .reason = "skill_error", .message = "the Skill took too many model turns without a tool call for the client", .usage = step_usage }),
            // The brain's answer is still cut at the output-token limit after
            // its last continuation (#394). A `failed` Step has no `text`
            // (§4.3), so the truncated answer stays on the gateway: the
            // message names the cause and quotes none of it.
            .max_tokens_exhausted => {
                const message = std.fmt.allocPrint(arena, "the Skill's output was still cut off at the model's output-token limit after {d} continuations", .{outcome.continuations}) catch return error.OutOfMemory;
                return self.emitStep(arena, state, .{ .kind = .failed, .reason = "skill_error", .message = message, .usage = step_usage });
            },
            else => |reason| return self.emitStep(arena, state, .{ .kind = .failed, .reason = "skill_error", .message = @tagName(reason), .usage = step_usage }),
        }
    }

    /// Turn a suspended batch into the Step the client answers: every remote
    /// tool use as a call (with `confirm` and `credentials`), or — when the
    /// brain asked the user — the first question alone, the rest answered by
    /// the gateway on continue.
    fn emitSuspended(
        self: *Gateway,
        arena: std.mem.Allocator,
        package: *const Package,
        state: *RunState,
        conversation: *const Conversation,
        info: agent_loop.SuspendInfo,
        step_usage: protocol.Usage,
    ) MethodError![]const u8 {
        const PendingUse = struct { id: []const u8, kind: []const u8, payload: []const u8 };
        var uses: std.ArrayList(PendingUse) = .empty;
        uses.append(arena, .{ .id = info.tool_use_id, .kind = info.kind, .payload = info.payload_json }) catch return error.OutOfMemory;
        for (info.pending_siblings) |sibling| uses.append(arena, .{ .id = sibling.tool_use_id, .kind = sibling.kind, .payload = sibling.payload_json }) catch return error.OutOfMemory;

        var question: ?protocol.Question = null;
        for (uses.items) |use| {
            if (std.mem.eql(u8, use.kind, PENDING_QUESTION_KIND)) {
                question = .{
                    .id = use.id,
                    .message = firstQuestionText(arena, use.payload) catch return error.OutOfMemory,
                    .tool_input_json = use.payload,
                };
                break;
            }
        }
        const pending = arena.alloc(Pending, uses.items.len) catch return error.OutOfMemory;
        var calls: std.ArrayList(protocol.Call) = .empty;
        for (uses.items, pending) |use, *slot| {
            const tool_use = findToolUse(conversation, use.id) orelse return error.UpstreamUnavailable;
            const name = arena.dupe(u8, tool_use.name) catch return error.OutOfMemory;
            if (question) |q| {
                slot.* = .{ .id = use.id, .name = name, .kind = if (std.mem.eql(u8, use.id, q.id)) .question else .skipped };
                continue;
            }
            slot.* = .{ .id = use.id, .name = name, .kind = .call };
            calls.append(arena, .{
                .id = use.id,
                .name = name,
                .input_json = arena.dupe(u8, tool_use.input) catch return error.OutOfMemory,
                .confirm = state.confirm_all or listContains(package.entry.manifest.confirmation_required_for, name),
                .deadline_ms = 300_000,
                .credentials = try declaredCredentialRefs(arena, package, tool_use.input),
                .result_limit_bytes = package.entry.manifest.egress_max_result_bytes,
            }) catch return error.OutOfMemory;
        }
        const completed = arena.alloc(Completed, info.completed_results.len) catch return error.OutOfMemory;
        for (info.completed_results, completed) |result, *slot| slot.* = .{
            .id = arena.dupe(u8, result.tool_use_id) catch return error.OutOfMemory,
            .content = arena.dupe(u8, result.content) catch return error.OutOfMemory,
            .is_error = result.is_error,
        };
        state.pending = pending;
        state.completed = completed;
        if (question) |q| {
            return self.emitStep(arena, state, .{ .kind = .input_required, .question = q, .usage = step_usage });
        }
        return self.emitStep(arena, state, .{ .kind = .tool_calls, .calls = calls.items, .usage = step_usage });
    }

    /// The continuation keeps only what the model would still see: the
    /// active window plus the summary that stands for everything before it
    /// (`activeWindowJson`).
    fn storeConversation(self: *Gateway, arena: std.mem.Allocator, state: *RunState, conversation: *const Conversation) MethodError!void {
        _ = self;
        state.messages = try activeWindowJson(arena, conversation);
        state.compact_summary = if (conversation.compact_summary) |summary| (arena.dupe(u8, summary) catch return error.OutOfMemory) else null;
    }

    fn finishRun(self: *Gateway, arena: std.mem.Allocator, state: *RunState, reason: []const u8, message: []const u8) MethodError![]const u8 {
        state.seq += 1;
        state.pending = &.{};
        state.completed = &.{};
        return self.emitStep(arena, state, .{ .kind = .failed, .reason = reason, .message = message, .usage = .{ .model = state.model, .currency = self.currency } });
    }

    const Emit = struct {
        kind: protocol.StepKind,
        calls: []const protocol.Call = &.{},
        question: ?protocol.Question = null,
        /// `final` only: the Skill's result. A `tool_calls` Step carries no
        /// text — the brain's narration between calls stays on the gateway.
        text: []const u8 = "",
        reason: []const u8 = "",
        message: []const u8 = "",
        usage: protocol.Usage,
        /// §8.5: set by the screen in `emitStep`; written as `disclosure`.
        disclosure_redactions: usize = 0,
    };

    /// Render a Step: digest first (over everything but `run_state`, `digest`
    /// and `sig`), then seal the state with that digest as its chain head, and
    /// only then attach both.
    fn emitStep(self: *Gateway, arena: std.mem.Allocator, state: *RunState, emit_in: Emit) MethodError![]const u8 {
        var emit = emit_in;
        if (self.findPackage(state.skill_id)) |package| try screenEmit(arena, package, state, &emit);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        writeStepBody(w, self, state, emit) catch return error.OutOfMemory;
        var value = std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{}) catch return error.OutOfMemory;
        const digest = protocol.stepDigest(arena, value) catch return error.OutOfMemory;
        log.info("sealed-gw", "run {s} step {d} {s}: calls={d} cost_micros={d} cumulative={d}{s}{s}", .{
            state.run_id, state.seq, @tagName(emit.kind), emit.calls.len, emit.usage.cost_micros, state.cost_micros, if (emit.reason.len != 0) " reason=" else "", emit.reason,
        });
        state.last_digest = digest;
        value.object.put(arena, "digest", .{ .string = digest }) catch return error.OutOfMemory;
        if (emit.kind == .tool_calls or emit.kind == .input_required) {
            const blob = try self.sealState(arena, state);
            value.object.put(arena, "run_state", .{ .string = blob }) catch return error.OutOfMemory;
        }
        return protocol.serializeValue(arena, value) catch return error.OutOfMemory;
    }

    fn writeStepBody(w: *std.Io.Writer, self: *Gateway, state: *const RunState, emit: Emit) !void {
        try w.writeAll("{\"run_id\":");
        try protocol.writeString(w, state.run_id);
        try w.print(",\"seq\":{d},\"kind\":\"{s}\"", .{ state.seq, @tagName(emit.kind) });
        if (emit.kind == .tool_calls) {
            try w.writeAll(",\"calls\":[");
            for (emit.calls, 0..) |call, index| {
                if (index != 0) try w.writeByte(',');
                try w.writeAll("{\"id\":");
                try protocol.writeString(w, call.id);
                try w.writeAll(",\"name\":");
                try protocol.writeString(w, call.name);
                try w.writeAll(",\"input\":");
                try w.writeAll(call.input_json);
                try w.print(",\"confirm\":{},\"deadline_ms\":{d},\"credentials\":[", .{ call.confirm, call.deadline_ms orelse 0 });
                for (call.credentials, 0..) |ref, ref_index| {
                    if (ref_index != 0) try w.writeByte(',');
                    try protocol.writeString(w, ref);
                }
                try w.print("],\"result_limit_bytes\":{d}}}", .{call.result_limit_bytes orelse protocol.DEFAULT_MAX_RESULT_BYTES});
            }
            try w.writeByte(']');
        }
        if (emit.kind == .input_required) {
            const q = emit.question orelse return error.InvalidParams;
            try w.writeAll(",\"question\":{\"id\":");
            try protocol.writeString(w, q.id);
            try w.writeAll(",\"message\":");
            try protocol.writeString(w, q.message);
            if (q.tool_input_json.len != 0) {
                try w.writeAll(",\"tool_input\":");
                try w.writeAll(q.tool_input_json);
            }
            try w.writeByte('}');
        }
        if (emit.kind == .final and emit.text.len != 0) {
            try w.writeAll(",\"text\":");
            try protocol.writeString(w, emit.text);
        }
        if (emit.kind == .failed) {
            try w.writeAll(",\"reason\":");
            try protocol.writeString(w, emit.reason);
            try w.writeAll(",\"message\":");
            try protocol.writeString(w, emit.message);
        }
        try w.writeAll(",\"usage\":{\"model\":");
        try protocol.writeString(w, emit.usage.model);
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_input_tokens\":{d},\"cache_creation_input_tokens\":{d},\"cost_micros\":{d},\"currency\":", .{
            emit.usage.input_tokens, emit.usage.output_tokens, emit.usage.cache_read_input_tokens, emit.usage.cache_creation_input_tokens, emit.usage.cost_micros,
        });
        try protocol.writeString(w, self.currency);
        try w.print("}},\"cumulative\":{{\"steps\":{d},\"cost_micros\":{d},\"currency\":", .{ state.seq, state.cost_micros });
        try protocol.writeString(w, self.currency);
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d}}},\"issuer\":{{\"skill_host\":", .{ state.input_tokens, state.output_tokens });
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"inference_gateway\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"prev_digest\":");
        try protocol.writeString(w, state.last_digest);
        if (state.results_digest.len != 0) {
            try w.writeAll(",\"results_digest\":");
            try protocol.writeString(w, state.results_digest);
        }
        if (emit.disclosure_redactions != 0) {
            try w.print(",\"disclosure\":{{\"redactions\":{d}}}", .{emit.disclosure_redactions});
        }
        if (emit.kind == .final or emit.kind == .failed) {
            try w.writeAll(",\"charge\":{\"run_id\":");
            try protocol.writeString(w, state.run_id);
            try w.print(",\"cost_micros\":{d},\"currency\":", .{state.cost_micros});
            try protocol.writeString(w, self.currency);
            try w.print(",\"steps\":{d},\"issued_at\":\"\",\"digest\":\"\"}}", .{state.seq});
        }
        try w.writeByte('}');
    }
};

const protocol_default_max_steps: u64 = 200;

/// §8.5: what the brain is about to show the client — a final text, the
/// inputs of a tool_calls batch, a question — passes the disclosure screen
/// before the Step is rendered. Under the manifest's `redact` policy a
/// passage that quotes the sealed material becomes the marker and the Step
/// counts it; under `fail` the Step becomes the run's failure and nothing of
/// it reaches the client; `off` skips the screen. The brain's own
/// conversation keeps the original: the screen edits what leaves, never
/// what the brain remembers.
fn screenEmit(arena: std.mem.Allocator, package: *const Package, state: *Gateway.RunState, emit: *Gateway.Emit) Gateway.MethodError!void {
    // Two corpora, two policies: the body (the Skill's instructions) and the
    // `sealed/` references. A documentation Skill restates its references
    // on purpose and turns that screen off; its instructions stay screened.
    const body_policy = disclosure.Policy.parse(package.entry.manifest.egress_disclosure) orelse .redact;
    const references_policy = disclosure.Policy.parse(package.entry.manifest.egress_disclosure_references) orelse .redact;
    var total: usize = 0;
    var fail = false;
    const body_spans = try screenAgainst(arena, &package.disclosure_body, body_policy, emit);
    total += body_spans;
    if (body_spans != 0 and body_policy == .fail) fail = true;
    const reference_spans = try screenAgainst(arena, &package.disclosure_references, references_policy, emit);
    total += reference_spans;
    if (reference_spans != 0 and references_policy == .fail) fail = true;
    if (total == 0) return;
    log.warn("sealed-gw", "run {s} step {d}: {d} passage(s) quoting sealed content ({d} body, {d} references) {s}", .{ state.run_id, state.seq, total, body_spans, reference_spans, if (fail) "end the run" else "redacted" });
    if (fail) {
        const usage = emit.usage;
        state.pending = &.{};
        state.completed = &.{};
        emit.* = .{ .kind = .failed, .reason = "disclosure", .message = "the Skill's output quoted its sealed content and its disclosure policy ends the run", .usage = usage };
        return;
    }
    emit.disclosure_redactions = total;
}

/// Apply one corpus under one policy to everything the Step would show;
/// returns the passages found (`off` and an empty corpus find none).
fn screenAgainst(arena: std.mem.Allocator, corpus: *const disclosure.Corpus, policy: disclosure.Policy, emit: *Gateway.Emit) Gateway.MethodError!usize {
    if (policy == .off or corpus.isEmpty()) return 0;
    var total: usize = 0;
    switch (emit.kind) {
        .final => {
            const redacted = disclosure.redactText(arena, corpus, emit.text) catch return error.OutOfMemory;
            emit.text = redacted.text;
            total += redacted.spans;
        },
        .tool_calls => {
            const calls = arena.dupe(protocol.Call, emit.calls) catch return error.OutOfMemory;
            for (calls) |*call| {
                const redacted = disclosure.redactJsonStrings(arena, corpus, call.input_json) catch return error.OutOfMemory;
                call.input_json = redacted.text;
                total += redacted.spans;
            }
            emit.calls = calls;
        },
        .input_required => {
            if (emit.question) |*question| {
                const message = disclosure.redactText(arena, corpus, question.message) catch return error.OutOfMemory;
                question.message = message.text;
                total += message.spans;
                if (question.tool_input_json.len != 0) {
                    const input = disclosure.redactJsonStrings(arena, corpus, question.tool_input_json) catch return error.OutOfMemory;
                    question.tool_input_json = input.text;
                    total += input.spans;
                }
            }
        },
        .failed => {},
    }
    return total;
}

test "the disclosure screen edits what leaves a Step, by the manifest's policy" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const rule = "R5: every invoice above the threshold needs a second approver before posting.";
    var corpus: disclosure.Corpus = .{};
    try corpus.add(al, rule);
    var manifest: protocol.Manifest = undefined;
    const entry_json = try protocol.testEntryJson(al, protocol.TEST_MANIFEST_JSON);
    const parsed = try protocol.parseEntry(al, entry_json);
    manifest = parsed.entry.manifest;
    var references: disclosure.Corpus = .{};
    try references.add(al, "Field list of the create-session request body: task, profile id, proxy country code, start url.");
    var package = Package{ .name = "x", .dir = "/pkg", .body = rule, .entry_json = entry_json, .entry = parsed.entry, .assets = &.{}, .sealed_files = &.{}, .disclosure_body = corpus, .disclosure_references = references };
    var state: Gateway.RunState = undefined;
    state.run_id = "run_1";
    state.seq = 1;
    state.pending = &.{};
    state.completed = &.{};

    // redact (the default): the final text loses the passage, the Step counts it.
    var final = Gateway.Emit{ .kind = .final, .text = "Done: every invoice above the threshold needs a second approver before posting, as the rule says.", .usage = .{} };
    try screenEmit(al, &package, &state, &final);
    try std.testing.expectEqual(protocol.StepKind.final, final.kind);
    try std.testing.expectEqualStrings("Done: [sealed], as the rule says.", final.text);
    try std.testing.expectEqual(@as(usize, 1), final.disclosure_redactions);
    // A tool input: the quoting string value is replaced, the document stays valid.
    const calls = [_]protocol.Call{.{ .id = "c1", .name = "Write", .input_json = "{\"file_path\":\"/tmp/x\",\"content\":\"every invoice above the threshold needs a second approver before posting\"}" }};
    var batch = Gateway.Emit{ .kind = .tool_calls, .calls = &calls, .usage = .{} };
    try screenEmit(al, &package, &state, &batch);
    try std.testing.expectEqual(@as(usize, 1), batch.disclosure_redactions);
    try std.testing.expectEqualStrings("{\"file_path\":\"/tmp/x\",\"content\":\"[sealed]\"}", batch.calls[0].input_json);
    // Nothing quoting: untouched, uncounted.
    var clean = Gateway.Emit{ .kind = .final, .text = "Posted the invoice; nothing to report.", .usage = .{} };
    try screenEmit(al, &package, &state, &clean);
    try std.testing.expectEqual(@as(usize, 0), clean.disclosure_redactions);
    try std.testing.expectEqualStrings("Posted the invoice; nothing to report.", clean.text);

    // fail: the Step becomes the run's failure.
    manifest.egress_disclosure = "fail";
    package.entry.manifest = manifest;
    var failing = Gateway.Emit{ .kind = .final, .text = "Done: every invoice above the threshold needs a second approver before posting.", .usage = .{} };
    try screenEmit(al, &package, &state, &failing);
    try std.testing.expectEqual(protocol.StepKind.failed, failing.kind);
    try std.testing.expectEqualStrings("disclosure", failing.reason);
    try std.testing.expect(std.mem.indexOf(u8, failing.message, "threshold") == null);

    // off: the passage passes.
    manifest.egress_disclosure = "off";
    package.entry.manifest = manifest;
    var open = Gateway.Emit{ .kind = .final, .text = "Done: every invoice above the threshold needs a second approver before posting.", .usage = .{} };
    try screenEmit(al, &package, &state, &open);
    try std.testing.expectEqual(@as(usize, 0), open.disclosure_redactions);
    try std.testing.expect(std.mem.indexOf(u8, open.text, "threshold") != null);

    // The two corpora are screened by their own policies: body redacted,
    // references quoted freely (a documentation Skill), or the reverse.
    manifest.egress_disclosure = "redact";
    manifest.egress_disclosure_references = "off";
    package.entry.manifest = manifest;
    var cited = Gateway.Emit{ .kind = .final, .text = "The create-session request body: task, profile id, proxy country code, start url. Also every invoice above the threshold needs a second approver before posting.", .usage = .{} };
    try screenEmit(al, &package, &state, &cited);
    try std.testing.expectEqual(protocol.StepKind.final, cited.kind);
    try std.testing.expectEqual(@as(usize, 1), cited.disclosure_redactions);
    try std.testing.expect(std.mem.indexOf(u8, cited.text, "proxy country code, start url") != null);
    try std.testing.expect(std.mem.indexOf(u8, cited.text, "second approver") == null);
    manifest.egress_disclosure = "off";
    manifest.egress_disclosure_references = "fail";
    package.entry.manifest = manifest;
    var leaking = Gateway.Emit{ .kind = .final, .text = "Field list of the create-session request body: task, profile id, proxy country code, start url.", .usage = .{} };
    try screenEmit(al, &package, &state, &leaking);
    try std.testing.expectEqual(protocol.StepKind.failed, leaking.kind);
    try std.testing.expectEqualStrings("disclosure", leaking.reason);
}

/// The continuation's view of the conversation (§9.2): the messages from the
/// compaction boundary on, in the transcript's own shape. The prefix the
/// boundary projected away is not carried — compaction moves a boundary, it
/// deletes nothing, so carrying it would grow `run_state` with every Step
/// until the blob no longer fits (`MAX_STATE_BYTES`). The summary that
/// stands for that prefix travels beside the window (`RunState.compact_summary`).
fn activeWindowJson(arena: std.mem.Allocator, conversation: *const Conversation) error{OutOfMemory}!std.json.Array {
    var messages = std.json.Array.init(arena);
    for (conversation.messages.items[conversation.activeStart()..]) |*message| {
        var out: std.Io.Writer.Allocating = .init(arena);
        transcript.Writer.renderMessageJson(&out.writer, message) catch return error.OutOfMemory;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{}) catch return error.OutOfMemory;
        messages.append(value) catch return error.OutOfMemory;
    }
    return messages;
}

/// Rebuild the loop's conversation from a continuation. The summary, when
/// there is one, leads as a synthetic assistant turn: that is the projection
/// the loop makes of `compact_summary` anyway (one assistant text message
/// before the active window), so the model sees the same conversation — and
/// being an ordinary message now, it is part of what the next compaction
/// summarizes, instead of being replaced and lost with the originals gone.
fn restoreConversation(arena: std.mem.Allocator, conversation: *Conversation, messages: std.json.Array, summary: ?[]const u8) !void {
    const allocator = conversation.allocator;
    if (summary) |text| {
        if (text.len != 0) {
            const blocks = try allocator.alloc(msg.Block, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .text = try allocator.dupe(u8, text) };
            errdefer allocator.free(blocks[0].text);
            try conversation.append(.{ .role = .assistant, .blocks = blocks });
        }
    }
    for (messages.items) |value| {
        const json = try protocol.serializeValue(arena, value);
        try conversation.append(try transcript.parseMessageJson(json, allocator));
    }
    conversation.compact_boundary = 0;
}

test "run_state carries the active window and the summary, not the projected prefix" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Four turns, compacted past the first two, with a summary standing in.
    var conversation = Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "first task");
    try conversation.appendText(.assistant, "first answer");
    try conversation.appendText(.user, "second task");
    try conversation.appendText(.assistant, "second answer");
    conversation.compact_boundary = 2;
    conversation.compact_summary = try a.dupe(u8, "SUMMARY of the first exchange");

    const window = try activeWindowJson(arena.allocator(), &conversation);
    try std.testing.expectEqual(@as(usize, 2), window.items.len);
    const rendered = try protocol.serializeValue(arena.allocator(), .{ .array = window });
    try std.testing.expect(std.mem.indexOf(u8, rendered, "first task") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "first answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "second task") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "second answer") != null);

    // Restored: the summary leads as an assistant turn, then the window; the
    // whole of it is active, so the next compaction summarizes the summary too.
    var restored = Conversation.init(a);
    defer restored.deinit();
    try restoreConversation(arena.allocator(), &restored, window, conversation.compact_summary);
    try std.testing.expectEqual(@as(usize, 3), restored.messages.items.len);
    try std.testing.expectEqual(msg.Role.assistant, restored.messages.items[0].role);
    try std.testing.expectEqualStrings("SUMMARY of the first exchange", restored.messages.items[0].blocks[0].text);
    try std.testing.expectEqual(msg.Role.user, restored.messages.items[1].role);
    try std.testing.expectEqualStrings("second task", restored.messages.items[1].blocks[0].text);
    try std.testing.expectEqualStrings("second answer", restored.messages.items[2].blocks[0].text);
    try std.testing.expectEqual(@as(usize, 3), restored.activeMessages().len);
    try std.testing.expect(restored.compact_summary == null);

    // No summary (never compacted): the window alone, nothing synthetic.
    var plain = Conversation.init(a);
    defer plain.deinit();
    try restoreConversation(arena.allocator(), &plain, window, null);
    try std.testing.expectEqual(@as(usize, 2), plain.messages.items.len);
    try std.testing.expectEqual(msg.Role.user, plain.messages.items[0].role);
}

// ── The capturing dispatcher ──────────────────────────────────────────────

/// The shadow loop's tool directory: every client tool is dispatchable by
/// name, none executes here. A `Read`, `Glob` or `Grep` whose target lies
/// under `<base_dir>/sealed/` is served from the package — the files that
/// never leave this process — when the manifest admits the tool; everything
/// else is marked pending so the loop suspends and the batch becomes a Step.
const RemoteDispatcher = struct {
    package: *const Package,
    base_dir: []const u8,
    defs: []const json_mod.ToolDefinition,

    fn dispatcher(self: *const RemoteDispatcher) tool_context.ToolDispatcher {
        return .{ .ctx = @ptrCast(self), .dispatchFn = &dispatchFn, .metadataFn = &metadataFn, .nameAtFn = &nameAtFn };
    }

    fn cast(ctx: *const anyopaque) *const RemoteDispatcher {
        return @ptrCast(@alignCast(ctx));
    }

    fn known(self: *const RemoteDispatcher, name: []const u8) bool {
        for (self.defs) |def| if (def.server_type == null and std.mem.eql(u8, def.name, name)) return true;
        return false;
    }

    fn metadataFn(ctx: *const anyopaque, name: []const u8) ?tool_context.ToolMeta {
        const self = cast(ctx);
        if (!self.known(name)) return null;
        return .{ .kind = .external, .category = category_mod.getToolCategory(name), .replay = .never, .prefetch_safe = false };
    }

    fn nameAtFn(ctx: *const anyopaque, index: usize) ?[]const u8 {
        const self = cast(ctx);
        var seen: usize = 0;
        for (self.defs) |def| {
            if (def.server_type != null) continue;
            if (seen == index) return def.name;
            seen += 1;
        }
        return null;
    }

    fn dispatchFn(ctx: *const anyopaque, tool_ctx: *const tool_context.ToolContext, name: []const u8, args: []const u8) anyerror!tool_context.ToolDispatchOutcome {
        const self = cast(ctx);
        if (self.servesHere(name)) {
            if (std.mem.eql(u8, name, "Read")) {
                if (try self.sealedRelativePath(tool_ctx.allocator, args)) |relative| {
                    return .{ .ok = tool_result.ToolResultBody.initInline(try self.readSealed(tool_ctx.allocator, relative)) };
                }
            } else if (try self.searchSealed(tool_ctx, name, args)) |body| {
                return .{ .ok = body };
            }
        }
        return handToClient(tool_ctx, name, args);
    }

    /// Records the call as a pending request for the client and answers
    /// `error.UiPending`. Apart from dispatchFn so that the error is not a
    /// literal `return error.X` in a function returning a ToolDispatchOutcome,
    /// which would copy a 3.7 KiB constant (doc/PERF_MEMORY_PRINCIPLES.md §3g).
    fn handToClient(tool_ctx: *const tool_context.ToolContext, name: []const u8, args: []const u8) error{ UiPending, OutOfMemory } {
        const kind: []const u8 = if (std.mem.eql(u8, name, ASK_USER_TOOL)) PENDING_QUESTION_KIND else PENDING_REMOTE_KIND;
        if (tool_ctx.pending_request) |slot| slot.* = .{
            .kind = try tool_ctx.allocator.dupe(u8, kind),
            .payload_json = try tool_ctx.allocator.dupe(u8, args),
        };
        return error.UiPending;
    }

    /// The tools the gateway may answer itself when their target is sealed:
    /// only ones the manifest admits. A call the client's policy frame would
    /// refuse is forwarded instead, so that it is refused there and counted
    /// (§6.1) like any other.
    fn servesHere(self: *const RemoteDispatcher, name: []const u8) bool {
        const local = std.mem.eql(u8, name, "Read") or std.mem.eql(u8, name, "Glob") or std.mem.eql(u8, name, "Grep");
        return local and protocol.manifestAllowsTool(&self.package.entry.manifest, name);
    }

    /// `file_path` of a Read, when it names a file under `<base_dir>/sealed/`:
    /// the path relative to the package's sealed directory.
    fn sealedRelativePath(self: *const RemoteDispatcher, allocator: std.mem.Allocator, args: []const u8) !?[]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return null;
        defer parsed.deinit();
        const path = valueString(parsed.value, "file_path") orelse return null;
        const relative = (try self.sealedRelative(allocator, path)) orelse return null;
        return if (relative.len == 0) null else relative;
    }

    /// A path under `<base_dir>/sealed`, in either separator style: its part
    /// relative to that root ("" for the root itself), confined to it — no
    /// empty, `.` or `..` segments. Null for any other path.
    fn sealedRelative(self: *const RemoteDispatcher, allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
        const path = try normalizeSlashes(allocator, raw);
        const root = try self.clientSealedRoot(allocator);
        if (std.mem.eql(u8, path, root)) return "";
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return null;
        const relative = path[root.len + 1 ..];
        var parts = std.mem.splitScalar(u8, relative, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
        }
        return relative;
    }

    /// `<base_dir>/sealed` as the brain names it, forward slashes.
    fn clientSealedRoot(self: *const RemoteDispatcher, allocator: std.mem.Allocator) ![]u8 {
        const base = try normalizeSlashes(allocator, self.base_dir);
        return std.mem.concat(allocator, u8, &.{ base, "/" ++ SEALED_DIR });
    }

    /// The package's sealed directory on this host, forward slashes.
    fn diskSealedRoot(self: *const RemoteDispatcher, allocator: std.mem.Allocator) ![]u8 {
        const dir = try normalizeSlashes(allocator, self.package.dir);
        return std.mem.concat(allocator, u8, &.{ dir, "/" ++ SEALED_DIR });
    }

    const SearchTarget = struct {
        /// Relative to the sealed root; "" is the root itself.
        relative: []const u8,
        /// Glob only: the pattern made relative to the root, when the pattern
        /// itself was an absolute path under it.
        pattern: ?[]const u8 = null,
    };

    /// Where a Glob or Grep looks, when that is under `<base_dir>/sealed`. A
    /// Glob whose `pattern` is itself an absolute path under the root is
    /// searched from the root with the pattern made relative to it (ripgrep's
    /// `--glob` matches relative to the search path); otherwise the `path`
    /// argument decides, and without one the search is the client's.
    fn sealedSearchTarget(self: *const RemoteDispatcher, allocator: std.mem.Allocator, is_glob: bool, args: std.json.Value) !?SearchTarget {
        if (is_glob) {
            if (valueString(args, "pattern")) |raw| {
                if (try self.sealedRelative(allocator, raw)) |relative| {
                    return if (relative.len == 0) null else .{ .relative = "", .pattern = relative };
                }
            }
        }
        const path = valueString(args, "path") orelse return null;
        const relative = (try self.sealedRelative(allocator, path)) orelse return null;
        return .{ .relative = relative };
    }

    /// A Glob or Grep over sealed files, answered here: the client's own tool
    /// implementation runs against the package's sealed directory, and every
    /// path in what it prints is rewritten to the client's `<base_dir>/sealed`,
    /// so the brain sees what the client's tool would have shown and can hand
    /// the paths straight back. A search over the Skill directory as a whole
    /// is not ours: it goes to the client and sees the public assets only.
    fn searchSealed(self: *const RemoteDispatcher, tool_ctx: *const tool_context.ToolContext, name: []const u8, args: []const u8) anyerror!?tool_result.ToolResultBody {
        const allocator = tool_ctx.allocator;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, args, .{}) catch return null;
        if (parsed != .object) return null;
        const is_glob = std.mem.eql(u8, name, "Glob");
        const target = (try self.sealedSearchTarget(allocator, is_glob, parsed)) orelse return null;
        const disk_root = try self.diskSealedRoot(allocator);
        const client_root = try self.clientSealedRoot(allocator);
        const disk_path = if (target.relative.len == 0) disk_root else try std.mem.concat(allocator, u8, &.{ disk_root, "/", target.relative });
        _ = read_state.statPath(disk_path) catch {
            // The client's tool reports a missing path the same way; the path
            // it names is the client's, never this host's.
            const client_path = if (target.relative.len == 0) client_root else try std.mem.concat(allocator, u8, &.{ client_root, "/", target.relative });
            tool_common.setErrorDetail(tool_ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{client_path});
            return error.PathNotFound;
        };
        var object = parsed.object;
        try object.put(allocator, "path", .{ .string = disk_path });
        if (target.pattern) |pattern| try object.put(allocator, "pattern", .{ .string = pattern });
        const local_args = try protocol.serializeValue(allocator, .{ .object = object });
        const printed = (if (is_glob) glob_tool.execute(tool_ctx, local_args) else grep_tool.execute(tool_ctx, local_args)) catch |err| {
            if (tool_ctx.error_detail) |slot| {
                if (slot.*) |detail| slot.* = rewriteSealedPaths(allocator, detail, disk_root, client_root, false) catch detail;
            }
            return err;
        };
        return tool_result.ToolResultBody.initInline(try rewriteSealedPaths(allocator, printed, disk_root, client_root, is_glob));
    }

    /// The sealed file as the client's Read tool would render it: `cat -n`
    /// numbering, so the brain sees what it would have seen locally.
    fn readSealed(self: *const RemoteDispatcher, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
        const listed = for (self.package.sealed_files) |path| {
            if (std.mem.eql(u8, path, relative)) break true;
        } else false;
        if (!listed) return error.FileNotFound;
        const full = try std.fs.path.join(allocator, &.{ self.package.dir, SEALED_DIR, relative });
        const bytes = readFile(allocator, full, MAX_SEALED_READ_BYTES) catch return error.FileNotFound;
        var out: std.ArrayList(u8) = .empty;
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            if (line.len == 0 and lines.peek() == null) break;
            try out.print(allocator, "{d: >6}\t{s}\n", .{ line_no, line });
        }
        return out.toOwnedSlice(allocator);
    }
};

/// The gateway's sealed directory, as the client's tool would have printed
/// it: every spelling of the on-disk root (forward or backslash separators)
/// becomes the client's `<base_dir>/sealed`. The Glob tool's JSON gets a
/// structural pass over its `filenames`, where on Windows the separators
/// ripgrep appended are normalized too, so the brain gets paths it can hand
/// straight back; Grep's text is rewritten by prefix only.
fn rewriteSealedPaths(allocator: std.mem.Allocator, text: []const u8, disk_root: []const u8, client_root: []const u8, glob_json: bool) ![]u8 {
    const disk_back = try std.mem.replaceOwned(u8, allocator, disk_root, "/", "\\");
    defer allocator.free(disk_back);
    if (glob_json) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch return allocator.dupe(u8, text);
        if (parsed == .object) {
            if (parsed.object.get("filenames")) |names| {
                if (names == .array) {
                    for (names.array.items) |*item| {
                        if (item.* != .string) continue;
                        var name = try std.mem.replaceOwned(u8, allocator, item.string, disk_back, client_root);
                        name = try std.mem.replaceOwned(u8, allocator, name, disk_root, client_root);
                        if (builtin.os.tag == .windows) name = try std.mem.replaceOwned(u8, allocator, name, "\\", "/");
                        item.* = .{ .string = name };
                    }
                    return @constCast(try protocol.serializeValue(allocator, parsed));
                }
            }
        }
        return allocator.dupe(u8, text);
    }
    const once = try std.mem.replaceOwned(u8, allocator, text, disk_back, client_root);
    defer allocator.free(once);
    return std.mem.replaceOwned(u8, allocator, once, disk_root, client_root);
}

fn normalizeSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    while (out.len > 1 and out[out.len - 1] == '/') return out[0 .. out.len - 1];
    return out;
}

/// The question text of an `AskUserQuestion` input: the first question, or a
/// marker the client's tool will reject with a proper error.
fn firstQuestionText(arena: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return "(malformed question)";
    if (parsed != .object) return "(malformed question)";
    const questions = parsed.object.get("questions") orelse return "(malformed question)";
    if (questions != .array or questions.array.items.len == 0) return "(malformed question)";
    return valueString(questions.array.items[0], "question") orelse "(malformed question)";
}

fn findToolUse(conversation: *const Conversation, id: []const u8) ?msg.ToolUse {
    var index = conversation.messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = conversation.messages.items[index];
        if (message.role != .assistant) continue;
        for (message.blocks) |block| switch (block) {
            .tool_use => |use| if (std.mem.eql(u8, use.id, id)) return use,
            else => {},
        };
        return null;
    }
    return null;
}

/// The text of the last assistant message: the Skill's result.
fn lastAssistantText(arena: std.mem.Allocator, conversation: *const Conversation) ![]const u8 {
    var index = conversation.messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = conversation.messages.items[index];
        if (message.role != .assistant) continue;
        var out: std.ArrayList(u8) = .empty;
        for (message.blocks) |block| switch (block) {
            .text => |text| try out.appendSlice(arena, text),
            else => {},
        };
        return out.items;
    }
    return "";
}

/// §6.4: the manifest-declared references whose placeholder appears in the
/// call's input, so the client knows which secrets the call needs.
fn declaredCredentialRefs(arena: std.mem.Allocator, package: *const Package, input_json: []const u8) Gateway.MethodError![]const []const u8 {
    const found = credentials.placeholderRefs(arena, input_json) catch return error.OutOfMemory;
    var declared: std.ArrayList([]const u8) = .empty;
    for (found) |ref| {
        for (package.entry.manifest.credentials) |credential| {
            if (std.mem.eql(u8, credential.ref, ref)) {
                declared.append(arena, ref) catch return error.OutOfMemory;
                break;
            }
        }
    }
    return declared.items;
}

// ── Packages ──────────────────────────────────────────────────────────────

fn loadPackages(arena: std.mem.Allocator, skills_dir: []const u8) Error![]const Package {
    const dir_z = arena.dupeZ(u8, skills_dir) catch return error.OutOfMemory;
    var iterator = pdir.open(dir_z) orelse return error.SkillsDirUnreadable;
    defer pdir.close(&iterator);
    var packages: std.ArrayList(Package) = .empty;
    while (pdir.next(&iterator)) |entry| {
        if (!entry.is_dir) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const name = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        const package_dir = std.fs.path.join(arena, &.{ skills_dir, name }) catch return error.OutOfMemory;
        const package = try loadPackage(arena, package_dir, name);
        packages.append(arena, package) catch return error.OutOfMemory;
    }
    std.mem.sort(Package, packages.items, {}, packageLessThan);
    return packages.toOwnedSlice(arena) catch return error.OutOfMemory;
}

fn packageLessThan(_: void, lhs: Package, rhs: Package) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

pub fn loadPackage(arena: std.mem.Allocator, package_dir: []const u8, name: []const u8) Error!Package {
    const md_path = std.fs.path.join(arena, &.{ package_dir, "SKILL.md" }) catch return error.OutOfMemory;
    const md = readFile(arena, md_path, MAX_REQUEST_BYTES) catch return error.InvalidPackage;
    const skill = definition.parseSkillMdWithFallback(arena, md, md_path, name) catch return error.InvalidPackage;
    const manifest_path = std.fs.path.join(arena, &.{ package_dir, "manifest.json" }) catch return error.OutOfMemory;
    const manifest_json = readFile(arena, manifest_path, MAX_REQUEST_BYTES) catch return error.InvalidPackage;
    const manifest_value = std.json.parseFromSliceLeaky(std.json.Value, arena, manifest_json, .{}) catch return error.InvalidPackage;
    const canonical = protocol.canonicalize(arena, manifest_value) catch return error.InvalidPackage;
    const digest = protocol.digestHex(arena, canonical) catch return error.OutOfMemory;
    const manifest = protocol.manifestFromValue(arena, manifest_value) catch return error.InvalidPackage;
    if (!std.mem.eql(u8, manifest.name, name)) return error.InvalidPackage;

    // Public assets: every regular file except the Skill's own two documents
    // and the sealed set, which is listed separately and never served.
    var assets: std.ArrayList(Asset) = .empty;
    var sealed_files: std.ArrayList([]const u8) = .empty;
    try collectFiles(arena, package_dir, "", &assets, &sealed_files);
    std.mem.sort(Asset, assets.items, {}, assetLessThan);
    std.mem.sort([]const u8, sealed_files.items, {}, pathLessThan);

    var assets_json: std.Io.Writer.Allocating = .init(arena);
    const aw = &assets_json.writer;
    aw.writeByte('[') catch return error.OutOfMemory;
    for (assets.items, 0..) |asset, index| {
        if (index != 0) aw.writeByte(',') catch return error.OutOfMemory;
        aw.writeAll("{\"path\":") catch return error.OutOfMemory;
        protocol.writeString(aw, asset.path) catch return error.OutOfMemory;
        aw.writeAll(",\"sha256\":") catch return error.OutOfMemory;
        protocol.writeString(aw, asset.sha256) catch return error.OutOfMemory;
        aw.print(",\"bytes\":{d}}}", .{asset.bytes}) catch return error.OutOfMemory;
    }
    aw.writeByte(']') catch return error.OutOfMemory;

    const entry_json = std.fmt.allocPrint(
        arena,
        "{{\"skill_id\":{s},\"version\":{s},\"manifest\":{s},\"manifest_digest\":\"{s}\",\"subscription\":{{\"state\":\"active\"}},\"assets\":{s}}}",
        .{ quoted(arena, manifest.skill_id) catch return error.OutOfMemory, quoted(arena, manifest.version) catch return error.OutOfMemory, canonical, digest, assets_json.written() },
    ) catch return error.OutOfMemory;
    const parsed = protocol.parseEntry(arena, entry_json) catch return error.InvalidPackage;
    // §8.5: the sealed material the brain must not restate — the body and
    // every sealed file — as the screen's corpus.
    var body_corpus: disclosure.Corpus = .{};
    body_corpus.add(arena, skill.body) catch return error.OutOfMemory;
    var references_corpus: disclosure.Corpus = .{};
    for (sealed_files.items) |relative| {
        const full = std.fs.path.join(arena, &.{ package_dir, SEALED_DIR, relative }) catch return error.OutOfMemory;
        const bytes = readFile(arena, full, MAX_REQUEST_BYTES) catch return error.InvalidPackage;
        references_corpus.add(arena, bytes) catch return error.OutOfMemory;
    }
    // The entry's arena is a child of ours; keep the parsed view alive by
    // never calling deinit (it is freed with `arena`).
    return .{
        .name = name,
        .dir = package_dir,
        .body = std.mem.trim(u8, skill.body, " \r\n\t"),
        .entry_json = entry_json,
        .entry = parsed.entry,
        .assets = assets.toOwnedSlice(arena) catch return error.OutOfMemory,
        .sealed_files = sealed_files.toOwnedSlice(arena) catch return error.OutOfMemory,
        .disclosure_body = body_corpus,
        .disclosure_references = references_corpus,
    };
}

fn assetLessThan(_: void, lhs: Asset, rhs: Asset) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Walk `root/<prefix>` recursively. Top-level `SKILL.md` and `manifest.json`
/// are the Skill's own documents; the top-level `sealed/` tree is listed as
/// sealed; dotfiles are skipped; everything else is a public asset.
fn collectFiles(arena: std.mem.Allocator, root: []const u8, prefix: []const u8, assets: *std.ArrayList(Asset), sealed_files: *std.ArrayList([]const u8)) Error!void {
    const dir_path = if (prefix.len == 0) root else (joinRelative(arena, root, prefix) catch return error.OutOfMemory);
    const dir_z = arena.dupeZ(u8, dir_path) catch return error.OutOfMemory;
    var iterator = pdir.open(dir_z) orelse return error.InvalidPackage;
    defer pdir.close(&iterator);
    while (pdir.next(&iterator)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const relative = if (prefix.len == 0)
            arena.dupe(u8, entry.name) catch return error.OutOfMemory
        else
            std.mem.concat(arena, u8, &.{ prefix, "/", entry.name }) catch return error.OutOfMemory;
        if (entry.is_dir) {
            try collectFiles(arena, root, relative, assets, sealed_files);
            continue;
        }
        if (prefix.len == 0 and (std.mem.eql(u8, entry.name, "SKILL.md") or std.mem.eql(u8, entry.name, "manifest.json"))) continue;
        if (std.mem.startsWith(u8, relative, SEALED_DIR ++ "/")) {
            sealed_files.append(arena, relative[SEALED_DIR.len + 1 ..]) catch return error.OutOfMemory;
            continue;
        }
        if (!protocol.validAssetPath(relative)) continue;
        const full = joinRelative(arena, root, relative) catch return error.OutOfMemory;
        const bytes = readFile(arena, full, protocol.MAX_ASSET_BYTES) catch return error.InvalidPackage;
        const digest = protocol.digestHex(arena, bytes) catch return error.OutOfMemory;
        assets.append(arena, .{ .path = relative, .sha256 = digest, .bytes = bytes.len }) catch return error.OutOfMemory;
    }
}

/// `root/relative` with the package-relative `/` path on this platform.
fn joinRelative(arena: std.mem.Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(arena, root);
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| try parts.append(arena, segment);
    return std.fs.path.join(arena, parts.items);
}

fn quoted(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeString(&out.writer, value);
    return out.written();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, cap: usize) ![]u8 {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
        if (out.items.len > cap) return error.TooLarge;
    }
    return out.toOwnedSlice(allocator);
}

// ── Conversions ───────────────────────────────────────────────────────────

/// The client's tool definitions (§4.1) plus its provider-side server tools,
/// in the neutral request type.
fn toolDefinitions(arena: std.mem.Allocator, tools: std.json.Value, provider_tools: std.json.Value) Gateway.MethodError![]const json_mod.ToolDefinition {
    if (tools != .array or provider_tools != .array) return error.InvalidParams;
    const out = arena.alloc(json_mod.ToolDefinition, tools.array.items.len + provider_tools.array.items.len) catch return error.OutOfMemory;
    for (tools.array.items, out[0..tools.array.items.len]) |tool, *slot| {
        const name = valueString(tool, "name") orelse return error.InvalidParams;
        var schema: json_mod.InputSchema = .{};
        if (tool == .object) if (tool.object.get("input_schema")) |raw| {
            if (raw != .object) return error.InvalidParams;
            if (raw.object.get("properties")) |properties| {
                if (properties != .object) return error.InvalidParams;
                schema.properties = properties.object;
            }
            if (raw.object.get("required")) |required| {
                if (required != .array) return error.InvalidParams;
                const names = arena.alloc([]const u8, required.array.items.len) catch return error.OutOfMemory;
                for (required.array.items, names) |item, *target| {
                    if (item != .string) return error.InvalidParams;
                    target.* = item.string;
                }
                schema.required = names;
            }
            if (raw.object.get("additionalProperties")) |extra| {
                if (extra == .bool) schema.additional_properties = extra.bool;
            }
        };
        slot.* = .{
            .name = name,
            .description = valueString(tool, "description") orelse "",
            .input_schema = schema,
            // The client's loop advertised this deferred tool as-is; so does
            // the shadow's (and keeps ToolSearch for it, as the client does).
            .deferred = valueBool(tool, "deferred") orelse false,
        };
    }
    for (provider_tools.array.items, out[tools.array.items.len..]) |tool, *slot| {
        const name = valueString(tool, "name") orelse return error.InvalidParams;
        const server_type = valueString(tool, "type") orelse return error.InvalidParams;
        slot.* = .{
            .name = name,
            .description = valueString(tool, "description") orelse "",
            .input_schema = .{},
            .server_type = server_type,
        };
    }
    return out;
}

fn stringList(arena: std.mem.Allocator, value: ?std.json.Value) Gateway.MethodError![]const []const u8 {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidParams;
    const out = arena.alloc([]const u8, list.array.items.len) catch return error.OutOfMemory;
    for (list.array.items, out) |item, *slot| {
        if (item != .string) return error.InvalidParams;
        slot.* = item.string;
    }
    return out;
}

fn listContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn findResult(results: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (results) |result| {
        const got = valueString(result, "tool_use_id") orelse continue;
        if (std.mem.eql(u8, got, id)) return result;
    }
    return null;
}

fn paramString(params: std.json.Value, key: []const u8) ?[]const u8 {
    return valueString(params, key);
}

fn valueString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn valueBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn valueInteger(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .integer) field.integer else null;
}

fn valueUnsigned(value: std.json.Value, key: []const u8) ?u64 {
    const raw = valueInteger(value, key) orelse return null;
    return if (raw >= 0) @intCast(raw) else null;
}

fn writeId(w: *std.Io.Writer, id: ?std.json.Value) !void {
    if (id) |value| {
        try std.json.Stringify.value(value, .{}, w);
    } else try w.writeAll("null");
}

/// A JSON-RPC error whose `data` is `extra_json` with `code` merged in.
fn rpcErrorWithData(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8, known: protocol.ErrorCode, extra_json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try protocol.writeString(w, message);
    try w.writeAll(",\"data\":{\"code\":");
    try protocol.writeString(w, known.name());
    const inner = std.mem.trim(u8, extra_json, " ");
    if (inner.len > 2 and inner[0] == '{') {
        try w.writeByte(',');
        try w.writeAll(inner[1 .. inner.len - 1]);
    }
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn rpcError(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8, known: ?protocol.ErrorCode, data_json: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try protocol.writeString(w, message);
    if (known != null or data_json != null) {
        try w.writeAll(",\"data\":{");
        var first = true;
        if (known) |k| {
            try w.writeAll("\"code\":");
            try protocol.writeString(w, k.name());
            first = false;
        }
        if (data_json) |data| {
            if (!first) try w.writeByte(',');
            try w.writeAll("\"current\":");
            try w.writeAll(data);
        }
        try w.writeByte('}');
    }
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

// ── HTTP server ───────────────────────────────────────────────────────────

/// Loopback HTTP/1.1 front for a Gateway (design §3, §6): one accept
/// thread, a bounded queue, a fixed set of worker threads, and a cap on
/// Steps whose model call is in flight. Over-capacity requests are refused
/// before any work is done on them — HTTP 503 with `Retry-After` when no
/// worker can take the connection, the JSON-RPC `rate_limited` error with
/// `retry_after_ms` when every model slot is busy — and both mean "not
/// processed, resend unchanged" (§8.4). A Step is answered as an SSE stream
/// whose only events are keepalive comments while the model works and the
/// JSON-RPC response at the end, so proxies and the client's liveness
/// monitor never see a silent connection. TLS, fan-out across processes and
/// non-loopback exposure stay a reverse proxy's job.
pub const ServerOptions = struct {
    port: u16 = 0,
    /// Worker threads; 0 = 4 × CPU count (a Step is mostly waiting on the
    /// upstream model).
    workers: usize = 0,
    /// Accepted connections waiting for a worker; 0 = 4 × workers.
    queue_depth: usize = 0,
    /// Steps whose model call may be in flight at once; 0 = workers.
    max_model_calls: usize = 0,
    /// SSE keepalive interval while a Step is computed; 0 disables.
    keepalive_ms: u64 = 15_000,
};

pub const ServerStats = struct {
    accepted: u64,
    served: u64,
    rejected_queue: u64,
    rejected_model: u64,
    workers: usize,
    queue_depth: usize,
    max_model_calls: usize,
    /// Summed queue wait (ms) over served connections.
    queue_wait_ms: u64,
};

/// What an admission rejection tells the client to wait before resending.
pub const QUEUE_RETRY_AFTER_MS: u64 = 1_000;
pub const MODEL_RETRY_AFTER_MS: u64 = 200;

/// A connection waiting for a worker, with when it was accepted.
const Queued = struct { fd: net.Socket, accepted_ms: u64 };

pub const Server = struct {
    allocator: std.mem.Allocator,
    gateway: *Gateway,
    listener: net.Socket,
    port: u16,
    workers_wanted: usize,
    queue_depth: usize,
    max_model_calls: usize,
    keepalive_ms: u64,
    accept_thread: std.Thread = undefined,
    workers: []std.Thread = &.{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: psync.Mutex = .{},
    cond: psync.Condition = .{},
    queue: std.ArrayList(Queued) = .empty,
    model_in_flight: usize = 0,
    /// Summed milliseconds connections spent between accept and a worker.
    timing_queue_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    served: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_queue: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_model: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(allocator: std.mem.Allocator, gateway: *Gateway, port: u16) !*Server {
        return startWith(allocator, gateway, .{ .port = port });
    }

    pub fn startWith(allocator: std.mem.Allocator, gateway: *Gateway, options: ServerOptions) !*Server {
        const cpus = std.Thread.getCpuCount() catch 1;
        const workers_wanted = if (options.workers != 0) options.workers else @max(cpus * 4, 4);
        const queue_depth = if (options.queue_depth != 0) options.queue_depth else workers_wanted * 4;
        const max_model_calls = if (options.max_model_calls != 0) options.max_model_calls else workers_wanted;
        // The process-wide request-setup gate counts the wait for a model's
        // first byte; its CLI default of 8 would cap this server at 8
        // concurrent model calls (design §3).
        connection_gate.raiseProcessLimit(max_model_calls);
        const listener = try net.listenLoopback(options.port, @intCast(@min(queue_depth + workers_wanted, 1024)));
        errdefer net.closeSocket(listener.sock);
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .gateway = gateway,
            .listener = listener.sock,
            .port = listener.port,
            .workers_wanted = workers_wanted,
            .queue_depth = queue_depth,
            .max_model_calls = max_model_calls,
            .keepalive_ms = options.keepalive_ms,
        };
        const workers = try allocator.alloc(std.Thread, workers_wanted);
        errdefer allocator.free(workers);
        var spawned: usize = 0;
        errdefer {
            self.closing.store(true, .release);
            self.mutex.lock();
            self.cond.broadcast();
            self.mutex.unlock();
            for (workers[0..spawned]) |thread| thread.join();
        }
        for (workers) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }
        self.workers = workers;
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.closing.store(true, .release);
        // Wake a blocked accept deterministically on every platform.
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        self.accept_thread.join();
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();
        for (self.workers) |thread| thread.join();
        // Connections still queued were never answered; close them.
        for (self.queue.items) |queued| net.closeSocket(queued.fd);
        self.queue.deinit(self.allocator);
        self.allocator.free(self.workers);
        net.closeSocket(self.listener);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/ssp", .{self.port});
    }

    pub fn stats(self: *Server) ServerStats {
        return .{
            .accepted = self.accepted.load(.monotonic),
            .served = self.served.load(.monotonic),
            .rejected_queue = self.rejected_queue.load(.monotonic),
            .rejected_model = self.rejected_model.load(.monotonic),
            .workers = self.workers_wanted,
            .queue_depth = self.queue_depth,
            .max_model_calls = self.max_model_calls,
            .queue_wait_ms = self.timing_queue_ms.load(.monotonic),
        };
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            const conn = net.acceptConn(self.listener) orelse {
                if (self.closing.load(.acquire)) return;
                continue;
            };
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            _ = self.accepted.fetchAdd(1, .monotonic);
            self.mutex.lock();
            if (self.queue.items.len >= self.queue_depth) {
                self.mutex.unlock();
                _ = self.rejected_queue.fetchAdd(1, .monotonic);
                // Refused before a byte is read: the cheapest possible path.
                rejectOverloaded(conn, QUEUE_RETRY_AFTER_MS);
                net.closeSocket(conn);
                continue;
            }
            self.queue.append(self.allocator, .{ .fd = conn, .accepted_ms = @intCast(util_time.nowMs()) }) catch {
                self.mutex.unlock();
                net.closeSocket(conn);
                continue;
            };
            self.cond.signal();
            self.mutex.unlock();
        }
    }

    fn workerLoop(self: *Server) void {
        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and !self.closing.load(.acquire)) self.cond.wait(&self.mutex);
            if (self.queue.items.len == 0) {
                self.mutex.unlock();
                return;
            }
            const queued = self.queue.orderedRemove(0);
            self.mutex.unlock();
            _ = self.timing_queue_ms.fetchAdd(@as(u64, @intCast(util_time.nowMs())) -| queued.accepted_ms, .monotonic);
            self.handleConn(queued.fd);
            _ = self.served.fetchAdd(1, .monotonic);
        }
    }

    fn tryAcquireModelSlot(self: *Server) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.model_in_flight >= self.max_model_calls) return false;
        self.model_in_flight += 1;
        return true;
    }

    fn releaseModelSlot(self: *Server) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.model_in_flight -= 1;
    }

    fn handleConn(self: *Server, fd: net.Socket) void {
        defer net.closeSocket(fd);
        net.setRecvTimeoutMs(fd, 30_000);
        net.setSendTimeoutMs(fd, 30_000);
        const cap = MAX_REQUEST_BYTES;
        // The buffer starts small and grows to the declared length: a cap-sized
        // (16 MiB) buffer allocated and zeroed per connection was the gateway's
        // largest per-Step cost (design §7, found by `sealed:bench`).
        var buf = self.allocator.alloc(u8, INITIAL_REQUEST_BYTES) catch return;
        var total: usize = 0;
        defer {
            // The client's provider credential arrives in this buffer and
            // lives nowhere else; what was written is zeroed before it goes back.
            @memset(buf[0..total], 0);
            self.allocator.free(buf);
        }
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (headers_end == null) {
            if (total == buf.len) {
                if (buf.len >= cap) return;
                buf = self.allocator.realloc(buf, @min(buf.len * 2, cap)) catch return;
            }
            const n = net.recv(fd, buf[total..]);
            if (n <= 0) return;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                headers_end = i + 4;
                content_length = headerUnsigned(buf[0..i], "content-length") orelse 0;
            }
        }
        const he = headers_end orelse return;
        if (content_length > cap - he) {
            writeResponse(fd, "413 Payload Too Large", "{\"error\":\"too large\"}");
            return;
        }
        if (he + content_length > buf.len) buf = self.allocator.realloc(buf, he + content_length) catch return;
        while ((total - he) < content_length) {
            const n = net.recv(fd, buf[total .. he + content_length]);
            if (n <= 0) return;
            total += @intCast(n);
        }
        const head = buf[0..(he - 4)];
        const body = buf[he..total];

        const version = headerValue(head, protocol.VERSION_HEADER);
        if (version == null or !std.mem.eql(u8, std.mem.trim(u8, version.?, " "), protocol.VERSION_HEADER_VALUE)) {
            const err = rpcError(self.allocator, null, @intFromEnum(protocol.ErrorCode.unsupported_version), "Sealed-Skill-Version 1 required", .unsupported_version, null) catch return;
            defer self.allocator.free(err);
            writeResponse(fd, "400 Bad Request", err);
            return;
        }
        if (!self.gateway.authorized(headerValue(head, "authorization"))) {
            writeResponse(fd, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
            return;
        }
        const credential = std.mem.trim(u8, headerValue(head, protocol.PROVIDER_CREDENTIAL_HEADER) orelse "", " ");

        // Admission for the two methods that call the model (design §6):
        // judged on the request line of the body, before any state is
        // decrypted, with the retry hint in the JSON-RPC error.
        const calls_model = bodyCallsModel(body);
        if (calls_model and !self.tryAcquireModelSlot()) {
            _ = self.rejected_model.fetchAdd(1, .monotonic);
            const id = requestId(self.allocator, body);
            defer if (id) |parsed| parsed.deinit();
            var data_buf: [64]u8 = undefined;
            const data = std.fmt.bufPrint(&data_buf, "{{\"retry_after_ms\":{d}}}", .{MODEL_RETRY_AFTER_MS}) catch return;
            const err = rpcErrorWithData(self.allocator, if (id) |parsed| parsed.value else null, @intFromEnum(protocol.ErrorCode.rate_limited), "every model slot is busy; resend after retry_after_ms", .rate_limited, data) catch return;
            defer self.allocator.free(err);
            writeResponse(fd, "200 OK", err);
            return;
        }
        defer if (calls_model) self.releaseModelSlot();

        if (!calls_model) {
            const response = self.gateway.handle(self.allocator, body, credential) catch |err| {
                log.warn("sealed-gw", "request failed: {s}", .{@errorName(err)});
                writeResponse(fd, "500 Internal Server Error", "{\"error\":\"internal\"}");
                return;
            };
            defer self.allocator.free(response);
            writeResponse(fd, "200 OK", response);
            return;
        }

        // A Step: SSE head now, keepalive comments while the model works,
        // the response as the final event.
        if (!writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")) return;
        var pinger = Pinger{ .fd = fd, .interval_ms = self.keepalive_ms };
        pinger.start();
        const response = self.gateway.handle(self.allocator, body, credential) catch |err| {
            pinger.finish();
            log.warn("sealed-gw", "request failed: {s}", .{@errorName(err)});
            _ = writeAll(fd, "data: {\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal\"}}\n\n");
            return;
        };
        defer self.allocator.free(response);
        pinger.finish();
        if (pinger.failed.load(.acquire)) return;
        if (!writeAll(fd, "data: ")) return;
        if (!writeAll(fd, response)) return;
        _ = writeAll(fd, "\n\n");
    }
};

/// Keepalive comments on an SSE stream while the worker computes the Step.
/// `finish` joins the thread before the worker writes the final event, so
/// the socket never sees two writers at once.
const Pinger = struct {
    fd: net.Socket,
    interval_ms: u64,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn start(self: *Pinger) void {
        if (self.interval_ms == 0) return;
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch null;
    }

    fn loop(self: *Pinger) void {
        while (!self.stop.load(.acquire)) {
            var waited: u64 = 0;
            while (waited < self.interval_ms and !self.stop.load(.acquire)) : (waited += 50) util_time.sleepMs(50);
            if (self.stop.load(.acquire)) return;
            if (!writeAll(self.fd, ": ping\n\n")) {
                self.failed.store(true, .release);
                return;
            }
        }
    }

    fn finish(self: *Pinger) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

/// Whether the request body names `runs.start` or `runs.continue`, judged
/// on the method string alone (a cheap scan, no JSON parse).
fn bodyCallsModel(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"" ++ "sealed/runs.start" ++ "\"") != null or
        std.mem.indexOf(u8, body, "\"" ++ "sealed/runs.continue" ++ "\"") != null;
}

/// The JSON-RPC id of a request body, for an error answered before `handle`.
fn requestId(allocator: std.mem.Allocator, body: []const u8) ?std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    const id = parsed.value.object.get("id") orelse {
        parsed.deinit();
        return null;
    };
    parsed.value = id;
    return parsed;
}

/// HTTP 503 with `Retry-After` and a JSON-RPC `rate_limited` body: nothing
/// of the request is parsed, so the client resends it unchanged. The bytes
/// the client is still sending are drained (bounded) after the answer and
/// before the close: closing with unread input resets the connection on
/// Windows and the client never sees the 503.
fn rejectOverloaded(fd: net.Socket, retry_after_ms: u64) void {
    defer drainBriefly(fd);
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"gateway at capacity; resend after retry_after_ms\",\"data\":{{\"code\":\"rate_limited\",\"retry_after_ms\":{d}}}}}}}", .{ @intFromEnum(protocol.ErrorCode.rate_limited), retry_after_ms }) catch return;
    var head_buf: [256]u8 = undefined;
    const retry_after_s = @max(retry_after_ms / 1000, 1);
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: {d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ retry_after_s, body.len }) catch return;
    if (!writeAll(fd, head)) return;
    _ = writeAll(fd, body);
}

/// Read and discard what the peer sends until it stops or a short timeout,
/// after the response went out (the peer closes once it has read it).
fn drainBriefly(fd: net.Socket) void {
    net.setRecvTimeoutMs(fd, 250);
    var sink: [4096]u8 = undefined;
    var rounds: u8 = 0;
    while (rounds < 64) : (rounds += 1) {
        const n = net.recv(fd, &sink);
        if (n <= 0) return;
    }
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn headerUnsigned(head: []const u8, name: []const u8) ?usize {
    const value = headerValue(head, name) orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn writeResponse(fd: net.Socket, status: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    if (!writeAll(fd, head)) return;
    _ = writeAll(fd, body);
}

fn writeAll(fd: net.Socket, bytes: []const u8) bool {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = net.send(fd, bytes[pos..]);
        if (n <= 0) return false;
        pos += @intCast(n);
    }
    return true;
}

const rng = @import("platform").rng;

fn fillRandom(buf: []u8) error{OutOfMemory}!void {
    // The platform RNG is the OS CSPRNG; a failure to read it is fatal for a
    // key or nonce, so it surfaces as an error instead of a predictable value.
    if (!rng.randomBytes(buf)) return error.OutOfMemory;
}

test "sealed read paths are confined to <base_dir>/sealed/" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const package = Package{ .name = "x", .dir = "/pkg", .body = "", .entry_json = "", .entry = undefined, .assets = &.{}, .sealed_files = &.{"notes.md"}, .disclosure_body = .{}, .disclosure_references = .{} };
    const dispatcher = RemoteDispatcher{ .package = &package, .base_dir = "C:\\Users\\u\\.metacodes\\sealed-skills\\x", .defs = &.{} };
    const inside = try dispatcher.sealedRelativePath(arena.allocator(), "{\"file_path\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed/notes.md\"}");
    try std.testing.expectEqualStrings("notes.md", inside.?);
    try std.testing.expect((try dispatcher.sealedRelativePath(arena.allocator(), "{\"file_path\":\"C:/Users/u/.metacodes/sealed-skills/x/scripts/post.py\"}")) == null);
    try std.testing.expect((try dispatcher.sealedRelativePath(arena.allocator(), "{\"file_path\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed/../manifest.json\"}")) == null);
    try std.testing.expect((try dispatcher.sealedRelativePath(arena.allocator(), "{\"file_path\":\"/etc/passwd\"}")) == null);
    try std.testing.expect((try dispatcher.sealedRelativePath(arena.allocator(), "not json")) == null);
}

test "sealed searches: Glob and Grep under <base_dir>/sealed are the gateway's, the Skill directory as a whole is not" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const package = Package{ .name = "x", .dir = "/srv/packages/x", .body = "", .entry_json = "", .entry = undefined, .assets = &.{}, .sealed_files = &.{"notes.md"}, .disclosure_body = .{}, .disclosure_references = .{} };
    const dispatcher = RemoteDispatcher{ .package = &package, .base_dir = "C:\\Users\\u\\.metacodes\\sealed-skills\\x", .defs = &.{} };
    const Parse = struct {
        fn value(arena_allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, json, .{});
        }
    };
    // A Glob by an absolute pattern: searched from the root, pattern made relative.
    const by_pattern = (try dispatcher.sealedSearchTarget(al, true, try Parse.value(al, "{\"pattern\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed/**/*.md\"}"))).?;
    try std.testing.expectEqualStrings("", by_pattern.relative);
    try std.testing.expectEqualStrings("**/*.md", by_pattern.pattern.?);
    // A Glob by path, in the client's own separators; the relative pattern stays.
    const by_path = (try dispatcher.sealedSearchTarget(al, true, try Parse.value(al, "{\"pattern\":\"*.md\",\"path\":\"C:\\\\Users\\\\u\\\\.metacodes\\\\sealed-skills\\\\x\\\\sealed\\\\sub\"}"))).?;
    try std.testing.expectEqualStrings("sub", by_path.relative);
    try std.testing.expect(by_path.pattern == null);
    // A Grep at the root itself.
    const at_root = (try dispatcher.sealedSearchTarget(al, false, try Parse.value(al, "{\"pattern\":\"x\",\"path\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed\"}"))).?;
    try std.testing.expectEqualStrings("", at_root.relative);
    // The Skill directory as a whole, a public subdirectory, a traversal, no path at all: the client's.
    try std.testing.expect((try dispatcher.sealedSearchTarget(al, false, try Parse.value(al, "{\"pattern\":\"x\",\"path\":\"C:/Users/u/.metacodes/sealed-skills/x\"}"))) == null);
    try std.testing.expect((try dispatcher.sealedSearchTarget(al, true, try Parse.value(al, "{\"pattern\":\"**/*\",\"path\":\"C:/Users/u/.metacodes/sealed-skills/x/scripts\"}"))) == null);
    try std.testing.expect((try dispatcher.sealedSearchTarget(al, false, try Parse.value(al, "{\"pattern\":\"x\",\"path\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed/../manifest.json\"}"))) == null);
    try std.testing.expect((try dispatcher.sealedSearchTarget(al, false, try Parse.value(al, "{\"pattern\":\"x\"}"))) == null);
    try std.testing.expect((try dispatcher.sealedSearchTarget(al, true, try Parse.value(al, "{\"pattern\":\"C:/Users/u/.metacodes/sealed-skills/x/sealed\"}"))) == null);
}

test "sealed search output names the client's sealed directory, never the gateway's" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const disk = "D:/srv/packages/x/sealed";
    const client = "C:/Users/u/.metacodes/sealed-skills/x/sealed";
    // Grep text: the prefix in either spelling becomes the client's root.
    const grep_out = try rewriteSealedPaths(al, "D:/srv/packages/x/sealed\\notes.md:1:RULE\nD:\\srv\\packages\\x\\sealed\\sub\\r.md:2:RULE\n", disk, client, false);
    try std.testing.expectEqualStrings("C:/Users/u/.metacodes/sealed-skills/x/sealed\\notes.md:1:RULE\nC:/Users/u/.metacodes/sealed-skills/x/sealed\\sub\\r.md:2:RULE\n", grep_out);
    // Glob JSON: each file name rewritten; on Windows its separators normalized as well.
    const glob_out = try rewriteSealedPaths(al, "{\"filenames\":[\"D:/srv/packages/x/sealed\\\\notes.md\",\"D:\\\\srv\\\\packages\\\\x\\\\sealed\\\\sub\\\\r.md\"],\"numFiles\":2,\"truncated\":false,\"durationMs\":0}", disk, client, true);
    try std.testing.expect(std.mem.indexOf(u8, glob_out, "D:") == null);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("{\"filenames\":[\"C:/Users/u/.metacodes/sealed-skills/x/sealed/notes.md\",\"C:/Users/u/.metacodes/sealed-skills/x/sealed/sub/r.md\"],\"numFiles\":2,\"truncated\":false,\"durationMs\":0}", glob_out);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, glob_out, "C:/Users/u/.metacodes/sealed-skills/x/sealed\\\\notes.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, glob_out, "\"numFiles\":2") != null);
    }
    // Text that is not the Glob JSON passes through untouched apart from the prefix.
    const other = try rewriteSealedPaths(al, "no paths here", disk, client, true);
    try std.testing.expectEqualStrings("no paths here", other);
}

test "the first question of an AskUserQuestion input is the Step's message" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Which ledger?", try firstQuestionText(arena.allocator(), "{\"questions\":[{\"question\":\"Which ledger?\",\"options\":[]}]}"));
    try std.testing.expectEqualStrings("(malformed question)", try firstQuestionText(arena.allocator(), "{\"schema\":{}}"));
}
