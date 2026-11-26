//! Sealed Skill Protocol (SSP/1) wire objects — doc/SEALED_SKILL_PROTOCOL.md.
//!
//! This module owns the shapes only: manifests and Entries (§5, §3.2), Steps
//! (§4.3), request parameter writers (§3.4–§3.6), the JSON-RPC envelope and
//! error table (§10), and canonical-JSON digests (§4.5). It performs no I/O and
//! no policy; `provider.zig` drives a run and `transport.zig` moves bytes.
//!
//! Parsed objects borrow from an arena owned by the `Parsed*` wrapper so a
//! Step or Entry is one allocation-lifetime, freed in one call.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const PROTOCOL_ID = "metask.sealed-skill/v1";
pub const REVISION = "2026-10-15";
pub const VERSION_HEADER = "Sealed-Skill-Version";
pub const VERSION_HEADER_VALUE = "1";
pub const MANIFEST_SCHEMA = "metask.sealed-skill.manifest/v1";
/// `prev_digest` of the first Step of a run: SHA-256 rendering of 32 zero bytes.
pub const GENESIS_DIGEST = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
pub const DEFAULT_MAX_RESULT_BYTES: u64 = 65536;
/// Hard cap on any single JSON document this client will parse from a gateway.
/// A Step carries the run's whole conversation in `run_state` (§4.4), so this
/// is sized like a model context, not like a control message.
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
/// §8.1: the client's provider credential for this request, as the client's
/// own provider would send it. A header, not a parameter: it is never part of
/// a digested object, never echoed and never logged.
pub const PROVIDER_CREDENTIAL_HEADER = "Sealed-Provider-Credential";
/// Largest public asset (§5 `assets`) a client will install.
pub const MAX_ASSET_BYTES: usize = 8 * 1024 * 1024;

pub const Method = enum {
    discover,
    skills_list,
    skills_get,
    skills_asset,
    runs_start,
    runs_continue,
    runs_cancel,

    pub fn wire(self: Method) []const u8 {
        return switch (self) {
            .discover => "sealed/discover",
            .skills_list => "sealed/skills.list",
            .skills_get => "sealed/skills.get",
            .skills_asset => "sealed/skills.asset",
            .runs_start => "sealed/runs.start",
            .runs_continue => "sealed/runs.continue",
            .runs_cancel => "sealed/runs.cancel",
        };
    }
};

/// §10. The numeric code is normative; `name` is the `error.data.code` spelling.
pub const ErrorCode = enum(i32) {
    unauthorized = -32001,
    subscription_required = -32002,
    skill_not_found = -32003,
    manifest_changed = -32004,
    run_not_found = -32005,
    run_state_invalid = -32006,
    budget_exceeded = -32007,
    policy_violation = -32008,
    rate_limited = -32009,
    unsupported_version = -32010,
    upstream_unavailable = -32011,

    pub fn fromCode(code: i64) ?ErrorCode {
        inline for (@typeInfo(ErrorCode).@"enum".fields) |field| {
            if (code == field.value) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn name(self: ErrorCode) []const u8 {
        return @tagName(self);
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidJson,
    /// A required field is missing or has the wrong JSON type.
    InvalidShape,
    /// A float appeared where the protocol digests integers only (§4.5).
    FloatInDigestedObject,
    MessageTooLarge,
};

// ── Manifest and Entry (§5, §3.2) ─────────────────────────────────────────

pub const CredentialDecl = struct {
    ref: []const u8,
    purpose: []const u8 = "",
    kind: []const u8 = "",
};

pub const Manifest = struct {
    schema: []const u8,
    skill_id: []const u8,
    version: []const u8,
    name: []const u8,
    display_name: []const u8 = "",
    description: []const u8,
    when_to_use: []const u8 = "",
    argument_hint: []const u8 = "",
    arguments: []const []const u8 = &.{},
    creator_id: []const u8 = "",
    creator_display_name: []const u8 = "",
    tools_allow: []const []const u8,
    tools_deny: []const []const u8 = &.{},
    confirmation_required_for: []const []const u8 = &.{},
    egress_classes: []const []const u8 = &.{},
    egress_max_result_bytes: u64 = DEFAULT_MAX_RESULT_BYTES,
    egress_retention: []const u8 = "run",
    /// §5, §8.5: what the gateway does when the brain's output quotes the
    /// Skill's **body** (its instructions) — `redact` (default), `fail` or
    /// `off`. `egress.disclosure` as a string sets both policies; as an
    /// object `{"body", "references"}` sets each.
    egress_disclosure: []const u8 = "redact",
    /// The same for the `sealed/` **reference** files. A documentation Skill
    /// whose purpose is to restate its references sets this to `off`; a
    /// Skill whose references are its private rules keeps `redact`.
    egress_disclosure_references: []const u8 = "redact",
    credentials: []const CredentialDecl = &.{},
    execution_classes: []const []const u8 = &.{},
    pricing_model: []const u8 = "",
    pricing_estimate_micros: i64 = 0,
    pricing_currency: []const u8 = "",
    requires_protocol: []const u8 = "",
    requires_client_min_version: []const u8 = "",

    /// Whether every execution class is one this client runs (§7: only
    /// `server` in revision 2026-10-15).
    pub fn executionSupported(self: *const Manifest) bool {
        if (self.execution_classes.len == 0) return true;
        for (self.execution_classes) |class| {
            if (!std.mem.eql(u8, class, "server")) return false;
        }
        return true;
    }
};

/// A public file of the Skill package (§5 `assets`): installed into the pin
/// directory so the Skill's scripts and data exist where the brain believes
/// they do. Anything under `sealed/` and the SKILL.md body are never listed.
pub const Asset = struct {
    /// Package-relative path with `/` separators.
    path: []const u8,
    /// `sha256:<hex>` of the file's bytes.
    sha256: []const u8,
    bytes: u64,
};

pub const Entry = struct {
    skill_id: []const u8,
    version: []const u8,
    manifest: Manifest,
    /// Canonical JSON of `manifest` (§4.5), as digested.
    manifest_canonical: []const u8,
    manifest_digest: []const u8,
    manifest_sig: []const u8 = "",
    subscription_state: []const u8 = "",
    assets: []const Asset = &.{},
};

pub const ParsedEntry = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *ParsedEntry) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParsedEntries = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    next_cursor: ?[]const u8,

    pub fn deinit(self: *ParsedEntries) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parse one Entry object (the result of `skills.get`, or one element of
/// `skills.list`). The manifest digest is recomputed from the canonical form
/// and compared with the gateway's `manifest_digest`; a mismatch is
/// `InvalidShape`, since a client must never pin a digest it cannot verify.
pub fn parseEntry(allocator: std.mem.Allocator, json: []const u8) ParseError!ParsedEntry {
    if (json.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    var result: ParsedEntry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .entry = undefined };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    result.entry = try entryFromValue(arena, parsed);
    return result;
}

pub fn parseEntries(allocator: std.mem.Allocator, result_json: []const u8) ParseError!ParsedEntries {
    if (result_json.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    var result: ParsedEntries = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .entries = &.{},
        .next_cursor = null,
    };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (parsed != .object) return error.InvalidShape;
    const skills = parsed.object.get("skills") orelse return error.InvalidShape;
    if (skills != .array) return error.InvalidShape;
    const entries = try arena.alloc(Entry, skills.array.items.len);
    for (skills.array.items, entries) |item, *slot| slot.* = try entryFromValue(arena, item);
    result.entries = entries;
    result.next_cursor = try optionalString(parsed, "next_cursor");
    return result;
}

pub fn entryFromValue(arena: std.mem.Allocator, value: std.json.Value) ParseError!Entry {
    if (value != .object) return error.InvalidShape;
    const manifest_value = value.object.get("manifest") orelse return error.InvalidShape;
    const canonical = try canonicalize(arena, manifest_value);
    const digest = try digestHex(arena, canonical);
    const claimed = try requiredString(value, "manifest_digest");
    if (!std.mem.eql(u8, claimed, digest)) return error.InvalidShape;
    const manifest = try manifestFromValue(arena, manifest_value);
    const skill_id = try requiredString(value, "skill_id");
    if (!std.mem.eql(u8, skill_id, manifest.skill_id)) return error.InvalidShape;
    var subscription_state: []const u8 = "";
    if (value.object.get("subscription")) |subscription| {
        if (subscription == .object) subscription_state = try optionalString(subscription, "state") orelse "";
    }
    var assets: []const Asset = &.{};
    if (value.object.get("assets")) |list| {
        if (list != .array) return error.InvalidShape;
        const out = try arena.alloc(Asset, list.array.items.len);
        for (list.array.items, out) |item, *slot| {
            if (item != .object) return error.InvalidShape;
            const path = try requiredString(item, "path");
            if (!validAssetPath(path)) return error.InvalidShape;
            const bytes = try requiredInteger(item, "bytes");
            if (bytes < 0) return error.InvalidShape;
            slot.* = .{ .path = path, .sha256 = try requiredString(item, "sha256"), .bytes = @intCast(bytes) };
        }
        assets = out;
    }
    return .{
        .skill_id = skill_id,
        .version = try optionalString(value, "version") orelse manifest.version,
        .manifest = manifest,
        .manifest_canonical = canonical,
        .manifest_digest = digest,
        .manifest_sig = try optionalString(value, "manifest_sig") orelse "",
        .subscription_state = subscription_state,
        .assets = assets,
    };
}

/// A package-relative path a client will write under its pin directory:
/// `/`-separated, no empty, `.` or `..` segments, no drive or root, and never
/// the pin's own files or the sealed set.
pub fn validAssetPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 512) return false;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, ':') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    if (std.mem.eql(u8, path, "SKILL.md") or std.mem.eql(u8, path, "sealed.json")) return false;
    if (std.mem.startsWith(u8, path, "sealed/")) return false;
    return true;
}

pub fn manifestFromValue(arena: std.mem.Allocator, value: std.json.Value) ParseError!Manifest {
    if (value != .object) return error.InvalidShape;
    const schema = try requiredString(value, "schema");
    if (!std.mem.eql(u8, schema, MANIFEST_SCHEMA)) return error.InvalidShape;
    var manifest: Manifest = .{
        .schema = schema,
        .skill_id = try requiredString(value, "skill_id"),
        .version = try requiredString(value, "version"),
        .name = try requiredString(value, "name"),
        .description = try requiredString(value, "description"),
        .tools_allow = &.{},
    };
    if (manifest.description.len == 0 or manifest.name.len == 0) return error.InvalidShape;
    manifest.display_name = try optionalString(value, "display_name") orelse "";
    manifest.when_to_use = try optionalString(value, "when_to_use") orelse "";
    manifest.argument_hint = try optionalString(value, "argument_hint") orelse "";
    manifest.arguments = try optionalStringList(arena, value, "arguments");
    if (value.object.get("creator")) |creator| {
        if (creator != .object) return error.InvalidShape;
        manifest.creator_id = try optionalString(creator, "id") orelse "";
        manifest.creator_display_name = try optionalString(creator, "display_name") orelse "";
    }
    const tools = value.object.get("tools") orelse return error.InvalidShape;
    if (tools != .object) return error.InvalidShape;
    manifest.tools_allow = try optionalStringList(arena, tools, "allow");
    if (manifest.tools_allow.len == 0) return error.InvalidShape;
    manifest.tools_deny = try optionalStringList(arena, tools, "deny");
    if (value.object.get("confirmation")) |confirmation| {
        if (confirmation != .object) return error.InvalidShape;
        manifest.confirmation_required_for = try optionalStringList(arena, confirmation, "required_for");
    }
    if (value.object.get("egress")) |egress| {
        if (egress != .object) return error.InvalidShape;
        manifest.egress_classes = try optionalStringList(arena, egress, "classes");
        if (try optionalInteger(egress, "max_result_bytes")) |bytes| {
            if (bytes <= 0) return error.InvalidShape;
            manifest.egress_max_result_bytes = @intCast(bytes);
        }
        manifest.egress_retention = try optionalString(egress, "retention") orelse "run";
        if (egress.object.get("disclosure")) |policy| switch (policy) {
            .string => |both| {
                manifest.egress_disclosure = both;
                manifest.egress_disclosure_references = both;
            },
            .object => {
                manifest.egress_disclosure = try optionalString(policy, "body") orelse "redact";
                manifest.egress_disclosure_references = try optionalString(policy, "references") orelse "redact";
            },
            .null => {},
            else => return error.InvalidShape,
        };
        if (!validDisclosurePolicy(manifest.egress_disclosure) or !validDisclosurePolicy(manifest.egress_disclosure_references))
            return error.InvalidShape;
    }
    if (value.object.get("credentials")) |credentials| {
        if (credentials != .array) return error.InvalidShape;
        const list = try arena.alloc(CredentialDecl, credentials.array.items.len);
        for (credentials.array.items, list) |item, *slot| {
            if (item != .object) return error.InvalidShape;
            slot.* = .{
                .ref = try requiredString(item, "ref"),
                .purpose = try optionalString(item, "purpose") orelse "",
                .kind = try optionalString(item, "kind") orelse "",
            };
        }
        manifest.credentials = list;
    }
    if (value.object.get("execution")) |execution| {
        if (execution != .object) return error.InvalidShape;
        manifest.execution_classes = try optionalStringList(arena, execution, "classes");
    }
    if (value.object.get("pricing")) |pricing| {
        if (pricing != .object) return error.InvalidShape;
        manifest.pricing_model = try optionalString(pricing, "model") orelse "";
        manifest.pricing_estimate_micros = try optionalInteger(pricing, "estimate_micros_per_run") orelse 0;
        manifest.pricing_currency = try optionalString(pricing, "currency") orelse "";
    }
    if (value.object.get("requires")) |requires| {
        if (requires != .object) return error.InvalidShape;
        manifest.requires_protocol = try optionalString(requires, "protocol") orelse "";
        manifest.requires_client_min_version = try optionalString(requires, "client_min_version") orelse "";
    }
    return manifest;
}

// ── Step (§4.3) ───────────────────────────────────────────────────────────

pub const StepKind = enum { tool_calls, final, input_required, failed };

pub const Call = struct {
    id: []const u8,
    name: []const u8,
    /// The `input` object re-serialized as JSON (the loop takes raw JSON).
    input_json: []const u8,
    confirm: bool = false,
    deadline_ms: ?u64 = null,
    credentials: []const []const u8 = &.{},
    result_limit_bytes: ?u64 = null,
};

pub const Usage = struct {
    model: []const u8 = "",
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cost_micros: i64 = 0,
    currency: []const u8 = "",
};

pub const Cumulative = struct {
    steps: u64 = 0,
    cost_micros: i64 = 0,
    currency: []const u8 = "",
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const Charge = struct {
    run_id: []const u8,
    cost_micros: i64,
    currency: []const u8,
    steps: u64,
    issued_at: []const u8 = "",
    digest: []const u8 = "",
    sig: []const u8 = "",
};

pub const Question = struct {
    id: []const u8,
    message: []const u8,
    /// Raw JSON of `schema`, or "" when absent.
    schema_json: []const u8 = "",
    /// Raw JSON of `tool_input`: the brain's `AskUserQuestion` call as the
    /// client's own tool takes it, so the client can run that tool verbatim.
    /// "" for a gateway that only has a message.
    tool_input_json: []const u8 = "",
};

pub const Step = struct {
    run_id: []const u8,
    seq: u64,
    run_state: []const u8,
    kind: StepKind,
    calls: []const Call = &.{},
    text: []const u8 = "",
    usage: Usage = .{},
    cumulative: Cumulative = .{},
    issuer_skill_host: []const u8 = "",
    issuer_inference_gateway: []const u8 = "",
    prev_digest: []const u8 = "",
    digest: []const u8 = "",
    sig: []const u8 = "",
    /// §8.3: the digest of the `results` array this Step was derived from
    /// (canonical JSON, §4.5); "" on a run's first Step. A client compares
    /// it with the digest of what it sent and ends the run when the Step
    /// answering its `runs.continue` carries anything else, including nothing.
    results_digest: []const u8 = "",
    /// §8.5: how many passages of the Skill's sealed material the gateway
    /// replaced with its marker in this Step's text, inputs or question.
    disclosure_redactions: u64 = 0,
    /// `failed` only.
    reason: []const u8 = "",
    message: []const u8 = "",
    /// `input_required` only.
    question: ?Question = null,
    /// `final` and `failed`.
    charge: ?Charge = null,
};

pub const ParsedStep = struct {
    arena: std.heap.ArenaAllocator,
    step: Step,

    pub fn deinit(self: *ParsedStep) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parse a Step from the JSON-RPC `result` object. `digest` is verified
/// against the canonical form without `digest`, `sig` and `run_state` (§4.5);
/// a Step whose digest does not match is `InvalidShape`: the hash chain is
/// the client's evidence and must not be recorded unverified.
pub fn parseStep(allocator: std.mem.Allocator, result_json: []const u8) ParseError!ParsedStep {
    if (result_json.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    var result: ParsedStep = .{ .arena = std.heap.ArenaAllocator.init(allocator), .step = undefined };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    result.step = try stepFromValue(arena, parsed);
    return result;
}

pub fn stepFromValue(arena: std.mem.Allocator, value: std.json.Value) ParseError!Step {
    if (value != .object) return error.InvalidShape;
    const kind_text = try requiredString(value, "kind");
    const kind: StepKind = if (std.mem.eql(u8, kind_text, "tool_calls"))
        .tool_calls
    else if (std.mem.eql(u8, kind_text, "final"))
        .final
    else if (std.mem.eql(u8, kind_text, "input_required"))
        .input_required
    else if (std.mem.eql(u8, kind_text, "failed"))
        .failed
    else
        return error.InvalidShape;
    const seq = try requiredInteger(value, "seq");
    if (seq <= 0) return error.InvalidShape;
    var step: Step = .{
        .run_id = try requiredString(value, "run_id"),
        .seq = @intCast(seq),
        .run_state = try optionalString(value, "run_state") orelse "",
        .kind = kind,
    };
    step.text = try optionalString(value, "text") orelse "";
    step.reason = try optionalString(value, "reason") orelse "";
    step.message = try optionalString(value, "message") orelse "";
    step.prev_digest = try optionalString(value, "prev_digest") orelse "";
    step.sig = try optionalString(value, "sig") orelse "";
    step.results_digest = try optionalString(value, "results_digest") orelse "";
    if (value.object.get("disclosure")) |disclosure| {
        if (disclosure != .object) return error.InvalidShape;
        const redactions = try optionalInteger(disclosure, "redactions") orelse 0;
        if (redactions < 0) return error.InvalidShape;
        step.disclosure_redactions = @intCast(redactions);
    }
    if (value.object.get("issuer")) |issuer| {
        if (issuer != .object) return error.InvalidShape;
        step.issuer_skill_host = try optionalString(issuer, "skill_host") orelse "";
        step.issuer_inference_gateway = try optionalString(issuer, "inference_gateway") orelse "";
    }
    if (value.object.get("usage")) |usage| step.usage = try usageFromValue(usage);
    if (value.object.get("cumulative")) |cumulative| step.cumulative = try cumulativeFromValue(cumulative);
    if (value.object.get("calls")) |calls| {
        if (calls != .array) return error.InvalidShape;
        const list = try arena.alloc(Call, calls.array.items.len);
        for (calls.array.items, list) |item, *slot| slot.* = try callFromValue(arena, item);
        step.calls = list;
    }
    if (value.object.get("question")) |question| {
        if (question != .object) return error.InvalidShape;
        step.question = .{
            .id = try requiredString(question, "id"),
            .message = try requiredString(question, "message"),
            .schema_json = if (question.object.get("schema")) |schema| try canonicalize(arena, schema) else "",
            .tool_input_json = if (question.object.get("tool_input")) |input| try serializeValue(arena, input) else "",
        };
    }
    if (value.object.get("charge")) |charge| {
        if (charge != .object) return error.InvalidShape;
        const cost = try requiredInteger(charge, "cost_micros");
        const steps = try requiredInteger(charge, "steps");
        if (steps < 0) return error.InvalidShape;
        step.charge = .{
            .run_id = try requiredString(charge, "run_id"),
            .cost_micros = cost,
            .currency = try requiredString(charge, "currency"),
            .steps = @intCast(steps),
            .issued_at = try optionalString(charge, "issued_at") orelse "",
            .digest = try optionalString(charge, "digest") orelse "",
            .sig = try optionalString(charge, "sig") orelse "",
        };
    }
    switch (kind) {
        .tool_calls => if (step.calls.len == 0) return error.InvalidShape,
        .input_required => if (step.question == null) return error.InvalidShape,
        .failed => if (step.reason.len == 0) return error.InvalidShape,
        .final => {},
    }
    // Verify the hash chain link: digest over the Step without digest/sig/run_state.
    const claimed = try requiredString(value, "digest");
    const expected = try stepDigest(arena, value);
    if (!std.mem.eql(u8, claimed, expected)) return error.InvalidShape;
    step.digest = claimed;
    return step;
}

/// §4.5: the digest of a Step is over its canonical JSON with `digest`,
/// `sig` and `run_state` removed.
pub fn stepDigest(allocator: std.mem.Allocator, step_value: std.json.Value) ParseError![]const u8 {
    if (step_value != .object) return error.InvalidShape;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeCanonicalObject(allocator, &out.writer, step_value.object, &.{ "digest", "sig", "run_state" }) catch |err| switch (err) {
        error.FloatInDigestedObject => return error.FloatInDigestedObject,
        else => return error.OutOfMemory,
    };
    return digestHex(allocator, out.written());
}

fn callFromValue(arena: std.mem.Allocator, value: std.json.Value) ParseError!Call {
    if (value != .object) return error.InvalidShape;
    const input = value.object.get("input") orelse return error.InvalidShape;
    if (input != .object) return error.InvalidShape;
    var call: Call = .{
        .id = try requiredString(value, "id"),
        .name = try requiredString(value, "name"),
        .input_json = try serializeValue(arena, input),
    };
    if (call.id.len == 0 or call.name.len == 0) return error.InvalidShape;
    if (value.object.get("confirm")) |confirm| {
        if (confirm != .bool) return error.InvalidShape;
        call.confirm = confirm.bool;
    }
    if (try optionalInteger(value, "deadline_ms")) |deadline| {
        if (deadline < 0) return error.InvalidShape;
        call.deadline_ms = @intCast(deadline);
    }
    call.credentials = try optionalStringList(arena, value, "credentials");
    if (try optionalInteger(value, "result_limit_bytes")) |limit| {
        if (limit <= 0) return error.InvalidShape;
        call.result_limit_bytes = @intCast(limit);
    }
    return call;
}

fn usageFromValue(value: std.json.Value) ParseError!Usage {
    if (value != .object) return error.InvalidShape;
    return .{
        .model = try optionalString(value, "model") orelse "",
        .input_tokens = try optionalUnsigned(value, "input_tokens"),
        .output_tokens = try optionalUnsigned(value, "output_tokens"),
        .cache_read_input_tokens = try optionalUnsigned(value, "cache_read_input_tokens"),
        .cache_creation_input_tokens = try optionalUnsigned(value, "cache_creation_input_tokens"),
        .cost_micros = try optionalInteger(value, "cost_micros") orelse 0,
        .currency = try optionalString(value, "currency") orelse "",
    };
}

fn cumulativeFromValue(value: std.json.Value) ParseError!Cumulative {
    if (value != .object) return error.InvalidShape;
    return .{
        .steps = try optionalUnsigned(value, "steps"),
        .cost_micros = try optionalInteger(value, "cost_micros") orelse 0,
        .currency = try optionalString(value, "currency") orelse "",
        .input_tokens = try optionalUnsigned(value, "input_tokens"),
        .output_tokens = try optionalUnsigned(value, "output_tokens"),
    };
}

// ── Request parameters (§3.4–§3.6) ────────────────────────────────────────

pub const StartParams = struct {
    skill_id: []const u8,
    manifest_digest: []const u8,
    prompt: []const u8,
    arguments: []const []const u8 = &.{},
    /// A JSON array of ToolDefinition objects, already serialized.
    tools_json: []const u8 = "[]",
    max_cost_micros: i64,
    currency: []const u8 = "USD",
    max_steps: u64,
    client_name: []const u8,
    client_version: []const u8,
    client_platform: []const u8,
    run_ref: []const u8 = "",
    locale: []const u8 = "",
    confirmation: []const u8 = "client",
    /// The fork's system prompt, exactly as the client's own fork would send
    /// it (§9.1 "Mirror"). "" omits the field.
    system: []const u8 = "",
    /// The directory the Skill's public assets were installed to on the
    /// client; the brain is told it as the Skill's base directory.
    base_dir: []const u8 = "",
    /// The client's provider route (§8.1); kind "" omits the block.
    provider_kind: []const u8 = "",
    provider_base_url: []const u8 = "",
    provider_openai_protocol: []const u8 = "",
    /// `{"scheme":"bearer"}`, `{"scheme":"api_key_header","header":"x-api-key"}`
    /// or `{"scheme":"custom_header","header":"…","value_prefix":"…"}`; "" for
    /// the kind's default.
    provider_auth_json: []const u8 = "",
    /// Provider-side server tools (web search …) the client's request would
    /// carry, in the client's dialect; "[]" or "" for none.
    provider_tools_json: []const u8 = "",
    /// Request parameters of the client's fork: model "" omits the block.
    model: []const u8 = "",
    max_tokens: u32 = 0,
    reasoning_effort: []const u8 = "",
};

pub fn writeStartParams(w: *std.Io.Writer, p: StartParams) !void {
    try w.writeAll("{\"skill_id\":");
    try writeString(w, p.skill_id);
    try w.writeAll(",\"manifest_digest\":");
    try writeString(w, p.manifest_digest);
    try w.writeAll(",\"prompt\":");
    try writeString(w, p.prompt);
    try w.writeAll(",\"arguments\":");
    try writeStringArray(w, p.arguments);
    try w.writeAll(",\"tools\":");
    try w.writeAll(if (p.tools_json.len == 0) "[]" else p.tools_json);
    try w.print(",\"budget\":{{\"max_cost_micros\":{d},\"currency\":", .{p.max_cost_micros});
    try writeString(w, p.currency);
    try w.print(",\"max_steps\":{d}}},\"client\":{{\"name\":", .{p.max_steps});
    try writeString(w, p.client_name);
    try w.writeAll(",\"version\":");
    try writeString(w, p.client_version);
    try w.writeAll(",\"platform\":");
    try writeString(w, p.client_platform);
    try w.writeAll(",\"run_ref\":");
    try writeString(w, p.run_ref);
    try w.writeAll("}");
    if (p.locale.len != 0) {
        try w.writeAll(",\"locale\":");
        try writeString(w, p.locale);
    }
    try w.writeAll(",\"confirmation\":");
    try writeString(w, p.confirmation);
    if (p.system.len != 0) {
        try w.writeAll(",\"system\":");
        try writeString(w, p.system);
    }
    if (p.base_dir.len != 0) {
        try w.writeAll(",\"base_dir\":");
        try writeString(w, p.base_dir);
    }
    if (p.provider_kind.len != 0) {
        try w.writeAll(",\"provider\":{\"kind\":");
        try writeString(w, p.provider_kind);
        try w.writeAll(",\"base_url\":");
        try writeString(w, p.provider_base_url);
        if (p.provider_openai_protocol.len != 0) {
            try w.writeAll(",\"openai_protocol\":");
            try writeString(w, p.provider_openai_protocol);
        }
        if (p.provider_auth_json.len != 0) {
            try w.writeAll(",\"auth\":");
            try w.writeAll(p.provider_auth_json);
        }
        try w.writeByte('}');
    }
    if (p.provider_tools_json.len != 0 and !std.mem.eql(u8, p.provider_tools_json, "[]")) {
        try w.writeAll(",\"provider_tools\":");
        try w.writeAll(p.provider_tools_json);
    }
    if (p.model.len != 0) {
        try w.writeAll(",\"request\":{\"model\":");
        try writeString(w, p.model);
        try w.print(",\"max_tokens\":{d}", .{p.max_tokens});
        if (p.reasoning_effort.len != 0) {
            try w.writeAll(",\"reasoning_effort\":");
            try writeString(w, p.reasoning_effort);
        }
        try w.writeByte('}');
    }
    try w.writeAll("}");
}

pub const Refusal = enum {
    policy_violation,
    permission_denied,
    tool_unavailable,
    budget,
    aborted,
};

pub const ResultEntry = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
    truncated: bool = false,
    refusal: ?Refusal = null,
    redactions: []const []const u8 = &.{},
};

pub fn writeContinueParams(
    w: *std.Io.Writer,
    run_id: []const u8,
    run_state: []const u8,
    seq: u64,
    results: []const ResultEntry,
) !void {
    try w.writeAll("{\"run_id\":");
    try writeString(w, run_id);
    try w.writeAll(",\"run_state\":");
    try writeString(w, run_state);
    try w.print(",\"seq\":{d},\"results\":", .{seq});
    try writeResultsArray(w, results);
    try w.writeByte('}');
}

/// The `results` array of `runs.continue` (§3.5), the one object both sides
/// digest (§8.3).
pub fn writeResultsArray(w: *std.Io.Writer, results: []const ResultEntry) !void {
    try w.writeByte('[');
    for (results, 0..) |result, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"tool_use_id\":");
        try writeString(w, result.tool_use_id);
        try w.writeAll(",\"content\":");
        try writeString(w, result.content);
        try w.print(",\"is_error\":{},\"truncated\":{}", .{ result.is_error, result.truncated });
        if (result.refusal) |refusal| {
            try w.writeAll(",\"refusal\":");
            try writeString(w, @tagName(refusal));
        }
        try w.writeAll(",\"redactions\":");
        try writeStringArray(w, result.redactions);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// §8.3: `sha256:` over the canonical JSON (§4.5) of a `results` array. The
/// client computes it from the entries it is about to send; the gateway from
/// the array it parsed; the two agree by construction (same wire form, same
/// canonicalization), so a Step's `results_digest` can be checked.
pub fn resultsDigest(allocator: std.mem.Allocator, results: []const ResultEntry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeResultsArray(&out.writer, results);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    return resultsDigestOfValue(allocator, parsed.value);
}

/// The gateway's side of `resultsDigest`: over the parsed `results` value.
pub fn resultsDigestOfValue(allocator: std.mem.Allocator, results: std.json.Value) ![]const u8 {
    const canonical = try canonicalize(allocator, results);
    defer allocator.free(canonical);
    return digestHex(allocator, canonical);
}

/// Whether the manifest's tool rules admit `tool_name`: a `deny` rule that
/// names the whole tool wins, then an `allow` rule that covers it. The same
/// decision on both sides of the protocol — the client's policy frame
/// (§6.1) and the gateway, which serves a sealed Read/Glob/Grep itself only
/// for a tool the client would have admitted.
pub fn manifestAllowsTool(manifest: *const Manifest, tool_name: []const u8) bool {
    for (manifest.tools_deny) |raw| if (ruleNamesWholeTool(raw, tool_name)) return false;
    for (manifest.tools_allow) |raw| if (ruleCoversTool(raw, tool_name)) return true;
    return false;
}

/// `Tool`, `Tool(pattern)`, or `prefix*` (MCP wildcard) covers `tool_name`.
pub fn ruleCoversTool(raw: []const u8, tool_name: []const u8) bool {
    const paren = std.mem.indexOfScalar(u8, raw, '(') orelse raw.len;
    const head = std.mem.trim(u8, raw[0..paren], " ");
    if (head.len == 0) return false;
    if (head[head.len - 1] == '*') return std.mem.startsWith(u8, tool_name, head[0 .. head.len - 1]);
    return std.mem.eql(u8, head, tool_name);
}

/// A rule without an argument pattern that covers the tool.
pub fn ruleNamesWholeTool(raw: []const u8, tool_name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, raw, '(') != null) return false;
    return ruleCoversTool(raw, tool_name);
}

/// §5: the class under which the fork's codebase context — the CLAUDE.md
/// chain and git status the client's own forks carry in their system
/// prompt — leaves the machine. A sealed fork carries that context only when
/// the manifest declares this class; otherwise it starts without it.
pub const EGRESS_CODEBASE_CONTEXT_CLASS = "repository_structure";

/// §5: the egress class a tool's results fall under, for the tools whose
/// results the client can classify before running them. Null: the client
/// cannot tell (a subagent's summary, an MCP tool, a write's confirmation)
/// and does not refuse on class grounds.
pub fn egressClassOfTool(tool_name: []const u8) ?[]const u8 {
    const table = [_]struct { name: []const u8, class: []const u8 }{
        .{ .name = "Read", .class = "file_contents" },
        .{ .name = "Grep", .class = "file_contents" },
        .{ .name = "Edit", .class = "file_contents" },
        .{ .name = "NotebookEdit", .class = "file_contents" },
        .{ .name = "Glob", .class = EGRESS_CODEBASE_CONTEXT_CLASS },
        .{ .name = "Bash", .class = "command_output" },
        .{ .name = "BashOutput", .class = "command_output" },
        .{ .name = "WebFetch", .class = "page_snapshot" },
        .{ .name = "WebSearch", .class = "page_snapshot" },
    };
    for (table) |row| if (std.mem.eql(u8, row.name, tool_name)) return row.class;
    return null;
}

/// Whether the manifest declares `class` under `egress.classes`.
pub fn manifestDeclaresEgress(manifest: *const Manifest, class: []const u8) bool {
    for (manifest.egress_classes) |declared| if (std.mem.eql(u8, declared, class)) return true;
    return false;
}

pub const CancelReason = enum { user_abort, budget, policy, client_error };

pub fn writeCancelParams(w: *std.Io.Writer, run_id: []const u8, run_state: []const u8, reason: CancelReason) !void {
    try w.writeAll("{\"run_id\":");
    try writeString(w, run_id);
    try w.writeAll(",\"run_state\":");
    try writeString(w, run_state);
    try w.writeAll(",\"reason\":");
    try writeString(w, @tagName(reason));
    try w.writeByte('}');
}

pub fn writeSkillsGetParams(w: *std.Io.Writer, skill_id: []const u8) !void {
    try w.writeAll("{\"skill_id\":");
    try writeString(w, skill_id);
    try w.writeByte('}');
}

pub fn writeSkillsAssetParams(w: *std.Io.Writer, skill_id: []const u8, path: []const u8) !void {
    try w.writeAll("{\"skill_id\":");
    try writeString(w, skill_id);
    try w.writeAll(",\"path\":");
    try writeString(w, path);
    try w.writeByte('}');
}

/// The result of `skills.asset`: `{"path","sha256","content_base64"}`.
pub const ParsedAsset = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    sha256: []const u8,
    /// Decoded bytes, verified against `sha256`.
    content: []const u8,

    pub fn deinit(self: *ParsedAsset) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseAsset(allocator: std.mem.Allocator, result_json: []const u8) ParseError!ParsedAsset {
    if (result_json.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    var result: ParsedAsset = .{ .arena = std.heap.ArenaAllocator.init(allocator), .path = "", .sha256 = "", .content = "" };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const path = try requiredString(parsed, "path");
    if (!validAssetPath(path)) return error.InvalidShape;
    const encoded = try requiredString(parsed, "content_base64");
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidShape;
    if (size > MAX_ASSET_BYTES) return error.MessageTooLarge;
    const content = try arena.alloc(u8, size);
    decoder.decode(content, encoded) catch return error.InvalidShape;
    const claimed = try requiredString(parsed, "sha256");
    const actual = try digestHex(arena, content);
    if (!std.mem.eql(u8, claimed, actual)) return error.InvalidShape;
    result.path = path;
    result.sha256 = claimed;
    result.content = content;
    return result;
}

// ── JSON-RPC envelope ─────────────────────────────────────────────────────

pub fn writeRequest(w: *std.Io.Writer, id: u64, method: Method, params_json: []const u8) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try writeString(w, method.wire());
    try w.writeAll(",\"params\":");
    try w.writeAll(if (params_json.len == 0) "{}" else params_json);
    try w.writeByte('}');
}

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    /// `error.data.code` when it names a §10 error, else null.
    known: ?ErrorCode,
    /// Raw JSON of `error.data`, "" when absent.
    data_json: []const u8 = "",
};

pub const RpcResponse = union(enum) {
    /// Raw JSON of `result`.
    result: []const u8,
    err: RpcError,
};

pub const ParsedResponse = struct {
    arena: std.heap.ArenaAllocator,
    response: RpcResponse,

    pub fn deinit(self: *ParsedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ResponseError = ParseError || error{
    /// The message is a valid JSON-RPC message for another id (a
    /// notification, or a late answer): skip it and read on.
    NotOurResponse,
};

/// Parse one JSON-RPC message and match it to `expected_id`.
pub fn parseResponse(allocator: std.mem.Allocator, json: []const u8, expected_id: u64) ResponseError!ParsedResponse {
    if (json.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    var result: ParsedResponse = .{ .arena = std.heap.ArenaAllocator.init(allocator), .response = undefined };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (parsed != .object) return error.InvalidShape;
    const id = parsed.object.get("id") orelse return error.NotOurResponse;
    if (id != .integer or id.integer != @as(i64, @intCast(expected_id))) return error.NotOurResponse;
    if (parsed.object.get("error")) |err_value| {
        if (err_value != .object) return error.InvalidShape;
        const code = try requiredInteger(err_value, "code");
        var known: ?ErrorCode = ErrorCode.fromCode(code);
        var data_json: []const u8 = "";
        if (err_value.object.get("data")) |data| {
            data_json = try serializeValue(arena, data);
            if (data == .object) {
                if (try optionalString(data, "code")) |name| {
                    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| {
                        if (std.mem.eql(u8, name, field.name)) known = @enumFromInt(field.value);
                    }
                }
            }
        }
        result.response = .{ .err = .{
            .code = code,
            .message = try optionalString(err_value, "message") orelse "",
            .known = known,
            .data_json = data_json,
        } };
        return result;
    }
    const value = parsed.object.get("result") orelse return error.InvalidShape;
    result.response = .{ .result = try serializeValue(arena, value) };
    return result;
}

// ── Canonical JSON and digests (§4.5) ─────────────────────────────────────

/// Canonical JSON: keys sorted by code point, no whitespace, integers only.
pub fn canonicalize(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeCanonical(allocator, &out.writer, value) catch |err| switch (err) {
        error.FloatInDigestedObject => return error.FloatInDigestedObject,
        else => return error.OutOfMemory,
    };
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// `sha256:<64 lower hex>` of `bytes`.
pub fn digestHex(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

const CanonicalError = error{ FloatInDigestedObject, OutOfMemory, WriteFailed };

fn writeCanonical(allocator: std.mem.Allocator, w: *std.Io.Writer, value: std.json.Value) CanonicalError!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => return error.FloatInDigestedObject,
        .number_string => |s| {
            // A number the parser kept as text: integers only.
            _ = std.fmt.parseInt(i64, s, 10) catch return error.FloatInDigestedObject;
            try w.writeAll(s);
        },
        .string => |s| try writeString(w, s),
        .array => |items| {
            try w.writeByte('[');
            for (items.items, 0..) |item, index| {
                if (index != 0) try w.writeByte(',');
                try writeCanonical(allocator, w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| try writeCanonicalObject(allocator, w, object, &.{}),
    }
}

fn writeCanonicalObject(allocator: std.mem.Allocator, w: *std.Io.Writer, object: std.json.ObjectMap, skip: []const []const u8) CanonicalError!void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var skipped = false;
        for (skip) |name| if (std.mem.eql(u8, name, entry.key_ptr.*)) {
            skipped = true;
        };
        if (!skipped) try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, keyLessThan);
    try w.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try w.writeByte(',');
        try writeString(w, key);
        try w.writeByte(':');
        try writeCanonical(allocator, w, object.get(key).?);
    }
    try w.writeByte('}');
}

fn keyLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Plain (non-canonical) serialization of a parsed value, for raw passthrough
/// such as `call.input` and `error.data`.
pub fn serializeValue(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ── JSON helpers ──────────────────────────────────────────────────────────

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn writeStringArray(w: *std.Io.Writer, values: []const []const u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeByte(',');
        try writeString(w, value);
    }
    try w.writeByte(']');
}

fn validDisclosurePolicy(text: []const u8) bool {
    return std.mem.eql(u8, text, "redact") or std.mem.eql(u8, text, "fail") or std.mem.eql(u8, text, "off");
}

fn requiredString(value: std.json.Value, key: []const u8) ParseError![]const u8 {
    return try optionalString(value, key) orelse error.InvalidShape;
}

fn optionalString(value: std.json.Value, key: []const u8) ParseError!?[]const u8 {
    if (value != .object) return error.InvalidShape;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        .null => null,
        else => error.InvalidShape,
    };
}

fn requiredInteger(value: std.json.Value, key: []const u8) ParseError!i64 {
    return try optionalInteger(value, key) orelse error.InvalidShape;
}

fn optionalInteger(value: std.json.Value, key: []const u8) ParseError!?i64 {
    if (value != .object) return error.InvalidShape;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .integer => |i| i,
        .null => null,
        else => error.InvalidShape,
    };
}

fn optionalUnsigned(value: std.json.Value, key: []const u8) ParseError!u64 {
    const raw = try optionalInteger(value, key) orelse return 0;
    if (raw < 0) return error.InvalidShape;
    return @intCast(raw);
}

fn optionalStringList(arena: std.mem.Allocator, value: std.json.Value, key: []const u8) ParseError![]const []const u8 {
    if (value != .object) return error.InvalidShape;
    const field = value.object.get(key) orelse return &.{};
    switch (field) {
        .null => return &.{},
        .array => |items| {
            const list = try arena.alloc([]const u8, items.items.len);
            for (items.items, list) |item, *slot| {
                if (item != .string) return error.InvalidShape;
                slot.* = item.string;
            }
            return list;
        },
        else => return error.InvalidShape,
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

pub const TEST_MANIFEST_JSON =
    \\{"schema":"metask.sealed-skill.manifest/v1","skill_id":"ssk_test","version":"1.0.0",
    \\"name":"erp-post","description":"Posts invoices. Use when asked to post an invoice.",
    \\"when_to_use":"invoice posting","argument_hint":"[folder]","arguments":["folder"],
    \\"creator":{"id":"cr_1","display_name":"Ada"},
    \\"tools":{"allow":["Read","Glob","Bash(python3 *)"],"deny":["Bash(rm *)"]},
    \\"confirmation":{"required_for":["Write"]},
    \\"egress":{"classes":["file_contents","command_output"],"max_result_bytes":4096,"retention":"run"},
    \\"credentials":[{"ref":"erp-main","purpose":"ERP login","kind":"password"}],
    \\"execution":{"classes":["server"]},
    \\"pricing":{"model":"subscription","estimate_micros_per_run":60000,"currency":"USD"},
    \\"requires":{"protocol":"metask.sealed-skill/v1","client_min_version":"0.6.0"}}
;

/// Build a gateway-shaped Entry JSON around `manifest_json` with a correct
/// digest, for tests and the mock gateway.
pub fn testEntryJson(allocator: std.mem.Allocator, manifest_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_json, .{});
    defer parsed.deinit();
    const canonical = try canonicalize(allocator, parsed.value);
    defer allocator.free(canonical);
    const digest = try digestHex(allocator, canonical);
    defer allocator.free(digest);
    const skill_id = parsed.value.object.get("skill_id").?.string;
    const version = parsed.value.object.get("version").?.string;
    return std.fmt.allocPrint(
        allocator,
        "{{\"skill_id\":\"{s}\",\"version\":\"{s}\",\"manifest\":{s},\"manifest_digest\":\"{s}\",\"subscription\":{{\"state\":\"active\"}}}}",
        .{ skill_id, version, canonical, digest },
    );
}

/// Wrap a Step body (without `digest`) into a Step JSON with a correct digest.
pub fn testStepJson(allocator: std.mem.Allocator, step_without_digest_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var value = try std.json.parseFromSliceLeaky(std.json.Value, scratch, step_without_digest_json, .{});
    const digest = try stepDigest(scratch, value);
    try value.object.put(scratch, "digest", .{ .string = digest });
    const rendered = try serializeValue(scratch, value);
    return allocator.dupe(u8, rendered);
}

test "canonical JSON sorts keys, strips whitespace, refuses floats" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"b\": [1, {\"z\": \"x\", \"a\": true}], \"a\": null}", .{});
    defer parsed.deinit();
    const canonical = try canonicalize(a, parsed.value);
    defer a.free(canonical);
    try std.testing.expectEqualStrings("{\"a\":null,\"b\":[1,{\"a\":true,\"z\":\"x\"}]}", canonical);

    var with_float = try std.json.parseFromSlice(std.json.Value, a, "{\"x\": 1.5}", .{});
    defer with_float.deinit();
    try std.testing.expectError(error.FloatInDigestedObject, canonicalize(a, with_float.value));
}

test "entry parses manifest fields and verifies the digest" {
    const a = std.testing.allocator;
    const entry_json = try testEntryJson(a, TEST_MANIFEST_JSON);
    defer a.free(entry_json);
    var parsed = try parseEntry(a, entry_json);
    defer parsed.deinit();
    const m = parsed.entry.manifest;
    try std.testing.expectEqualStrings("ssk_test", parsed.entry.skill_id);
    try std.testing.expectEqualStrings("erp-post", m.name);
    try std.testing.expectEqual(@as(usize, 3), m.tools_allow.len);
    try std.testing.expectEqualStrings("Bash(python3 *)", m.tools_allow[2]);
    try std.testing.expectEqualStrings("Bash(rm *)", m.tools_deny[0]);
    try std.testing.expectEqual(@as(u64, 4096), m.egress_max_result_bytes);
    try std.testing.expectEqualStrings("erp-main", m.credentials[0].ref);
    try std.testing.expectEqual(@as(i64, 60000), m.pricing_estimate_micros);
    try std.testing.expect(m.executionSupported());
    try std.testing.expect(std.mem.startsWith(u8, parsed.entry.manifest_digest, "sha256:"));
    try std.testing.expectEqualStrings("active", parsed.entry.subscription_state);

    // A tampered digest is refused: the client never pins what it cannot verify.
    const tampered = try std.mem.replaceOwned(u8, a, entry_json, "\"manifest_digest\":\"sha256:0", "\"manifest_digest\":\"sha256:1");
    defer a.free(tampered);
    if (!std.mem.eql(u8, tampered, entry_json)) {
        try std.testing.expectError(error.InvalidShape, parseEntry(a, tampered));
    }
}

test "manifest without an allowlist or description is refused" {
    const a = std.testing.allocator;
    const no_tools = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"s\",\"version\":\"1\",\"name\":\"n\",\"description\":\"d\",\"tools\":{\"allow\":[]}}";
    const entry = try testEntryJson(a, no_tools);
    defer a.free(entry);
    try std.testing.expectError(error.InvalidShape, parseEntry(a, entry));
}

test "step parses calls, usage and the hash-chain digest" {
    const a = std.testing.allocator;
    const body =
        \\{"run_id":"run_1","seq":1,"run_state":"opaque-blob","kind":"tool_calls",
        \\"calls":[{"id":"call_1","name":"Read","input":{"file_path":"a.txt"},"confirm":true,"deadline_ms":30000,"result_limit_bytes":1024}],
        \\"text":"reading","usage":{"model":"m","input_tokens":10,"output_tokens":2,"cost_micros":70,"currency":"USD"},
        \\"cumulative":{"steps":1,"cost_micros":70,"currency":"USD","input_tokens":10,"output_tokens":2},
        \\"issuer":{"skill_host":"metask","inference_gateway":"metask"},
        \\"prev_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}
    ;
    const step_json = try testStepJson(a, body);
    defer a.free(step_json);
    var parsed = try parseStep(a, step_json);
    defer parsed.deinit();
    const s = parsed.step;
    try std.testing.expectEqual(StepKind.tool_calls, s.kind);
    try std.testing.expectEqual(@as(u64, 1), s.seq);
    try std.testing.expectEqualStrings("opaque-blob", s.run_state);
    try std.testing.expectEqual(@as(usize, 1), s.calls.len);
    try std.testing.expectEqualStrings("Read", s.calls[0].name);
    try std.testing.expectEqualStrings("{\"file_path\":\"a.txt\"}", s.calls[0].input_json);
    try std.testing.expect(s.calls[0].confirm);
    try std.testing.expectEqual(@as(?u64, 30000), s.calls[0].deadline_ms);
    try std.testing.expectEqual(@as(i64, 70), s.usage.cost_micros);
    try std.testing.expectEqual(@as(u64, 1), s.cumulative.steps);
    try std.testing.expectEqualStrings("metask", s.issuer_inference_gateway);
    try std.testing.expectEqualStrings(GENESIS_DIGEST, s.prev_digest);

    // run_state is excluded from the digest, so a different blob still verifies…
    const other_state = try std.mem.replaceOwned(u8, a, step_json, "opaque-blob", "other-blob");
    defer a.free(other_state);
    var parsed2 = try parseStep(a, other_state);
    parsed2.deinit();
    // …while a changed call does not.
    const other_call = try std.mem.replaceOwned(u8, a, step_json, "a.txt", "b.txt");
    defer a.free(other_call);
    try std.testing.expectError(error.InvalidShape, parseStep(a, other_call));
}

test "step kinds enforce their required fields" {
    const a = std.testing.allocator;
    const empty_calls = try testStepJson(a, "{\"run_id\":\"r\",\"seq\":1,\"kind\":\"tool_calls\",\"calls\":[]}");
    defer a.free(empty_calls);
    try std.testing.expectError(error.InvalidShape, parseStep(a, empty_calls));
    const failed_no_reason = try testStepJson(a, "{\"run_id\":\"r\",\"seq\":2,\"kind\":\"failed\"}");
    defer a.free(failed_no_reason);
    try std.testing.expectError(error.InvalidShape, parseStep(a, failed_no_reason));
    const unknown_kind = try testStepJson(a, "{\"run_id\":\"r\",\"seq\":2,\"kind\":\"prefetch\"}");
    defer a.free(unknown_kind);
    try std.testing.expectError(error.InvalidShape, parseStep(a, unknown_kind));
    const final = try testStepJson(a, "{\"run_id\":\"r\",\"seq\":3,\"kind\":\"final\",\"text\":\"done\",\"charge\":{\"run_id\":\"r\",\"cost_micros\":5,\"currency\":\"USD\",\"steps\":3}}");
    defer a.free(final);
    var parsed = try parseStep(a, final);
    defer parsed.deinit();
    try std.testing.expectEqual(StepKind.final, parsed.step.kind);
    try std.testing.expectEqual(@as(i64, 5), parsed.step.charge.?.cost_micros);
}

test "request writers produce the documented shapes" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeStartParams(&out.writer, .{
        .skill_id = "ssk",
        .manifest_digest = "sha256:ab",
        .prompt = "post \"this\"",
        .arguments = &.{"folder"},
        .tools_json = "[{\"name\":\"Read\"}]",
        .max_cost_micros = 500000,
        .max_steps = 200,
        .client_name = "metacodes",
        .client_version = "0.6.0",
        .client_platform = "windows-x86_64",
        .run_ref = "ref",
    });
    try std.testing.expectEqualStrings(
        "{\"skill_id\":\"ssk\",\"manifest_digest\":\"sha256:ab\",\"prompt\":\"post \\\"this\\\"\",\"arguments\":[\"folder\"],\"tools\":[{\"name\":\"Read\"}],\"budget\":{\"max_cost_micros\":500000,\"currency\":\"USD\",\"max_steps\":200},\"client\":{\"name\":\"metacodes\",\"version\":\"0.6.0\",\"platform\":\"windows-x86_64\",\"run_ref\":\"ref\"},\"confirmation\":\"client\"}",
        out.written(),
    );

    var cont: std.Io.Writer.Allocating = .init(a);
    defer cont.deinit();
    try writeContinueParams(&cont.writer, "run_1", "blob", 1, &.{
        .{ .tool_use_id = "call_1", .content = "ok", .truncated = true, .redactions = &.{"erp-main"} },
        .{ .tool_use_id = "call_2", .content = "", .is_error = true, .refusal = .policy_violation },
    });
    try std.testing.expectEqualStrings(
        "{\"run_id\":\"run_1\",\"run_state\":\"blob\",\"seq\":1,\"results\":[{\"tool_use_id\":\"call_1\",\"content\":\"ok\",\"is_error\":false,\"truncated\":true,\"redactions\":[\"erp-main\"]},{\"tool_use_id\":\"call_2\",\"content\":\"\",\"is_error\":true,\"truncated\":false,\"refusal\":\"policy_violation\",\"redactions\":[]}]}",
        cont.written(),
    );

    var req: std.Io.Writer.Allocating = .init(a);
    defer req.deinit();
    try writeRequest(&req.writer, 7, .runs_cancel, "{\"run_id\":\"r\"}");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"sealed/runs.cancel\",\"params\":{\"run_id\":\"r\"}}", req.written());

    // The mirror fields (§9.1): system prompt, base dir, provider route,
    // provider tools and the request parameters of the client's fork.
    var mirror: std.Io.Writer.Allocating = .init(a);
    defer mirror.deinit();
    try writeStartParams(&mirror.writer, .{
        .skill_id = "ssk",
        .manifest_digest = "sha256:ab",
        .prompt = "go",
        .max_cost_micros = 1,
        .max_steps = 2,
        .client_name = "metacodes",
        .client_version = "0.6.0",
        .client_platform = "p",
        .system = "You are a subagent.",
        .base_dir = "/home/u/.metacodes/sealed-skills/erp-post",
        .provider_kind = "anthropic",
        .provider_base_url = "https://api.anthropic.com",
        .provider_auth_json = "{\"scheme\":\"api_key_header\",\"header\":\"x-api-key\"}",
        .provider_tools_json = "[{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}]",
        .model = "claude-sonnet-4-5",
        .max_tokens = 8192,
        .reasoning_effort = "high",
    });
    try std.testing.expect(std.mem.endsWith(
        u8,
        mirror.written(),
        "\"confirmation\":\"client\",\"system\":\"You are a subagent.\",\"base_dir\":\"/home/u/.metacodes/sealed-skills/erp-post\",\"provider\":{\"kind\":\"anthropic\",\"base_url\":\"https://api.anthropic.com\",\"auth\":{\"scheme\":\"api_key_header\",\"header\":\"x-api-key\"}},\"provider_tools\":[{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}],\"request\":{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":8192,\"reasoning_effort\":\"high\"}}",
    ));
}

test "assets: paths are confined to the pin directory and the public set" {
    try std.testing.expect(validAssetPath("scripts/post.py"));
    try std.testing.expect(validAssetPath("references/public.md"));
    try std.testing.expect(!validAssetPath("sealed/notes.md"));
    try std.testing.expect(!validAssetPath("SKILL.md"));
    try std.testing.expect(!validAssetPath("sealed.json"));
    try std.testing.expect(!validAssetPath("../escape.txt"));
    try std.testing.expect(!validAssetPath("/abs.txt"));
    try std.testing.expect(!validAssetPath("a//b"));
    try std.testing.expect(!validAssetPath("C:x"));
}

test "assets: the result is decoded and its digest verified" {
    const a = std.testing.allocator;
    const content = "print('hi')\n";
    const digest = try digestHex(a, content);
    defer a.free(digest);
    var encoded_buf: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buf, content);
    const ok_json = try std.fmt.allocPrint(a, "{{\"path\":\"scripts/post.py\",\"sha256\":\"{s}\",\"content_base64\":\"{s}\"}}", .{ digest, encoded });
    defer a.free(ok_json);
    var parsed = try parseAsset(a, ok_json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(content, parsed.content);
    const bad_json = try std.fmt.allocPrint(a, "{{\"path\":\"scripts/post.py\",\"sha256\":\"sha256:00\",\"content_base64\":\"{s}\"}}", .{encoded});
    defer a.free(bad_json);
    try std.testing.expectError(error.InvalidShape, parseAsset(a, bad_json));
}

test "manifest tool rules: plain names, argument patterns, MCP wildcards, deny first" {
    try std.testing.expect(ruleCoversTool("Read", "Read"));
    try std.testing.expect(!ruleCoversTool("Read", "Write"));
    try std.testing.expect(ruleCoversTool("Bash(python3 *)", "Bash"));
    try std.testing.expect(ruleCoversTool("mcp__playwright__*", "mcp__playwright__browser_click"));
    try std.testing.expect(!ruleCoversTool("mcp__playwright__*", "mcp__github__issue"));
    try std.testing.expect(ruleNamesWholeTool("Bash", "Bash"));
    try std.testing.expect(!ruleNamesWholeTool("Bash(rm *)", "Bash"));

    const a = std.testing.allocator;
    const entry_json = try testEntryJson(a, TEST_MANIFEST_JSON);
    defer a.free(entry_json);
    var parsed = try parseEntry(a, entry_json);
    defer parsed.deinit();
    const m = &parsed.entry.manifest;
    try std.testing.expect(manifestAllowsTool(m, "Read"));
    try std.testing.expect(manifestAllowsTool(m, "Glob"));
    // `Bash(rm *)` denies an argument pattern, not the tool: the frame checks it.
    try std.testing.expect(manifestAllowsTool(m, "Bash"));
    try std.testing.expect(!manifestAllowsTool(m, "Grep"));
    try std.testing.expect(!manifestAllowsTool(m, "Write"));
}

test "disclosure: the Step's count parses; the manifest's policy is one of three words" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    // A Step is only accepted with its own digest: stamp the fixture.
    const Stamped = struct {
        fn step(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
            const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
            const digest = try stepDigest(allocator, value);
            return std.fmt.allocPrint(allocator, "{s},\"digest\":\"{s}\"}}", .{ body[0 .. body.len - 1], digest });
        }
    };
    var counted = try parseStep(a, try Stamped.step(al, "{\"run_id\":\"run_1\",\"seq\":2,\"run_state\":\"\",\"kind\":\"final\",\"text\":\"x [sealed] y\",\"disclosure\":{\"redactions\":2}}"));
    defer counted.deinit();
    try std.testing.expectEqual(@as(u64, 2), counted.step.disclosure_redactions);
    var plain = try parseStep(a, try Stamped.step(al, "{\"run_id\":\"run_1\",\"seq\":1,\"run_state\":\"\",\"kind\":\"final\",\"text\":\"x\"}"));
    defer plain.deinit();
    try std.testing.expectEqual(@as(u64, 0), plain.step.disclosure_redactions);

    const failing = try std.mem.replaceOwned(u8, a, TEST_MANIFEST_JSON, "\"retention\":\"run\"", "\"retention\":\"run\",\"disclosure\":\"fail\"");
    defer a.free(failing);
    const failing_entry = try testEntryJson(a, failing);
    defer a.free(failing_entry);
    var parsed = try parseEntry(a, failing_entry);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fail", parsed.entry.manifest.egress_disclosure);
    const default_entry = try testEntryJson(a, TEST_MANIFEST_JSON);
    defer a.free(default_entry);
    var defaulted = try parseEntry(a, default_entry);
    defer defaulted.deinit();
    try std.testing.expectEqualStrings("redact", defaulted.entry.manifest.egress_disclosure);
    const loud = try std.mem.replaceOwned(u8, a, TEST_MANIFEST_JSON, "\"retention\":\"run\"", "\"retention\":\"run\",\"disclosure\":\"loud\"");
    defer a.free(loud);
    const loud_entry = try testEntryJson(a, loud);
    defer a.free(loud_entry);
    try std.testing.expectError(error.InvalidShape, parseEntry(a, loud_entry));
}

test "egress classes: the tools the client can classify, and what a manifest declares" {
    try std.testing.expectEqualStrings("file_contents", egressClassOfTool("Read").?);
    try std.testing.expectEqualStrings("file_contents", egressClassOfTool("Grep").?);
    try std.testing.expectEqualStrings("repository_structure", egressClassOfTool("Glob").?);
    try std.testing.expectEqualStrings("command_output", egressClassOfTool("Bash").?);
    try std.testing.expectEqualStrings("page_snapshot", egressClassOfTool("WebFetch").?);
    try std.testing.expect(egressClassOfTool("Write") == null);
    try std.testing.expect(egressClassOfTool("Task") == null);
    try std.testing.expect(egressClassOfTool("AskUserQuestion") == null);
    try std.testing.expect(egressClassOfTool("mcp__github__issue") == null);

    const a = std.testing.allocator;
    const entry_json = try testEntryJson(a, TEST_MANIFEST_JSON);
    defer a.free(entry_json);
    var parsed = try parseEntry(a, entry_json);
    defer parsed.deinit();
    const m = &parsed.entry.manifest;
    try std.testing.expect(manifestDeclaresEgress(m, "file_contents"));
    try std.testing.expect(manifestDeclaresEgress(m, "command_output"));
    try std.testing.expect(!manifestDeclaresEgress(m, "page_snapshot"));
    try std.testing.expect(!manifestDeclaresEgress(m, EGRESS_CODEBASE_CONTEXT_CLASS));
}

test "results digest: client entries and the gateway's parsed array agree (§8.3)" {
    const a = std.testing.allocator;
    const entries = [_]ResultEntry{
        .{ .tool_use_id = "call_1", .content = "line one\nline \"two\"", .truncated = true, .redactions = &.{"erp-main"} },
        .{ .tool_use_id = "call_2", .content = "", .is_error = true, .refusal = .policy_violation },
    };
    const client_side = try resultsDigest(a, &entries);
    defer a.free(client_side);
    // What the gateway receives: the same array inside the continue params,
    // possibly re-serialized with other spacing or key order by a proxy.
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    try writeContinueParams(&params.writer, "run_1", "blob", 1, &entries);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, params.written(), .{});
    defer parsed.deinit();
    const gateway_side = try resultsDigestOfValue(a, parsed.value.object.get("results").?);
    defer a.free(gateway_side);
    try std.testing.expectEqualStrings(client_side, gateway_side);
    try std.testing.expect(std.mem.startsWith(u8, client_side, "sha256:"));
    // A changed result changes the digest.
    const other = [_]ResultEntry{.{ .tool_use_id = "call_1", .content = "line one" }};
    const other_digest = try resultsDigest(a, &other);
    defer a.free(other_digest);
    try std.testing.expect(!std.mem.eql(u8, client_side, other_digest));
}

test "json-rpc responses: result, known error, foreign id" {
    const a = std.testing.allocator;
    var ok = try parseResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"x\":1}}", 3);
    defer ok.deinit();
    try std.testing.expectEqualStrings("{\"x\":1}", ok.response.result);

    var failed = try parseResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32004,\"message\":\"pin stale\",\"data\":{\"code\":\"manifest_changed\",\"current\":{}}}}", 3);
    defer failed.deinit();
    try std.testing.expectEqual(ErrorCode.manifest_changed, failed.response.err.known.?);
    try std.testing.expectEqualStrings("pin stale", failed.response.err.message);

    try std.testing.expectError(error.NotOurResponse, parseResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{}}", 3));
    try std.testing.expectError(error.NotOurResponse, parseResponse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}", 3));
}

test "disclosure: a string sets both policies, an object sets each, an unknown word is refused" {
    const a = std.testing.allocator;
    const both = try std.mem.replaceOwned(u8, a, TEST_MANIFEST_JSON, "\"retention\":\"run\"", "\"retention\":\"run\",\"disclosure\":\"fail\"");
    defer a.free(both);
    const both_entry = try testEntryJson(a, both);
    defer a.free(both_entry);
    var parsed_both = try parseEntry(a, both_entry);
    defer parsed_both.deinit();
    try std.testing.expectEqualStrings("fail", parsed_both.entry.manifest.egress_disclosure);
    try std.testing.expectEqualStrings("fail", parsed_both.entry.manifest.egress_disclosure_references);

    const split = try std.mem.replaceOwned(u8, a, TEST_MANIFEST_JSON, "\"retention\":\"run\"", "\"retention\":\"run\",\"disclosure\":{\"references\":\"off\"}");
    defer a.free(split);
    const split_entry = try testEntryJson(a, split);
    defer a.free(split_entry);
    var parsed_split = try parseEntry(a, split_entry);
    defer parsed_split.deinit();
    try std.testing.expectEqualStrings("redact", parsed_split.entry.manifest.egress_disclosure);
    try std.testing.expectEqualStrings("off", parsed_split.entry.manifest.egress_disclosure_references);

    const bad = try std.mem.replaceOwned(u8, a, TEST_MANIFEST_JSON, "\"retention\":\"run\"", "\"retention\":\"run\",\"disclosure\":{\"body\":\"loud\"}");
    defer a.free(bad);
    const bad_entry = try testEntryJson(a, bad);
    defer a.free(bad_entry);
    try std.testing.expectError(error.InvalidShape, parseEntry(a, bad_entry));
}
