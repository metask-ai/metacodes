//! One-shot, deterministic projection of completed tool results into Conversation.
//!
//! Hooks and UI consume the typed result's deterministic rendering first:
//! legacy inline results remain raw, while byte-zero results are already a
//! bounded artifact envelope because no complete in-memory value exists. This
//! module then commits either the original small bytes or one stable artifact
//! envelope; historical messages are never re-projected before later requests.

const std = @import("std");
const artifact = @import("tool_result_artifact.zig");
const tool_result = @import("tool_result.zig");
const types = @import("../types.zig");
const conversation_mod = @import("conversation.zig");
const result_budget = @import("result_budget.zig");
const json_mod = @import("../json.zig");
const util_json = @import("../util/json.zig");

pub const SCHEMA = tool_result.PROJECTION_SCHEMA;
pub const ENVELOPE_PREFIX = tool_result.ENVELOPE_PREFIX;
pub const BASH_SCHEMA = "metacodes.bash-result.v2";

/// Fixed JSON scaffolding of one artifact/fallback envelope: schema version,
/// projection kind, artifact id, media type, original size, digest, the two
/// capture flags, the preview field names and the read instruction. Measured
/// at ~500 bytes with the longest production media type; rounded up so a
/// preview sized against `payloadAllowance` cannot push the rendered envelope
/// past the per-result budget it was derived from.
pub const ENVELOPE_OVERHEAD_BYTES: result_budget.Encoded = .of(640);

/// Budget bytes per token, the same approximation `turnBudgetBytes` uses to
/// turn a token window into a byte budget.
const BUDGET_BYTES_PER_TOKEN: usize = 4;

/// What one image tool result costs this layer's byte budget. A vision block is
/// billed by the provider at a fixed token price (`IMAGE_TOKEN_ESTIMATE`),
/// never by its base64 length, so measuring it in bytes would let a single
/// 3.75 MB screenshot evict every unrelated result in the same turn. Public
/// because the AgentCore budget wrapper (`session_budget`) charges its payload
/// cap for an inline image at the same figure.
pub const IMAGE_RESULT_BUDGET_BYTES: usize =
    conversation_mod.IMAGE_TOKEN_ESTIMATE * BUDGET_BYTES_PER_TOKEN;

/// Image-shaped tool result (`{"type":"image",...}` from the Read tool).
/// Detection delegates to `dialect.extractImageResult` — the single truth the
/// wire serializers use — so this layer can never drift into a second sniffer.
/// Module-private on purpose: consumers that need the predicate should ask
/// that single truth directly rather than route through the projection layer.
fn isImageResult(content: []const u8) bool {
    return json_mod.extractImageResult(content) != null;
}

/// Budget weight of one committed result. Images cost their native token
/// estimate; every other result costs exactly its bytes, so non-image
/// projection stays byte-identical to the pre-image-carve-out behavior.
fn accountedBytes(content: []const u8) usize {
    return if (isImageResult(content)) IMAGE_RESULT_BUDGET_BYTES else content.len;
}

pub const Item = struct {
    tool_name: []const u8,
    content: *[]const u8,
    is_error: bool,
};

pub const Config = struct {
    session_root: []const u8,
    /// The single budget, derived once per turn from the provider window.
    budget: result_budget.Budget,
    /// Encoded preview bytes a spilled result may keep. `null` derives it from
    /// the budget, which is the only defensible default: spilling means the
    /// content exceeded the allowance, not that the allowance disappeared.
    ///
    /// An explicit value replaces the derivation outright rather than capping
    /// it - tests use it to pin an exact preview against a deliberately tiny
    /// `per_result_bytes`, which a cap would collapse to zero. It is therefore
    /// the caller's job to keep an override inside the budget; only turn
    /// pressure shrinks it afterwards.
    preview_bytes: ?usize = null,
    /// Aggregate base64 bytes of native image results the turn may keep.
    /// Images bypass the byte budget above, but providers cap the request
    /// size (`types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST`); beyond this the
    /// largest images spill into recoverable envelopes with no preview.
    per_turn_image_bytes: usize = types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST,

    fn previewCap(self: Config) usize {
        return self.preview_bytes orelse
            self.budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES).raw();
    }
};

pub const Stats = struct {
    /// Literal bytes handed to this pass (artifact envelopes count their
    /// recorded original size).
    raw_bytes: usize = 0,
    /// Literal bytes after projection — same unit as `raw_bytes`, so the pair
    /// reads as a real before/after. The turn-budget decision is **not** made
    /// on this number: see `budget_exhausted`.
    projected_bytes: usize = 0,
    artifact_bytes: usize = 0,
    artifact_spill_count: usize = 0,
    unrecoverable_fallback_count: usize = 0,
    /// Results whose *tool* emitted a JSON body (Bash's `bash-result.v2`,
    /// a bounded `rows/cursor/total` envelope). Projection envelopes are JSON
    /// too and are deliberately not counted: they are this layer's artifact.
    structured_result_count: usize = 0,
    structured_projection_failures: usize = 0,
    turn_budget_spills: usize = 0,
    /// Image results spilled because the turn exceeded `per_turn_image_bytes`
    /// (a wire-size limit, not a budget): the only rule that spills a picture.
    image_spills: usize = 0,
    /// Image results kept inline that byte-length rules would otherwise have
    /// spilled (over `per_result_bytes`). Logged rather than left silent, so
    /// the carve-out is visible in the same line that reports the spills.
    image_exempt_count: usize = 0,
    /// Committed artifact envelopes whose capture-time preview was smaller
    /// than this turn's budget allows and was re-rendered against it.
    envelope_regrown_count: usize = 0,
    /// Of those, the ones whose original fitted the budget outright and were
    /// returned to the model in full. A non-zero count here is the signal the
    /// capture path spilled something it never needed to.
    envelope_reinlined_count: usize = 0,
    /// Bytes this session's artifact store is holding, as last observed by a
    /// publish. Zero when nothing has been published yet. Exhausting the
    /// session quota makes every later oversized result permanently
    /// unrecoverable, and until now the only trace of approaching it was an
    /// undifferentiated fallback count.
    session_artifact_bytes: u64 = 0,
    /// Whether the committed results still exceed `per_turn_bytes` in **budget
    /// weight** (`accountedBytes`: an image costs its token estimate, every
    /// other result costs its bytes). Deliberately not derived from
    /// `projected_bytes`, which is a byte metric.
    budget_exhausted: bool = false,

    pub fn changed(self: Stats) bool {
        return self.artifact_spill_count != 0 or
            self.unrecoverable_fallback_count != 0 or
            self.envelope_regrown_count != 0;
    }
};

pub fn turnBudgetBytes(max_input_tokens: usize) usize {
    return result_budget.perTurnBytes(max_input_tokens);
}

/// The three numbers every allowance decision needs, bundled so they cannot
/// drift apart: what one result may cost, how big a preview it keeps when it
/// is spilled, and the ceiling the turn budget has lowered them to.
const Allowance = struct {
    per_result_bytes: usize,
    preview_cap: usize,
    ceiling: usize,

    fn at(self: Allowance, ceiling: usize) Allowance {
        return .{
            .per_result_bytes = self.per_result_bytes,
            .preview_cap = self.preview_cap,
            .ceiling = ceiling,
        };
    }

    fn underPressure(self: Allowance) bool {
        return self.ceiling < self.per_result_bytes;
    }

    /// Preview a spilled result keeps. An explicitly configured preview size
    /// is a fixed request, so only turn pressure may shrink it.
    fn previewBytes(self: Allowance) result_budget.Encoded {
        const cap = result_budget.Encoded.of(self.preview_cap);
        if (!self.underPressure()) return cap;
        return cap.min(result_budget.Encoded.of(self.ceiling).minus(ENVELOPE_OVERHEAD_BYTES));
    }

    fn spillCost(self: Allowance) usize {
        return ENVELOPE_OVERHEAD_BYTES.plus(self.previewBytes()).raw();
    }

    /// Model-visible cost of a result of `len` bytes.
    ///
    /// Spilling is only ever chosen when it actually saves bytes. An envelope
    /// is ~640 bytes of scaffolding, so replacing a 700-byte result with one
    /// loses content *and* grows the request - the exact negative-sum trade
    /// the Bash channel preview used to make between 1537 and ~1760 bytes.
    /// The `@min(len, ...)` makes that outcome unrepresentable.
    /// `len` is a committed result's own length, which is what it costs the
    /// turn once rendered - the same unit as the ceiling.
    fn cost(self: Allowance, len: usize) usize {
        if (len <= self.ceiling) return len;
        return @min(len, self.spillCost());
    }
};

/// Largest per-item cost ceiling under which every planned result fits the
/// turn budget. Monotone in `ceiling`, so a binary search finds the exact
/// water line: results below it are untouched and only those above it are
/// trimmed, instead of the largest result being evicted outright.
fn resolveTurnCeiling(
    lengths: []const usize,
    plan: []const ItemPlan,
    fixed_cost: usize,
    per_turn_bytes: usize,
    allowance: Allowance,
) usize {
    if (turnCost(lengths, plan, fixed_cost, allowance) <= per_turn_bytes)
        return allowance.per_result_bytes;
    var low: usize = 0;
    var high: usize = allowance.per_result_bytes;
    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        if (turnCost(lengths, plan, fixed_cost, allowance.at(mid)) <= per_turn_bytes)
            low = mid
        else
            high = mid - 1;
    }
    return low;
}

fn turnCost(
    lengths: []const usize,
    plan: []const ItemPlan,
    fixed_cost: usize,
    allowance: Allowance,
) usize {
    var total = fixed_cost;
    for (lengths, plan) |len, entry| {
        if (entry.exempt) continue;
        total +|= allowance.cost(len);
    }
    return total;
}

const ItemPlan = struct {
    /// Never spilled: ReadArtifact (its own recovery would recurse), encoded
    /// tool errors (bounded control messages), images (a vision block the
    /// model cannot read back as an artifact), and results already committed
    /// as an envelope.
    exempt: bool,
    structured: bool,
};

pub fn project(allocator: std.mem.Allocator, items: []Item, config: Config) !Stats {
    var stats = Stats{};
    const plan = try allocator.alloc(ItemPlan, items.len);
    defer allocator.free(plan);
    const lengths = try allocator.alloc(usize, items.len);
    defer allocator.free(lengths);

    // Correct capture-time previews before anything is planned: an envelope
    // may be re-inlined outright here, which changes both what it costs and
    // whether it is exempt at all.
    const uncapped = Allowance{
        .per_result_bytes = config.budget.per_result_bytes,
        .preview_cap = config.previewCap(),
        .ceiling = config.budget.per_result_bytes,
    };
    // Price the rewrite *before* doing it. Regrowing against the uncapped
    // allowance and only then finding the turn cannot afford the result means
    // reading the artifact back, inlining it, and spilling it to the same
    // artifact again inside one pass - while reporting both "returned to the
    // model in full" and "spilled" for the same item.
    //
    // This ceiling is deliberately allowed to come out *below* the one the
    // real pass computes: there, a committed envelope is exempt and costs
    // whatever it already is, so nothing downstream can restrain how far this
    // pass grows it. Restraining it here is the whole point.
    const regrow_allowance = uncapped.at(regrowCeiling(items, plan, lengths, config, uncapped));
    for (items) |item| {
        if (item.is_error) continue;
        if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
        if (!isRecoverableEnvelope(item.content.*)) continue;
        if (try regrowCommittedEnvelope(allocator, item, config, regrow_allowance)) {
            stats.envelope_regrown_count += 1;
            if (!isProjectionEnvelope(item.content.*)) stats.envelope_reinlined_count += 1;
        }
    }

    var fixed_cost: usize = 0;
    for (items, 0..) |item, index| {
        const content = item.content.*;
        if (recoverableEnvelopeOriginalBytes(content)) |original_bytes| {
            stats.raw_bytes +|= original_bytes;
            stats.artifact_bytes +|= original_bytes;
            stats.artifact_spill_count +|= 1;
        } else if (bashCapturedBytes(content)) |captured| {
            // Bash spills its own channels before this pass ever sees them, so
            // billing the envelope's length would make `raw_bytes` report a
            // 2.4KB envelope for a 40KB command. The pair is documented as a
            // real before/after; for that to be true it has to count what the
            // command actually produced.
            stats.raw_bytes +|= captured;
        } else {
            stats.raw_bytes +|= content.len;
        }
        const structured = toolEmittedStructured(content);
        if (structured) stats.structured_result_count += 1;
        const image = isImageResult(content);
        const exempt = image or
            item.is_error or
            isProjectionEnvelope(content) or
            std.mem.eql(u8, item.tool_name, "ReadArtifact");
        if (exempt) fixed_cost +|= accountedBytes(content);
        plan[index] = .{ .exempt = exempt, .structured = structured };
    }

    // Wire-size cap for the turn's native images (the agent loop passes what
    // `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST` leaves after the history's
    // non-trimmable pictures). Images bypass the byte budget, so this is the
    // one rule that can spill a picture: largest first (strict > keeps the
    // ordinal as the deterministic tie-breaker) and with no preview - a base64
    // preview is noise for the model and would put part of the payload on the
    // wire anyway; the envelope keeps the artifact id and sha256 for
    // ReadArtifact recovery. A spilled image is a committed envelope from here
    // on: still exempt, but priced at its literal length instead of the vision
    // estimate, so the fixed cost is repriced before the ceiling is resolved.
    var image_bytes: usize = 0;
    for (items) |item| {
        if (isImageResult(item.content.*)) image_bytes +|= item.content.*.len;
    }
    while (image_bytes > config.per_turn_image_bytes) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (items, 0..) |item, index| {
            if (!isImageResult(item.content.*)) continue;
            if (item.content.*.len > biggest_len) {
                biggest = index;
                biggest_len = item.content.*.len;
            }
        }
        const index = biggest orelse break;
        try spillOne(allocator, items[index], plan[index].structured, config, &stats, result_budget.Encoded.of(0), false);
        fixed_cost = (fixed_cost -| IMAGE_RESULT_BUDGET_BYTES) +| items[index].content.*.len;
        stats.image_spills += 1;
        image_bytes -= biggest_len;
    }
    for (items) |item| {
        const content = item.content.*;
        if (isImageResult(content) and content.len > config.budget.per_result_bytes) stats.image_exempt_count += 1;
    }

    // One allowance decision for every result, then one render each. The
    // previous shape decided per-result first and then re-spilled the largest
    // item in a loop, which could render the same result twice and could not
    // shrink anything it had already turned into an envelope.
    for (items, 0..) |item, index| lengths[index] = item.content.*.len;
    const allowance = uncapped.at(
        resolveTurnCeiling(lengths, plan, fixed_cost, config.budget.per_turn_bytes, uncapped),
    );

    for (items, plan) |item, entry| {
        if (entry.exempt) continue;
        const len = item.content.*.len;
        if (allowance.cost(len) >= len) continue;
        try spillOne(
            allocator,
            item,
            entry.structured,
            config,
            &stats,
            allowance.previewBytes(),
            allowance.underPressure(),
        );
    }

    stats.projected_bytes = literalTotal(items);
    stats.budget_exhausted = accountedTotal(items) > config.budget.per_turn_bytes;
    const usage = artifact.sessionUsage(config.session_root);
    if (usage.observed) stats.session_artifact_bytes = usage.used_bytes;
    return stats;
}

/// The ceiling the regrow pass may spend, given what rewriting every committed
/// envelope this turn would cost.
///
/// The regrow pass is the one place that can make a result *bigger*, and its
/// output is exempt from the spill pass below - so if it is not bounded here,
/// it is not bounded at all. Two ways that bites without this:
///
///   - one envelope re-inlined against the uncapped allowance, then spilled
///     straight back out by the turn ceiling - the artifact read back, written
///     again, and both "returned to the model in full" and "spilled" reported
///     for the same item;
///   - ten parallel tool calls whose envelopes each grow to `per_result_bytes`,
///     which is ten times the per-result budget and well past the turn's.
///
/// Uses `plan` and `lengths` as scratch; both are overwritten by the real
/// planning pass afterwards. Everything keeps the exemption and the length it
/// has today except a committed envelope, which is made non-exempt and priced
/// at its original's size: below the ceiling that is what re-inlining costs,
/// and above it `Allowance.cost` charges preview-plus-scaffolding, which is
/// exactly what regrowing costs. Nothing else is repriced, so this can only
/// restrain the rewrite - it never spills something the real pass would have
/// left alone.
fn regrowCeiling(
    items: []const Item,
    plan: []ItemPlan,
    lengths: []usize,
    config: Config,
    uncapped: Allowance,
) usize {
    if (config.session_root.len == 0) return uncapped.per_result_bytes;
    var fixed_cost: usize = 0;
    var any_regrowable = false;
    for (items, 0..) |item, index| {
        const content = item.content.*;
        const read_artifact = std.mem.eql(u8, item.tool_name, "ReadArtifact");
        // The same gate the regrow loop itself applies.
        const regrowable = !item.is_error and !read_artifact and isRecoverableEnvelope(content);
        const exempt = !regrowable and
            (isImageResult(content) or item.is_error or isProjectionEnvelope(content) or read_artifact);
        lengths[index] = if (regrowable)
            (recoverableEnvelopeOriginalBytes(content) orelse content.len)
        else
            content.len;
        plan[index] = .{ .exempt = exempt, .structured = false };
        if (regrowable) any_regrowable = true;
        if (exempt) fixed_cost +|= accountedBytes(content);
    }
    if (!any_regrowable) return uncapped.per_result_bytes;
    return resolveTurnCeiling(lengths, plan, fixed_cost, config.budget.per_turn_bytes, uncapped);
}

/// Bytes a Bash result actually captured, summed across both channels.
/// Cheap prefix check first: only a `metacodes.bash-result.v2` envelope is
/// parsed.
fn bashCapturedBytes(content: []const u8) ?usize {
    if (std.mem.indexOf(u8, content[0..@min(content.len, 96)], BASH_SCHEMA) == null) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    var total: usize = 0;
    var seen = false;
    for ([_][]const u8{ "stdout_captured_bytes", "stderr_captured_bytes" }) |key| {
        const value = parsed.value.object.get(key) orelse continue;
        if (value != .integer or value.integer < 0) continue;
        seen = true;
        total +|= @intCast(value.integer);
    }
    return if (seen) total else null;
}

fn recoverableEnvelopeOriginalBytes(content: []const u8) ?usize {
    if (!isRecoverableEnvelope(content)) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const original = parsed.value.object.get("original_bytes") orelse return null;
    if (original != .integer or original.integer < 0) return null;
    return std.math.cast(usize, original.integer);
}

pub fn isProjectionEnvelope(content: []const u8) bool {
    return std.mem.startsWith(u8, content, ENVELOPE_PREFIX);
}

pub fn isRecoverableEnvelope(content: []const u8) bool {
    return std.mem.startsWith(u8, content, ENVELOPE_PREFIX ++ "\"artifact\"");
}

/// Whether clearing this completed result would destroy its only bounded
/// recovery capability. Bash owns its channel handles directly - a published
/// artifact, or the process spool when the capture was too large to publish -
/// while all other tools use the generic projection envelope.
pub fn hasRecoverableArtifact(content: []const u8) bool {
    if (isRecoverableEnvelope(content)) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const version = parsed.value.object.get("schema_version") orelse return false;
    if (version != .string or !std.mem.eql(u8, version.string, BASH_SCHEMA)) return false;
    return bashChannelRecoverable(parsed.value.object, "stdout") or
        bashChannelRecoverable(parsed.value.object, "stderr");
}

/// Whether one Bash channel still has a way back to the bytes it elided: a
/// published artifact, addressed by content.
///
/// A spool-path disjunct was tried here, so that a capture too large to publish
/// - no artifact id, nothing to make a content-addressed promise about - would
/// still be protected by the file on disk. It was removed with the field it
/// read: `doc/API.md`'s prompt-cache contract lists staging paths and random
/// ids among the things that are never model-visible, and a JobRegistry spool
/// path is both. Such a capture is genuinely unrecoverable, and
/// `<channel>_storage_error` says so rather than implying otherwise.
fn bashChannelRecoverable(object: std.json.ObjectMap, label: []const u8) bool {
    var key_buffer: [32]u8 = undefined;
    const recoverable = object.get(channelKey(&key_buffer, label, "_recoverable")) orelse return false;
    if (recoverable != .bool or !recoverable.bool) return false;
    const id = object.get(channelKey(&key_buffer, label, "_artifact_id")) orelse return false;
    return id == .string and validArtifactId(id.string);
}

fn channelKey(buffer: []u8, label: []const u8, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ label, suffix }) catch suffix;
}

fn validArtifactId(id: []const u8) bool {
    if (id.len != artifact.ID_BYTES or !std.mem.startsWith(u8, id, artifact.ID_PREFIX)) return false;
    for (id[artifact.ID_PREFIX.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

/// Re-render a committed artifact envelope against the current allowance.
///
/// The capture path fills `artifact.Preview` from a **compile-time** array
/// (`PREVIEW_HEAD_BYTES` + `PREVIEW_TAIL_BYTES` = 1536) inside the streaming
/// write loop - chosen before the result existed, before its size was known
/// and before any provider was consulted. Everything downstream then inherited
/// that number, because a `Receipt` carries no session root and `render` has
/// no way back to the store.
///
/// This layer holds the budget *and* `session_root`, so it is the one place
/// that can correct it: re-read the artifact and re-render at the allowance
/// the model can actually afford, or drop the envelope entirely when the
/// original now fits inline. Returns true when the item was rewritten.
fn regrowCommittedEnvelope(
    allocator: std.mem.Allocator,
    item: Item,
    config: Config,
    allowance: Allowance,
) !bool {
    if (config.session_root.len == 0) return false;
    const current = item.content.*;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, current, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;

    const identity = parseEnvelopeIdentity(object) orelse return false;
    const original_bytes = identity.original_bytes;
    const capture_complete = identity.capture_complete;
    const shown = previewShownBytes(object);

    // Re-inline whenever the whole original now fits. This is the case the
    // constant got most wrong: a result a few kilobytes long, spilled at
    // capture time, then kept as a 1.5KB preview under a budget with room for
    // all of it.
    // `original_bytes` is a Source count and `ceiling` an Encoded budget; the
    // crossing is sound because an encoded byte never costs less than the
    // source byte it came from, and re-inlining makes the content its own
    // envelope so the two are directly comparable there.
    if (capture_complete and original_bytes <= allowance.ceiling) {
        if (readWholeArtifact(allocator, config.session_root, identity.artifact_id, original_bytes)) |whole| {
            allocator.free(@constCast(current));
            item.content.* = whole;
            return true;
        } else |_| {}
    }

    const target = allowance.previewBytes();
    // The crossing has to be written down. An encoded byte never costs less
    // than the source byte it came from, so `target` encoded bytes can show at
    // most `target` source bytes - which is what makes this a sound cheap
    // pre-filter, and is precisely the reasoning that used to be implicit here
    // while `target` was silently reused as a source length below.
    const target_as_source_bound = result_budget.Source.of(target.raw());
    if (result_budget.Source.of(shown).lte(target_as_source_bound) == false) return false;

    // Read a *superset* of what can fit, for the same reason, then cut it to
    // the encoded budget in `renderEnvelopeWithPreview`. Handing the raw chunks
    // over as-is would size the preview by source length and let a quote-dense
    // or binary artifact render at up to twice the per-result budget - and a
    // committed envelope is exempt from the spill pass, so nothing downstream
    // would trim it back. One chunk per side keeps this to two reads, which
    // each re-verify the artifact's digest.
    // Each artifact read is capped below, so there is no value in carrying an
    // unbounded caller-supplied preview through the arithmetic. Clamp before
    // multiplying; otherwise a `preview_bytes = maxInt(usize)` override could
    // overflow here even though both eventual reads are only 32 KiB.
    const source_bound = @min(target_as_source_bound.raw(), artifact.MAX_READ_BYTES * 2);
    const head_read: usize = @min(source_bound / 4 * 3, artifact.MAX_READ_BYTES);
    const tail_read: usize = @min(source_bound -| head_read, artifact.MAX_READ_BYTES);
    if (head_read == 0) return false;
    var head = artifact.readChunk(allocator, config.session_root, identity.artifact_id, 0, head_read) catch return false;
    defer head.deinit();
    const tail_offset = original_bytes -| tail_read;
    var tail = if (tail_read > 0 and tail_offset >= head.bytes.len)
        artifact.readChunk(allocator, config.session_root, identity.artifact_id, tail_offset, tail_read) catch return false
    else
        null;
    defer if (tail) |*chunk| chunk.deinit();
    const tail_bytes: []const u8 = if (tail) |chunk| chunk.bytes else "";

    const utf8 = isInlineUtf8(head.bytes) and isInlineUtf8(tail_bytes);
    const rendered = try renderEnvelopeWithPreview(allocator, identity, head.bytes, tail_bytes, target, utf8);
    // Rewriting to show no more than the capture already showed is churn: it
    // burns the prompt-cache tail of this result for nothing.
    if (rendered.shown_source_bytes <= shown) {
        allocator.free(rendered.bytes);
        return false;
    }
    allocator.free(@constCast(current));
    item.content.* = rendered.bytes;
    return true;
}

/// Everything a committed artifact envelope's recovery contract depends on,
/// and nothing that depends on a budget. Re-rendering an envelope means
/// re-rendering its preview around exactly these fields.
const EnvelopeIdentity = struct {
    artifact_id: []const u8,
    media_type: []const u8,
    original_bytes: u64,
    sha256: []const u8,
    capture_complete: bool,
};

fn parseEnvelopeIdentity(object: std.json.ObjectMap) ?EnvelopeIdentity {
    const id_value = object.get("artifact_id") orelse return null;
    if (id_value != .string or !validArtifactId(id_value.string)) return null;
    const original_value = object.get("original_bytes") orelse return null;
    if (original_value != .integer or original_value.integer < 0) return null;
    const media_type = switch (object.get("media_type") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const digest = switch (object.get("sha256") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (digest.len != artifact.ID_HEX_BYTES) return null;
    const capture_complete = switch (object.get("capture_complete") orelse return null) {
        .bool => |value| value,
        else => return null,
    };
    return .{
        .artifact_id = id_value.string,
        .media_type = media_type,
        .original_bytes = @intCast(original_value.integer),
        .sha256 = digest,
        .capture_complete = capture_complete,
    };
}

/// One rendered envelope plus how many source bytes of the original its
/// preview shows, so a caller can tell a grow from a shrink without parsing
/// what it just wrote.
const RenderedEnvelope = struct { bytes: []u8, shown_source_bytes: u64 };

/// Render one artifact envelope, cutting its preview out of `head_source` and
/// `tail_source` against `budget` **encoded** bytes. The single place an
/// envelope is (re-)rendered from an identity plus two source buffers, so the
/// grow path and the shrink path cannot cut differently.
fn renderEnvelopeWithPreview(
    allocator: std.mem.Allocator,
    identity: EnvelopeIdentity,
    head_source: []const u8,
    tail_source: []const u8,
    budget: result_budget.Encoded,
    utf8: bool,
) !RenderedEnvelope {
    const base64 = !utf8;
    const head = result_budget.headCut(head_source, budget.scaled(3, 4), base64).head(head_source);
    const tail_budget = budget.minus(result_budget.encodedCost(head, base64));
    const tail = result_budget.tailCut(tail_source, tail_budget, base64).tail(tail_source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writeArtifactEnvelopeHead(
        writer,
        identity.artifact_id,
        identity.media_type,
        identity.original_bytes,
        identity.sha256,
        identity.capture_complete,
    );
    try appendPreviewParts(writer, head, tail, identity.original_bytes -| head.len -| tail.len, utf8);
    try writer.writeAll(ARTIFACT_ENVELOPE_TAIL);
    return .{ .bytes = try out.toOwnedSlice(), .shown_source_bytes = head.len + tail.len };
}

/// The preview an envelope already carries, as raw source bytes.
///
/// `preview_head`/`preview_tail` are stored in the envelope's own encoding: a
/// UTF-8 preview is the bytes themselves, a base64 preview has to be decoded
/// before it can be re-cut. Caller frees both slices with `allocator`.
const DecodedPreview = struct {
    head: []u8,
    tail: []u8,
    utf8: bool,

    fn deinit(self: DecodedPreview, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.tail);
    }
};

fn decodeEnvelopePreview(allocator: std.mem.Allocator, object: std.json.ObjectMap) ?DecodedPreview {
    const encoding = switch (object.get("preview_encoding") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const utf8 = std.mem.eql(u8, encoding, "utf-8");
    if (!utf8 and !std.mem.eql(u8, encoding, "base64")) return null;
    const head = decodePreviewPart(allocator, object.get("preview_head"), utf8) orelse return null;
    const tail = decodePreviewPart(allocator, object.get("preview_tail"), utf8) orelse {
        allocator.free(head);
        return null;
    };
    return .{ .head = head, .tail = tail, .utf8 = utf8 };
}

fn decodePreviewPart(allocator: std.mem.Allocator, value: ?std.json.Value, utf8: bool) ?[]u8 {
    const text = switch (value orelse return null) {
        .string => |string| string,
        else => return null,
    };
    if (utf8) return allocator.dupe(u8, text) catch null;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    const out = allocator.alloc(u8, size) catch return null;
    decoder.decode(out, text) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

/// Shrink any structured tool result by trimming only its long string values.
///
/// The generic text truncation is the wrong tool for a JSON result: it leaves
/// unparseable output and takes the short fields down with the long one - the
/// exit code, the storage error, the ids and flags that are what make the
/// result actionable in the first place. Those are never what makes a result
/// oversized; one or two long strings are. So the object is re-emitted with
/// its own key order, every short value verbatim, and only the long strings
/// cut to a shared water line found by binary search.
///
/// Counters that describe a trimmed string are corrected as the object is
/// re-emitted.  The source JSON is allowed to use any object key order, so
/// metadata is collected in a first pass instead of relying on a producer's
/// canonical ordering (`stdout` before `stdout_truncated`, etc.).
/// Whether this result is JSON at all - an object, but also a top-level array
/// or scalar, which tools do return. The generic text truncation is only ever
/// safe for content that was not structured to begin with: applied to any of
/// these it emits something no consumer can parse, and the schema is not
/// recoverable from the wreck.
pub fn isStructuredObject(content: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    return true;
}

pub fn shrinkStructuredResult(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_bytes: usize,
) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    // Emitted size is monotone in the water line, so the largest one that fits
    // is a binary search. `low` is always known-feasible once set.
    var best: ?[]u8 = null;
    errdefer if (best) |bytes| allocator.free(bytes);
    var low: usize = 0;
    var high: usize = max_bytes;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const rendered = renderTrimmedRoot(allocator, parsed.value, mid) catch break;
        if (rendered.len <= max_bytes) {
            if (best) |bytes| allocator.free(bytes);
            best = rendered;
            low = mid + 1;
        } else {
            allocator.free(rendered);
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    const out = best orelse return null;
    if (out.len >= content.len) {
        allocator.free(out);
        return null;
    }
    return out;
}

/// Bookkeeping a trim invalidates, corrected as the object is written.
///
/// Both envelope families put a string before the counters that describe it
/// (`preview_head` before `preview_head_bytes`, `stdout` before
/// `stdout_truncated`) and `original_bytes` before all of them, so one pass in
/// key order can fix every one. A counter left describing the pre-trim string
/// is the same quiet lie as an envelope that claims to be intact.
const TrimLedger = struct {
    original_bytes: ?u64 = null,
    head_shown: ?result_budget.Source = null,
    tail_shown: ?result_budget.Source = null,
    trimmed_stdout: bool = false,
    trimmed_stderr: bool = false,
    /// Whether `preview_head`/`preview_tail` hold base64 rather than the bytes
    /// themselves. Two consequences, and the counters are the lesser one: a
    /// base64 field cut into head + marker + tail is not base64 any more and
    /// no consumer can decode it.
    preview_base64: bool = false,

    /// `omitted_bytes` is only recomputable once both preview counters are
    /// known, and it must satisfy head + tail + omitted == original or the
    /// envelope reports an elision size that is not the truth.
    fn omitted(self: TrimLedger) ?u64 {
        const original = self.original_bytes orelse return null;
        const head = self.head_shown orelse return null;
        const tail = self.tail_shown orelse return null;
        return original -| head.raw() -| tail.raw();
    }
};

/// Only a top-level object carries the counter conventions worth correcting;
/// an array or scalar is trimmed by the same recursion without them.
fn renderTrimmedRoot(allocator: std.mem.Allocator, value: std.json.Value, water: usize) ![]u8 {
    if (value == .object) return renderTrimmedObject(allocator, value.object, water);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeTrimmedValue(&out.writer, value, water);
    return out.toOwnedSlice();
}

/// Re-emit one JSON object, cutting every string longer than `water` - at any
/// depth - to a head/tail around `PREVIEW_ELISION`. Key order is preserved
/// because `std.json.ObjectMap` is an array hash map, which is what lets the
/// counter correction be a single pass.
fn renderTrimmedObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    water: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');

    // Collect all fields that counters may refer to before writing anything.
    // ObjectMap preserves insertion order, but input JSON does not promise the
    // canonical order produced by our own envelopes.
    var ledger = TrimLedger{};
    var metadata = object.iterator();
    while (metadata.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value == .integer and value.integer >= 0 and std.mem.eql(u8, key, "original_bytes"))
            ledger.original_bytes = @intCast(value.integer);
        if (value == .string and std.mem.eql(u8, key, "preview_encoding"))
            ledger.preview_base64 = std.mem.eql(u8, value.string, "base64");
    }
    var preview = object.iterator();
    while (preview.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value != .string) continue;
        if (std.mem.eql(u8, key, "preview_head")) {
            ledger.head_shown = trimmedStringSource(value.string, water, ledger.preview_base64);
        } else if (std.mem.eql(u8, key, "preview_tail")) {
            ledger.tail_shown = trimmedStringSource(value.string, water, ledger.preview_base64);
        } else if (value.string.len > water and std.mem.eql(u8, key, "stdout")) {
            ledger.trimmed_stdout = true;
        } else if (value.string.len > water and std.mem.eql(u8, key, "stderr")) {
            ledger.trimmed_stderr = true;
        }
    }

    var first = true;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (!first) try writer.writeByte(',');
        first = false;
        const key = entry.key_ptr.*;
        try util_json.writeJsonString(writer, key);
        try writer.writeByte(':');

        const value = entry.value_ptr.*;
        if (value == .string) {
            const is_preview = std.mem.eql(u8, key, "preview_head") or
                std.mem.eql(u8, key, "preview_tail");
            // A base64 preview must stay decodable, so it is cut to a prefix on
            // a four-character boundary with no marker spliced in, and its
            // counter is the *decoded* length - the unit `original_bytes` and
            // `omitted_bytes` are in.
            const base64_field = is_preview and ledger.preview_base64;
            if (value.string.len > water) {
                _ = try writeTrimmedString(writer, value.string, water, base64_field);
            } else {
                try util_json.writeJsonString(writer, value.string);
            }
            continue;
        }

        // Counters whose subject this pass has already written.
        if (ledger.head_shown != null and std.mem.eql(u8, key, "preview_head_bytes")) {
            try writer.print("{d}", .{ledger.head_shown.?.raw()});
            continue;
        }
        if (ledger.tail_shown != null and std.mem.eql(u8, key, "preview_tail_bytes")) {
            try writer.print("{d}", .{ledger.tail_shown.?.raw()});
            continue;
        }
        if (std.mem.eql(u8, key, "omitted_bytes")) {
            if (ledger.omitted()) |value_out| {
                try writer.print("{d}", .{value_out});
                continue;
            }
        }
        if ((ledger.trimmed_stdout and std.mem.eql(u8, key, "stdout_truncated")) or
            (ledger.trimmed_stderr and std.mem.eql(u8, key, "stderr_truncated")))
        {
            try writer.writeAll("true");
            continue;
        }
        try writeTrimmedValue(writer, value, water);
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Trim strings wherever they are, not only at the top level. A result shaped
/// `{"rows":[{"text": <40KB> }]}` has no long top-level string at all, and
/// leaving it untrimmed sent it to the text truncation that destroys the JSON.
/// Non-string leaves are emitted verbatim: their type is part of the schema.
fn writeTrimmedValue(writer: *std.Io.Writer, value: std.json.Value, water: usize) !void {
    switch (value) {
        .string => |text| {
            if (text.len > water) {
                _ = try writeTrimmedString(writer, text, water, false);
            } else {
                try util_json.writeJsonString(writer, text);
            }
        },
        .array => |items| {
            try writer.writeByte('[');
            for (items.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeTrimmedValue(writer, item, water);
            }
            try writer.writeByte(']');
        },
        .object => |nested| {
            try writer.writeByte('{');
            var first = true;
            var it = nested.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try util_json.writeJsonString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try writeTrimmedValue(writer, entry.value_ptr.*, water);
            }
            try writer.writeByte('}');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

const PREVIEW_ELISION = "\n...[trimmed to fit context]...\n";

/// Decoded length of a base64 string, which is the unit its sibling counters
/// are written in.
/// A base64 string is `Encoded`; what it decodes to is `Source`. Writing the
/// character count into a counter documented as original bytes overstated it
/// by a third, and the head+tail+omitted invariant still held because all three
/// were wrong in the same unit.
fn base64DecodedLen(text: []const u8) result_budget.Source {
    return result_budget.Source.of(std.base64.standard.Decoder.calcSizeForSlice(text) catch text.len / 4 * 3);
}

/// Return the source-byte count that `writeTrimmedString` will keep without
/// writing anything.  This lets the counter ledger be computed independently
/// of object key order.
fn trimmedStringSource(source: []const u8, water: usize, base64: bool) result_budget.Source {
    if (source.len <= water)
        return if (base64) base64DecodedLen(source) else result_budget.Source.of(source.len);
    if (base64) {
        const chars = @min(water, source.len) / 4 * 4;
        return base64DecodedLen(source[0..chars]);
    }
    if (water <= PREVIEW_ELISION.len) {
        return result_budget.Source.of(alignedCut(source, @min(water, source.len)));
    }
    const budget = water - PREVIEW_ELISION.len;
    const head_len = alignedCut(source, budget * 3 / 4);
    const want_tail = budget -| head_len;
    const tail_start = source.len - alignedCut(source[head_len..], want_tail);
    return result_budget.Source.of(head_len + (source.len - tail_start));
}

/// Write `source` cut to roughly `water` bytes and return how many bytes of the
/// *original* it still shows.
///
/// `base64` mode keeps a prefix only: splicing an elision marker between two
/// base64 runs produces a field that is no longer base64, so nothing can decode
/// it - losing the tail is the cheaper half of that trade. The returned count
/// is decoded bytes, so it stays comparable with `original_bytes`.
fn writeTrimmedString(writer: *std.Io.Writer, source: []const u8, water: usize, base64: bool) !result_budget.Source {
    if (base64) {
        const chars = @min(water, source.len) / 4 * 4;
        try util_json.writeJsonString(writer, source[0..chars]);
        return base64DecodedLen(source[0..chars]);
    }
    if (water <= PREVIEW_ELISION.len) {
        const head = alignedCut(source, @min(water, source.len));
        try util_json.writeJsonString(writer, source[0..head]);
        return result_budget.Source.of(head);
    }
    const budget = water - PREVIEW_ELISION.len;
    const head_len = alignedCut(source, budget * 3 / 4);
    const want_tail = budget -| head_len;
    const tail_start = source.len - alignedCut(source[head_len..], want_tail);
    try writer.writeByte('"');
    try writeJsonStringBody(writer, source[0..head_len]);
    try writeJsonStringBody(writer, PREVIEW_ELISION);
    try writeJsonStringBody(writer, source[tail_start..]);
    try writer.writeByte('"');
    return result_budget.Source.of(head_len + (source.len - tail_start));
}

/// `encodeJsonString` writes its own quotes; a three-part string has to share
/// one pair, so the body is escaped directly.
fn writeJsonStringBody(writer: *std.Io.Writer, bytes: []const u8) !void {
    try util_json.writeJsonStringContents(writer, bytes);
}

/// Longest prefix of `source` at most `desired` bytes that is safe to cut at:
/// a UTF-8 boundary always, and a multiple of four when the string is all
/// ASCII, so base64 keeps decoding to the same bytes.
fn alignedCut(source: []const u8, desired: usize) usize {
    const end = result_budget.floorUtf8Boundary(source, @min(desired, source.len));
    if (end == source.len) return end;
    for (source[0..end]) |byte| {
        if (byte >= 0x80) return end;
    }
    return end - (end % 4);
}

/// Re-render a committed artifact envelope so the whole envelope fits
/// `max_bytes`, keeping every identity field and shrinking only the preview.
///
/// The Conversation-level pressure valves bound results that entered under a
/// different budget, and their generic head/tail truncation is a *text* edit:
/// applied to an envelope it produces unparseable JSON, which destroys the
/// artifact id, the digest and the read instruction - the only way the omitted
/// bytes can ever be recovered. `clearToolResultAt` already refuses to erase
/// that capability; this is how the truncation pass keeps the same promise
/// while still doing its job. No store access: the preview is re-cut from the
/// one the envelope already carries.
///
/// Returns null when the content is not an envelope this can rewrite, or when
/// even a minimal envelope would not fit - the caller must then leave the
/// result alone rather than mangle it.
pub fn shrinkRecoverableEnvelope(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_bytes: usize,
) ?[]u8 {
    if (!isRecoverableEnvelope(content) or content.len <= max_bytes) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const identity = parseEnvelopeIdentity(parsed.value.object) orelse return null;
    const preview = decodeEnvelopePreview(allocator, parsed.value.object) orelse return null;
    defer preview.deinit(allocator);

    const rendered = renderEnvelopeWithPreview(
        allocator,
        identity,
        preview.head,
        preview.tail,
        result_budget.Encoded.of(max_bytes).minus(ENVELOPE_OVERHEAD_BYTES),
        preview.utf8,
    ) catch return null;
    // The overhead constant is a measured round-up, not a proof. A media type
    // long enough to break it means this cannot shrink the result at all, and
    // saying so is better than returning something over the limit.
    if (rendered.bytes.len > max_bytes or rendered.bytes.len >= content.len) {
        allocator.free(rendered.bytes);
        return null;
    }
    return rendered.bytes;
}

fn previewShownBytes(object: std.json.ObjectMap) u64 {
    var shown: u64 = 0;
    for ([_][]const u8{ "preview_head_bytes", "preview_tail_bytes" }) |key| {
        const value = object.get(key) orelse continue;
        if (value == .integer and value.integer > 0) shown +|= @intCast(value.integer);
    }
    return shown;
}

/// `readChunk` is capped at `MAX_READ_BYTES` per call, so a re-inline of an
/// original larger than one chunk is stitched from successive reads. Bounded
/// by `Allowance.ceiling`, which never exceeds `PER_RESULT_MAX_BYTES`.
fn readWholeArtifact(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    artifact_id: []const u8,
    original_bytes: u64,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, @intCast(original_bytes));
    errdefer out.deinit(allocator);
    var offset: u64 = 0;
    while (offset < original_bytes) {
        const want: usize = @intCast(@min(original_bytes - offset, artifact.MAX_READ_BYTES));
        var chunk = try artifact.readChunk(allocator, session_root, artifact_id, offset, want);
        defer chunk.deinit();
        if (chunk.bytes.len == 0) return error.ArtifactChangedDuringRead;
        try out.appendSlice(allocator, chunk.bytes);
        offset += chunk.bytes.len;
    }
    return out.toOwnedSlice(allocator);
}

fn spillOne(
    allocator: std.mem.Allocator,
    item: Item,
    structured: bool,
    config: Config,
    stats: *Stats,
    preview_bytes: result_budget.Encoded,
    turn_budget: bool,
) !void {
    const original = item.content.*;
    const media_type = if (structured) "application/json" else "text/plain; charset=utf-8";
    const persisted = artifact.persist(allocator, config.session_root, original);
    const replacement = if (persisted) |stored| blk: {
        stats.artifact_spill_count += 1;
        stats.artifact_bytes +|= original.len;
        break :blk try renderArtifactEnvelope(allocator, stored, media_type, original, preview_bytes);
    } else |persist_error| blk: {
        if (persist_error == error.OutOfMemory) return error.OutOfMemory;
        stats.unrecoverable_fallback_count += 1;
        if (structured) stats.structured_projection_failures += 1;
        break :blk try renderFallbackEnvelope(allocator, media_type, original, preview_bytes, artifact.storageErrorCode(persist_error));
    };
    allocator.free(@constCast(original));
    item.content.* = replacement;
    if (turn_budget) stats.turn_budget_spills += 1;
}

fn renderArtifactEnvelope(
    allocator: std.mem.Allocator,
    receipt: artifact.Receipt,
    media_type: []const u8,
    content: []const u8,
    preview_bytes: result_budget.Encoded,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writeArtifactEnvelopeHead(writer, receipt.id(), media_type, receipt.bytes, receipt.sha256[0..], true);
    try appendPreview(writer, content, preview_bytes);
    try writer.writeAll(ARTIFACT_ENVELOPE_TAIL);
    return out.toOwnedSlice();
}

const ARTIFACT_ENVELOPE_TAIL = ",\"read\":{\"tool\":\"ReadArtifact\",\"offset\":0,\"limit_max\":32768}}";

fn writeArtifactEnvelopeHead(
    writer: *std.Io.Writer,
    artifact_id: []const u8,
    media_type: []const u8,
    original_bytes: u64,
    sha256_hex: []const u8,
    capture_complete: bool,
) !void {
    try writer.writeAll(ENVELOPE_PREFIX ++ "\"artifact\",\"artifact_id\":");
    try util_json.writeJsonString(writer, artifact_id);
    try writer.writeAll(",\"media_type\":");
    try util_json.writeJsonString(writer, media_type);
    try writer.print(",\"original_bytes\":{d},\"sha256\":\"{s}\",\"capture_complete\":{s},\"recoverable\":true", .{
        original_bytes,
        sha256_hex,
        if (capture_complete) "true" else "false",
    });
}

fn renderFallbackEnvelope(
    allocator: std.mem.Allocator,
    media_type: []const u8,
    content: []const u8,
    preview_bytes: result_budget.Encoded,
    storage_error: []const u8,
) ![]u8 {
    const digest = artifact.sha256Hex(content);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(ENVELOPE_PREFIX ++ "\"fallback\",\"artifact_id\":null,\"media_type\":");
    try util_json.writeJsonString(writer, media_type);
    try writer.print(",\"original_bytes\":{d},\"sha256\":\"{s}\",\"capture_complete\":true,\"recoverable\":false,\"storage_error\":", .{ content.len, digest[0..] });
    try util_json.writeJsonString(writer, storage_error);
    try appendPreview(writer, content, preview_bytes);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn appendPreview(writer: *std.Io.Writer, content: []const u8, preview_bytes: result_budget.Encoded) !void {
    const valid_utf8 = isInlineUtf8(content);
    // `preview_bytes` is an encoded budget. Cutting on source length would let
    // a quote- or newline-dense result render at up to twice the size it was
    // sized against, so the head/tail cuts are chosen by encoded cost. The
    // base64 branch has no escapes but expands 4:3, which the same accounting
    // covers by converting the budget back into source bytes.
    const base64 = !valid_utf8;
    const head_cut = result_budget.headCut(content, preview_bytes.scaled(3, 4), base64);
    const head = head_cut.head(content);
    const remaining = head_cut.rest(content);
    const tail = result_budget.tailCut(remaining, preview_bytes.minus(result_budget.encodedCost(head, base64)), base64).tail(remaining);
    try appendPreviewParts(writer, head, tail, content.len - head.len - tail.len, valid_utf8);
}

fn appendPreviewParts(
    writer: *std.Io.Writer,
    head: []const u8,
    tail: []const u8,
    omitted: u64,
    valid_utf8: bool,
) !void {
    try writer.writeAll(if (valid_utf8) ",\"preview_encoding\":\"utf-8\"" else ",\"preview_encoding\":\"base64\"");
    try writer.writeAll(",\"preview_head\":");
    try appendPreviewPart(writer, head, valid_utf8);
    try writer.writeAll(",\"preview_tail\":");
    try appendPreviewPart(writer, tail, valid_utf8);
    try writer.print(",\"preview_head_bytes\":{d},\"preview_tail_bytes\":{d},\"omitted_bytes\":{d}", .{
        head.len,
        tail.len,
        omitted,
    });
}

fn appendPreviewPart(writer: *std.Io.Writer, bytes: []const u8, utf8: bool) !void {
    if (utf8) return util_json.writeJsonString(writer, bytes);
    const encoder = std.base64.standard.Encoder;
    const encoded = try std.heap.page_allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer std.heap.page_allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);
    try util_json.writeJsonString(writer, encoded);
}

fn isInlineUtf8(content: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(content)) return false;
    for (content) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') return false;
    }
    return true;
}

/// Whether the **tool** emitted a structured body.
///
/// Asking `isStructuredJson` directly gets this wrong in both directions once
/// the tool layer publishes. A projection envelope is a JSON document, so a
/// plain-text Grep result wrapped in one counted as structured; excluding every
/// envelope instead lost the opposite case, a WebFetch JSON body that the tool
/// layer published - the envelope is the wrapper, and what it wraps is recorded
/// in its own `media_type`. So: for an envelope, believe its media type; for
/// anything else, look at the bytes.
fn toolEmittedStructured(content: []const u8) bool {
    if (!isProjectionEnvelope(content)) return isStructuredJson(content);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const media = parsed.value.object.get("media_type") orelse return false;
    if (media != .string) return false;
    return std.mem.startsWith(u8, media.string, "application/json");
}

fn isStructuredJson(content: []const u8) bool {
    var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, content);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return false;
        if (token == .end_of_document) return true;
    }
}

fn accountedTotal(items: []const Item) usize {
    var total: usize = 0;
    for (items) |item| total +|= accountedBytes(item.content.*);
    return total;
}

fn literalTotal(items: []const Item) usize {
    var total: usize = 0;
    for (items) |item| total +|= item.content.*.len;
    return total;
}

test "structured spill remains valid JSON and exposes no local path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    // Comfortably past the envelope scaffolding, so spilling is actually the
    // cheaper representation; a payload smaller than the envelope is now left
    // inline on purpose.
    const padding = try allocator.alloc(u8, 4096);
    defer allocator.free(padding);
    @memset(padding, 'x');
    var content: []const u8 = try std.fmt.allocPrint(allocator, "{{\"rows\":[1,2,3],\"padding\":\"{s}\"}}", .{padding});
    var items = [_]Item{.{ .tool_name = "KgContext", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{ .session_root = root, .budget = .{ .per_result_bytes = 16, .per_turn_bytes = 8192 } });
    defer allocator.free(@constCast(content));
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);
    try std.testing.expect(isRecoverableEnvelope(content));
    try std.testing.expect(std.mem.indexOf(u8, content, root) == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("application/json", parsed.value.object.get("media_type").?.string);
}

test "projection preview preserves deterministic UTF-8 head and tail" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const filler = try allocator.alloc(u8, 4096);
    defer allocator.free(filler);
    @memset(filler, 'm');
    var content: []const u8 = try std.fmt.allocPrint(allocator, "HEAD-中文-{s}-TAIL🙂", .{filler});
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};
    _ = try project(allocator, &items, .{ .session_root = root, .budget = .{ .per_result_bytes = 8, .per_turn_bytes = 8192 }, .preview_bytes = 36 });
    defer allocator.free(@constCast(content));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("utf-8", parsed.value.object.get("preview_encoding").?.string);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.object.get("preview_head").?.string, "HEAD-"));
    try std.testing.expect(std.mem.endsWith(u8, parsed.value.object.get("preview_tail").?.string, "TAIL🙂"));
    try std.testing.expect(parsed.value.object.get("omitted_bytes").?.integer > 0);
}

test "recoverable artifact detection includes Bash channel envelopes" {
    const id = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const bash = "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout_artifact_id\":\"" ++ id ++ "\",\"stdout_recoverable\":true}";
    try std.testing.expect(hasRecoverableArtifact(bash));
    try std.testing.expect(!hasRecoverableArtifact("{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout_artifact_id\":null,\"stdout_recoverable\":false}"));
}

test "missing store yields an explicit valid fallback envelope" {
    const allocator = std.testing.allocator;
    const padding = try allocator.alloc(u8, 4096);
    defer allocator.free(padding);
    @memset(padding, 'x');
    var content: []const u8 = try std.fmt.allocPrint(allocator, "{{\"large\":true,\"padding\":\"{s}\"}}", .{padding});
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{ .session_root = "", .budget = .{ .per_result_bytes = 8, .per_turn_bytes = 8192 } });
    defer allocator.free(@constCast(content));
    try std.testing.expectEqual(@as(usize, 1), stats.unrecoverable_fallback_count);
    try std.testing.expectEqual(@as(usize, 1), stats.structured_projection_failures);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("recoverable").?.bool);
    try std.testing.expectEqualStrings("artifact_store_unavailable", parsed.value.object.get("storage_error").?.string);
}

test "error payloads remain exact even when they exceed projection budgets" {
    const allocator = std.testing.allocator;
    var content: []const u8 = try allocator.dupe(u8, "{\"error\":{\"code\":\"retry_with_offset\",\"detail\":\"exact\"}}");
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "Read", .content = &content, .is_error = true }};
    const before = try allocator.dupe(u8, content);
    defer allocator.free(before);
    const stats = try project(allocator, &items, .{ .session_root = "", .budget = .{ .per_result_bytes = 8, .per_turn_bytes = 8 } });
    try std.testing.expectEqualStrings(before, content);
    try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
    try std.testing.expect(stats.budget_exhausted);
}

test "turn pressure trims every oversized result to one water line" {
    // The old pass evicted the single largest result and left its equals
    // untouched, so an equal-size pair needed an ordinal tie-break to stay
    // deterministic. Water-filling has no victim: both results above the line
    // are trimmed to the same ceiling, which is both fairer and deterministic
    // without a tie-break rule.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var first: []const u8 = try allocator.alloc(u8, 16 * 1024);
    @memset(@constCast(first), 'A');
    defer allocator.free(@constCast(first));
    var second: []const u8 = try allocator.alloc(u8, 16 * 1024);
    @memset(@constCast(second), 'B');
    defer allocator.free(@constCast(second));
    var items = [_]Item{
        .{ .tool_name = "A", .content = &first, .is_error = false },
        .{ .tool_name = "B", .content = &second, .is_error = false },
    };
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 64 * 1024, .per_turn_bytes = 4096 },
        .preview_bytes = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.turn_budget_spills);
    try std.testing.expect(isRecoverableEnvelope(first));
    try std.testing.expect(isRecoverableEnvelope(second));
    try std.testing.expectEqual(first.len, second.len);
}

test "a result the envelope cannot shrink is left inline" {
    // issue #29: between the preview size and preview+scaffolding, spilling
    // costs *more* bytes than it saves and destroys content at the same time.
    // The planner must refuse rather than merely be unlikely to choose it.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var content: []const u8 = try allocator.alloc(u8, ENVELOPE_OVERHEAD_BYTES.raw() - 1);
    @memset(@constCast(content), 'S');
    defer allocator.free(@constCast(content));
    const before = content;
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{
        .session_root = root,
        // Both budgets are far below the result: under the old rules it would
        // be spilled twice over.
        .budget = .{ .per_result_bytes = 8, .per_turn_bytes = 8 },
        .preview_bytes = 0,
    });
    try std.testing.expectEqual(before.ptr, content.ptr);
    try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, 0), stats.turn_budget_spills);
    // The budget genuinely cannot be met; that is reported rather than
    // papered over with a spill that would make the request bigger.
    try std.testing.expect(stats.budget_exhausted);
}

/// Image tool result whose base64 payload is well past every production
/// `per_result_bytes` cap (8..64 KB). Caller frees.
fn testImageResult(allocator: std.mem.Allocator, data_bytes: usize) ![]const u8 {
    const data = try allocator.alloc(u8, data_bytes);
    defer allocator.free(data);
    @memset(data, 'A');
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}",
        .{data},
    );
}

test "image results survive the per-result pass regardless of byte length" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var image: []const u8 = try testImageResult(allocator, 96 * 1024);
    defer allocator.free(@constCast(image));
    const original = try allocator.dupe(u8, image);
    defer allocator.free(original);
    var items = [_]Item{.{ .tool_name = "Read", .content = &image, .is_error = false }};
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 64 * 1024, .per_turn_bytes = 200 * 1024 },
    });
    try std.testing.expectEqualStrings(original, image);
    try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, 1), stats.image_exempt_count);
    // Byte metrics stay literal and unchanged (nothing was rewritten) while the
    // budget decision uses the vision token estimate, not the base64 size —
    // 96 KB of payload against a 200 KB turn budget is not exhaustion.
    try std.testing.expectEqual(image.len, stats.projected_bytes);
    try std.testing.expectEqual(stats.raw_bytes, stats.projected_bytes);
    try std.testing.expect(!stats.budget_exhausted);
}

test "turn budget spills text before it ever considers an image" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // The image is by far the largest item, so a byte-length victim search
    // would pick it first; only the carve-out makes the text the victim.
    var image: []const u8 = try testImageResult(allocator, 96 * 1024);
    defer allocator.free(@constCast(image));
    const image_original = try allocator.dupe(u8, image);
    defer allocator.free(image_original);
    var text: []const u8 = try allocator.alloc(u8, 32 * 1024);
    @memset(@constCast(text), 'T');
    defer allocator.free(@constCast(text));
    var items = [_]Item{
        .{ .tool_name = "Read", .content = &image, .is_error = false },
        .{ .tool_name = "Grep", .content = &text, .is_error = false },
    };
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 64 * 1024, .per_turn_bytes = 16 * 1024 },
        .preview_bytes = 0,
    });
    try std.testing.expectEqualStrings(image_original, image);
    try std.testing.expectEqual(@as(usize, 1), stats.turn_budget_spills);
    try std.testing.expect(isRecoverableEnvelope(text));
}

test "a spilled preview fills the budget instead of a fixed 1536 bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var content: []const u8 = try allocator.alloc(u8, 256 * 1024);
    @memset(@constCast(content), 'W');
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "Grep", .content = &content, .is_error = false }};
    const budget = result_budget.Budget.fromModel(200_000);
    const stats = try project(allocator, &items, .{ .session_root = root, .budget = budget });
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);
    try std.testing.expect(isRecoverableEnvelope(content));

    // Spilling means the content exceeded the allowance, not that the
    // allowance disappeared: the preview keeps essentially the whole budget.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const shown = parsed.value.object.get("preview_head_bytes").?.integer +
        parsed.value.object.get("preview_tail_bytes").?.integer;
    try std.testing.expect(shown > 16 * 1024);
    // And the rendered envelope still fits the budget it was derived from.
    try std.testing.expect(content.len <= budget.per_result_bytes);
}

/// Build a committed artifact envelope exactly the way the streaming capture
/// path does: `Spool.write` fills a compile-time `Preview` array as bytes go
/// past, and `render` emits that fixed-size preview. Caller frees.
fn captureTimeEnvelope(allocator: std.mem.Allocator, root: []const u8, payload: []const u8) ![]u8 {
    var spool = try artifact.Spool.begin(allocator, root);
    defer spool.deinit();
    try spool.write(payload);
    var body = tool_result.ToolResultBody.fromCompletedSpool(try spool.finish(), .text_utf8);
    defer body.deinit(allocator);
    var rendered = try body.render(allocator);
    defer rendered.deinit(allocator);
    return allocator.dupe(u8, rendered.bytes);
}

test "a capture-time envelope small enough for the budget is re-inlined" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 4096);
    defer allocator.free(payload);
    @memset(payload, 'P');
    payload[0] = 'H';
    payload[payload.len - 1] = 'T';

    var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
    defer allocator.free(@constCast(content));
    // The capture path shows 1536 of the 4096 bytes, decided by a compile-time
    // array size while the bytes were still streaming to disk.
    try std.testing.expect(isRecoverableEnvelope(content));
    try std.testing.expect(content.len < payload.len);

    var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = result_budget.Budget.fromModel(200_000),
    });
    // 4KB against a 25KB budget: there was never a reason to elide anything.
    try std.testing.expectEqual(@as(usize, 1), stats.envelope_regrown_count);
    try std.testing.expectEqual(@as(usize, 1), stats.envelope_reinlined_count);
    try std.testing.expectEqualStrings(payload, content);
}

test "an oversized capture-time envelope keeps its receipt and grows its preview" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'L');
    payload[payload.len - 1] = 'Z';

    var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
    defer allocator.free(@constCast(content));
    var before = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    const capture_shown = before.value.object.get("preview_head_bytes").?.integer +
        before.value.object.get("preview_tail_bytes").?.integer;
    before.deinit();
    try std.testing.expectEqual(
        @as(i64, @intCast(artifact.PREVIEW_HEAD_BYTES + artifact.PREVIEW_TAIL_BYTES)),
        capture_shown,
    );

    var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
    const budget = result_budget.Budget.fromModel(200_000);
    const stats = try project(allocator, &items, .{ .session_root = root, .budget = budget });
    try std.testing.expectEqual(@as(usize, 1), stats.envelope_regrown_count);
    try std.testing.expectEqual(@as(usize, 0), stats.envelope_reinlined_count);
    // Still recoverable, still bounded, but the model now sees an order of
    // magnitude more of it - and the tail is preserved.
    try std.testing.expect(isRecoverableEnvelope(content));
    try std.testing.expect(content.len <= budget.per_result_bytes);
    var after = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer after.deinit();
    const shown = after.value.object.get("preview_head_bytes").?.integer +
        after.value.object.get("preview_tail_bytes").?.integer;
    try std.testing.expect(shown > capture_shown * 8);
    try std.testing.expect(std.mem.endsWith(u8, after.value.object.get("preview_tail").?.string, "Z"));
    try std.testing.expectEqual(@as(i64, 256 * 1024), after.value.object.get("original_bytes").?.integer);
}

test "unbounded preview override cannot overflow artifact re-render arithmetic" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'Q');
    var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};

    // `preview_bytes` is an embedders' override. Even an absurd value must be
    // clamped before read-size arithmetic rather than wrapping usize.
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = result_budget.Budget.fromModel(200_000),
        .preview_bytes = std.math.maxInt(usize),
    });
    try std.testing.expectEqual(@as(usize, 1), stats.envelope_regrown_count);
    try std.testing.expect(isRecoverableEnvelope(content));
}

test "raw_bytes bills a Bash envelope by what its channels captured" {
    const allocator = std.testing.allocator;
    var content: []const u8 = try allocator.dupe(
        u8,
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"head...tail\"," ++
            "\"stdout_captured_bytes\":40009,\"stderr_captured_bytes\":12,\"exit_code\":0}",
    );
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "Bash", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{
        .session_root = "",
        .budget = result_budget.Budget.fromModel(200_000),
    });
    // Not the ~120-byte envelope: what the command actually produced.
    try std.testing.expectEqual(@as(usize, 40_021), stats.raw_bytes);
}

test "a re-rendered committed envelope stays inside the budget in every encoding" {
    // The regrow path reads the artifact back and re-renders the preview. It
    // has to spend the same **encoded** budget the spill path does: an
    // escape-dense or binary artifact cut by source length renders at up to
    // twice the per-result budget, and a committed envelope is exempt from the
    // spill pass, so nothing downstream would trim it back.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const budget = result_budget.Budget.fromModel(200_000);

    // quote: every byte escapes to two. 0x01: not inline-safe, so the preview
    // is base64 and expands 4:3. 'L': the one-to-one control case.
    for ([_]u8{ '"', '\n', 0x01, 'L' }) |fill| {
        const payload = try allocator.alloc(u8, 256 * 1024);
        defer allocator.free(payload);
        @memset(payload, fill);
        var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
        defer allocator.free(@constCast(content));
        var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
        const stats = try project(allocator, &items, .{ .session_root = root, .budget = budget });
        try std.testing.expectEqual(@as(usize, 1), stats.envelope_regrown_count);
        try std.testing.expect(isRecoverableEnvelope(content));
        try std.testing.expect(content.len <= budget.per_result_bytes);
        // Still a real preview, not a degenerate one traded for the bound.
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        const shown = parsed.value.object.get("preview_head_bytes").?.integer +
            parsed.value.object.get("preview_tail_bytes").?.integer;
        try std.testing.expect(shown > artifact.PREVIEW_HEAD_BYTES + artifact.PREVIEW_TAIL_BYTES);
    }
}

test "a re-inline the turn cannot afford is never performed" {
    // Two committed envelopes, each small enough to inline against the
    // per-result budget but not both against the turn budget. Deciding the
    // re-inline against the uncapped allowance read both artifacts back,
    // inlined them, and spilled both to the same artifacts again in the same
    // pass - reporting `envelope_reinlined_count=2` (documented as "returned
    // to the model in full") beside `artifact_spill_count=2` for the same two
    // results.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload_a = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(payload_a);
    @memset(payload_a, 'A');
    const payload_b = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(payload_b);
    @memset(payload_b, 'B');

    var first: []const u8 = try captureTimeEnvelope(allocator, root, payload_a);
    defer allocator.free(@constCast(first));
    var second: []const u8 = try captureTimeEnvelope(allocator, root, payload_b);
    defer allocator.free(@constCast(second));
    var items = [_]Item{
        .{ .tool_name = "A", .content = &first, .is_error = false },
        .{ .tool_name = "B", .content = &second, .is_error = false },
    };
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 25_000, .per_turn_bytes = 16 * 1024 },
    });
    try std.testing.expectEqual(@as(usize, 0), stats.envelope_reinlined_count);
    // `artifact_spill_count` also counts envelopes that arrived as envelopes,
    // so the signal for "this pass spilled something" is `turn_budget_spills`.
    try std.testing.expectEqual(@as(usize, 0), stats.turn_budget_spills);
    // Both stay recoverable envelopes, and the pair fits the turn budget.
    try std.testing.expect(isRecoverableEnvelope(first));
    try std.testing.expect(isRecoverableEnvelope(second));
    try std.testing.expect(first.len + second.len <= 16 * 1024);

    // A turn with room for it still gets the full re-inline.
    var third: []const u8 = try captureTimeEnvelope(allocator, root, payload_a);
    defer allocator.free(@constCast(third));
    var roomy = [_]Item{.{ .tool_name = "A", .content = &third, .is_error = false }};
    const roomy_stats = try project(allocator, &roomy, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 25_000, .per_turn_bytes = 200 * 1024 },
    });
    try std.testing.expectEqual(@as(usize, 1), roomy_stats.envelope_reinlined_count);
    try std.testing.expectEqualStrings(payload_a, third);
}

test "shrinkRecoverableEnvelope keeps every identity field and rewrites the counters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // Both preview encodings: a base64 preview has to be decoded before it can
    // be re-cut, and re-encoded after.
    for ([_]u8{ 'S', 0x01 }) |fill| {
        const payload = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(payload);
        @memset(payload, fill);
        var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
        defer allocator.free(@constCast(content));
        var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
        _ = try project(allocator, &items, .{
            .session_root = root,
            .budget = result_budget.Budget.fromModel(200_000),
        });
        try std.testing.expect(isRecoverableEnvelope(content));

        var before = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer before.deinit();
        const target = content.len / 3;
        const shrunk = shrinkRecoverableEnvelope(allocator, content, target) orelse
            return error.ShrinkRefused;
        defer allocator.free(shrunk);
        try std.testing.expect(shrunk.len <= target);
        try std.testing.expect(isRecoverableEnvelope(shrunk));
        try std.testing.expect(hasRecoverableArtifact(shrunk));

        var after = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
        defer after.deinit();
        for ([_][]const u8{ "artifact_id", "media_type", "sha256", "preview_encoding" }) |key| {
            try std.testing.expectEqualStrings(
                before.value.object.get(key).?.string,
                after.value.object.get(key).?.string,
            );
        }
        try std.testing.expectEqual(
            before.value.object.get("original_bytes").?.integer,
            after.value.object.get("original_bytes").?.integer,
        );
        try std.testing.expect(after.value.object.get("recoverable").?.bool);
        try std.testing.expect(after.value.object.get("read").? == .object);
        // The counters describe the new preview, not the one it replaced.
        const before_shown = before.value.object.get("preview_head_bytes").?.integer +
            before.value.object.get("preview_tail_bytes").?.integer;
        const after_shown = after.value.object.get("preview_head_bytes").?.integer +
            after.value.object.get("preview_tail_bytes").?.integer;
        try std.testing.expect(after_shown < before_shown);
        try std.testing.expectEqual(
            after.value.object.get("original_bytes").?.integer,
            after_shown + after.value.object.get("omitted_bytes").?.integer,
        );

        // Refuses rather than mangles what it cannot rewrite.
        try std.testing.expect(shrinkRecoverableEnvelope(allocator, content, content.len) == null);
        try std.testing.expect(shrinkRecoverableEnvelope(allocator, "not an envelope", 8) == null);
    }
}

test "regrowing a whole turn's envelopes stays inside the turn budget" {
    // The regrow pass is the only step that makes a result bigger, and what it
    // produces is exempt from the spill pass - so ten parallel tool calls, each
    // returning a committed envelope, would each grow to the full per-result
    // budget and put the turn ten times over it with nothing left to trim.
    // Partial captures (`capture_complete=false`, a capture past
    // MAX_ARTIFACT_BYTES) cannot be re-inlined but grow just the same, so the
    // pre-pass has to price every rewritable envelope and not only the
    // re-inlinable ones.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const count = 10;
    var contents: [count][]const u8 = undefined;
    var items: [count]Item = undefined;
    for (0..count) |index| {
        const payload = try allocator.alloc(u8, 256 * 1024);
        defer allocator.free(payload);
        @memset(payload, @as(u8, 'a') + @as(u8, @intCast(index)));
        contents[index] = try captureTimeEnvelope(allocator, root, payload);
        items[index] = .{ .tool_name = "Mcp", .content = &contents[index], .is_error = false };
    }
    defer for (contents) |content| allocator.free(@constCast(content));

    const budget = result_budget.Budget.fromModel(200_000);
    const stats = try project(allocator, &items, .{ .session_root = root, .budget = budget });
    var total: usize = 0;
    for (contents) |content| {
        try std.testing.expect(isRecoverableEnvelope(content));
        try std.testing.expect(content.len <= budget.per_result_bytes);
        total += content.len;
    }
    try std.testing.expect(total <= budget.per_turn_bytes);
    try std.testing.expect(!stats.budget_exhausted);
    // Still worth doing: every one of them grew well past the 1536-byte
    // capture preview, they were just all held to a shared water line.
    try std.testing.expectEqual(@as(usize, count), stats.envelope_regrown_count);
    try std.testing.expect(total > count * (artifact.PREVIEW_HEAD_BYTES + artifact.PREVIEW_TAIL_BYTES));
}

test "a shrunk preview is still a prefix and a suffix of the original" {
    // The correctness core of the shrink path: it re-cuts the preview the
    // envelope already carries, so the head stays a prefix of the original and
    // the tail stays a suffix - which is the only reason
    // `original - head - tail` is still the right `omitted_bytes`. Cut from
    // anywhere else and the envelope would report a number that is not true.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast('a' + (index % 26));

    var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
    _ = try project(allocator, &items, .{
        .session_root = root,
        .budget = result_budget.Budget.fromModel(200_000),
    });

    const shrunk = shrinkRecoverableEnvelope(allocator, content, content.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    const head = parsed.value.object.get("preview_head").?.string;
    const tail = parsed.value.object.get("preview_tail").?.string;
    try std.testing.expect(head.len > 0 and tail.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, payload, head));
    try std.testing.expect(std.mem.endsWith(u8, payload, tail));
    // And the omission count is exactly what those two cuts left out.
    try std.testing.expectEqual(
        @as(i64, @intCast(payload.len - head.len - tail.len)),
        parsed.value.object.get("omitted_bytes").?.integer,
    );
}

test "shrink refuses rather than emit an envelope over the limit" {
    // `ENVELOPE_OVERHEAD_BYTES` is a measured round-up, not a proof, so the
    // result is checked against the caller's limit before it is handed back.
    // Below the scaffolding size there is no envelope to be had, and the
    // caller must be told that rather than handed something oversized - it
    // would then leave the result whole, which is the safe direction.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'Z');
    var content: []const u8 = try captureTimeEnvelope(allocator, root, payload);
    defer allocator.free(@constCast(content));
    var items = [_]Item{.{ .tool_name = "McpProbe", .content = &content, .is_error = false }};
    _ = try project(allocator, &items, .{
        .session_root = root,
        .budget = result_budget.Budget.fromModel(200_000),
    });

    // Every limit from "impossible" up to the envelope's own size: never a
    // result over the limit, never one that grew.
    for ([_]usize{ 0, 1, 64, 320, ENVELOPE_OVERHEAD_BYTES.raw(), ENVELOPE_OVERHEAD_BYTES.raw() + 1, 1024, 4096 }) |limit| {
        if (shrinkRecoverableEnvelope(allocator, content, limit)) |out| {
            defer allocator.free(out);
            try std.testing.expect(out.len <= limit);
            try std.testing.expect(out.len < content.len);
            try std.testing.expect(isRecoverableEnvelope(out));
            try std.testing.expect(hasRecoverableArtifact(out));
        }
    }
}

test "shrinking converges and preserves an incomplete capture's flag" {
    // Two properties the pressure valves depend on. Converges: the valve runs
    // on every pass, and a result that keeps shrinking would keep invalidating
    // the prompt-cache tail for nothing. Preserves `capture_complete`: it is
    // the model's only signal that the artifact is not the whole story, and a
    // rewrite that quietly flipped it to true would be a lie about the bytes.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const payload = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'C');
    const receipt = try artifact.persist(allocator, root, payload);

    // An envelope whose capture was cut short, rendered the way the capture
    // path renders one.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeArtifactEnvelopeHead(&out.writer, receipt.id(), "text/plain; charset=utf-8", payload.len, receipt.sha256[0..], false);
    try appendPreview(&out.writer, payload, .of(40 * 1024));
    try out.writer.writeAll(ARTIFACT_ENVELOPE_TAIL);
    const incomplete = try out.toOwnedSlice();
    defer allocator.free(incomplete);
    try std.testing.expect(isRecoverableEnvelope(incomplete));

    const limit = incomplete.len / 2;
    const first = shrinkRecoverableEnvelope(allocator, incomplete, limit) orelse return error.ShrinkRefused;
    defer allocator.free(first);
    try std.testing.expect(first.len <= limit);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first, .{});
    defer parsed.deinit();
    // The incomplete-capture signal survives the rewrite.
    try std.testing.expect(!parsed.value.object.get("capture_complete").?.bool);
    try std.testing.expect(parsed.value.object.get("recoverable").?.bool);

    // Converged: at the same limit there is nothing left to do.
    try std.testing.expect(shrinkRecoverableEnvelope(allocator, first, limit) == null);
}

test "a structured result keeps its short fields and stays parseable when trimmed" {
    // What the generic text truncation destroyed: a bash envelope's exit code
    // and storage reason, the flags, the ids - none of which is ever what made
    // the result oversized. Only the one long string is.
    const allocator = std.testing.allocator;
    const filler = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(filler);
    @memset(filler, 'o');
    filler[0] = 'H';
    filler[filler.len - 1] = 'T';
    const bash = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"{s}\"," ++
            "\"stdout_encoding\":\"utf-8\",\"stdout_captured_bytes\":{d},\"stdout_truncated\":false," ++
            "\"stdout_artifact_id\":null,\"stdout_recoverable\":true," ++
            "\"stdout_storage_error\":\"artifact_store_unavailable\",\"exit_code\":42}}",
        .{ filler, filler.len },
    );
    defer allocator.free(bash);

    const limit = bash.len / 4;
    const shrunk = shrinkStructuredResult(allocator, bash, limit) orelse return error.ShrinkRefused;
    defer allocator.free(shrunk);
    try std.testing.expect(shrunk.len <= limit);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Still JSON, and every short field survived byte for byte.
    try std.testing.expectEqual(@as(i64, 42), obj.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("artifact_store_unavailable", obj.get("stdout_storage_error").?.string);
    try std.testing.expectEqualStrings("metacodes.bash-result.v2", obj.get("schema_version").?.string);
    try std.testing.expectEqualStrings("utf-8", obj.get("stdout_encoding").?.string);
    try std.testing.expect(obj.get("stdout_recoverable").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(filler.len)), obj.get("stdout_captured_bytes").?.integer);
    // The long one was cut, head and tail kept, and the flag that describes it
    // was corrected rather than left claiming the original was intact.
    const out = obj.get("stdout").?.string;
    try std.testing.expect(out.len < filler.len);
    try std.testing.expect(std.mem.startsWith(u8, out, "H"));
    try std.testing.expect(std.mem.endsWith(u8, out, "T"));
    try std.testing.expect(obj.get("stdout_truncated").?.bool);
}

test "structured trimming marks both output channels when both are cut" {
    const allocator = std.testing.allocator;
    const filler = try allocator.alloc(u8, 32 * 1024);
    defer allocator.free(filler);
    @memset(filler, 'x');
    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"stdout\":\"{s}\",\"stdout_truncated\":false,\"stderr\":\"{s}\",\"stderr_truncated\":false,\"exit_code\":0}}",
        .{ filler, filler },
    );
    defer allocator.free(content);

    const shrunk = shrinkStructuredResult(allocator, content, content.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expect(parsed.value.object.get("stderr_truncated").?.bool);
}

test "trimming a fallback envelope corrects the counters it invalidates" {
    // A non-recoverable fallback envelope has no artifact to re-render from,
    // so it goes through the generic string trim - and its preview counters
    // have to follow the strings they describe.
    const allocator = std.testing.allocator;
    const body = try allocator.alloc(u8, 30 * 1024);
    defer allocator.free(body);
    @memset(body, 'f');
    const content: []const u8 = try renderFallbackEnvelope(allocator, "text/plain; charset=utf-8", body, .of(24 * 1024), "artifact_store_unavailable");
    defer allocator.free(@constCast(content));
    try std.testing.expect(isProjectionEnvelope(content));
    try std.testing.expect(!isRecoverableEnvelope(content));

    var before = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer before.deinit();
    const before_head = before.value.object.get("preview_head_bytes").?.integer;

    const shrunk = shrinkStructuredResult(allocator, content, content.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var after = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer after.deinit();
    const obj = after.value.object;
    // Identity and reason survive; the counter matches the string it names.
    try std.testing.expectEqualStrings("artifact_store_unavailable", obj.get("storage_error").?.string);
    try std.testing.expect(!obj.get("recoverable").?.bool);
    try std.testing.expectEqualStrings(
        before.value.object.get("sha256").?.string,
        obj.get("sha256").?.string,
    );
    // `preview_head_bytes` counts the *original* bytes the field still shows,
    // so once the field is a head/tail pair it excludes the elision marker.
    const head = obj.get("preview_head").?.string;
    try std.testing.expect(head.len < @as(usize, @intCast(before_head)));
    try std.testing.expect(std.mem.indexOf(u8, head, PREVIEW_ELISION) != null);
    try std.testing.expectEqual(
        @as(i64, @intCast(head.len - PREVIEW_ELISION.len)),
        obj.get("preview_head_bytes").?.integer,
    );
}

test "a trimmed envelope's elision count still adds up" {
    // Correcting two of the three counters is not correcting them. An envelope
    // that reports `omitted_bytes` from before the trim understates the gap -
    // it told the model 6144 bytes were missing out of 30720 when the real
    // figure was 22896 - and the model decides whether to recover from exactly
    // that number.
    const allocator = std.testing.allocator;
    const body = try allocator.alloc(u8, 30 * 1024);
    defer allocator.free(body);
    @memset(body, 'f');
    const content: []const u8 = try renderFallbackEnvelope(allocator, "text/plain; charset=utf-8", body, .of(24 * 1024), "artifact_store_unavailable");
    defer allocator.free(@constCast(content));

    for ([_]usize{ 2, 3, 5, 8 }) |divisor| {
        const shrunk = shrinkStructuredResult(allocator, content, content.len / divisor) orelse continue;
        defer allocator.free(shrunk);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const original = object.get("original_bytes").?.integer;
        const head = object.get("preview_head_bytes").?.integer;
        const tail = object.get("preview_tail_bytes").?.integer;
        const omitted = object.get("omitted_bytes").?.integer;
        try std.testing.expectEqual(original, head + tail + omitted);
    }
}

test "a long string nested inside the result is trimmed too" {
    // Only top-level strings were trimmed, so `{"rows":[{"text": <40KB>}]}`
    // had nothing to give and fell through to the text truncation that
    // destroys the JSON - the shape most tool results actually have.
    const allocator = std.testing.allocator;
    const filler = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(filler);
    @memset(filler, 'n');
    filler[0] = 'H';
    filler[filler.len - 1] = 'T';
    const nested = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"probe.v1\",\"exit_code\":3,\"rows\":[{{\"text\":\"{s}\"}}]}}",
        .{filler},
    );
    defer allocator.free(nested);

    const shrunk = shrinkStructuredResult(allocator, nested, nested.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    // Structure and the short fields intact, the deep string cut head/tail.
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("exit_code").?.integer);
    const text = parsed.value.object.get("rows").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(text.len < filler.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "H"));
    try std.testing.expect(std.mem.endsWith(u8, text, "T"));
}

test "a structured result with nothing to trim is left whole, never mangled" {
    // A large numeric array has no string to give back. Trimming cannot help,
    // and the text path would emit something no consumer can parse - so the
    // valve keeps it oversized instead. One extra request beats a destroyed
    // schema, which is the same call `hasRecoverableArtifact` already makes.
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"schema_version\":\"probe.v1\",\"exit_code\":0,\"rows\":[");
    var index: usize = 0;
    while (index < 6000) : (index += 1) {
        if (index != 0) try buf.writer.writeByte(',');
        try buf.writer.print("{d}", .{index});
    }
    try buf.writer.writeAll("]}");
    const content = buf.written();

    try std.testing.expect(isStructuredObject(content));
    try std.testing.expect(shrinkStructuredResult(allocator, content, content.len / 3) == null);
    // Plain text is still fair game for the text path - it has no schema to
    // destroy.
    try std.testing.expect(!isStructuredObject("just a long plain string of output"));
}

test "a trimmed base64 preview is still decodable, and its counter is decoded bytes" {
    // Two bugs in one field. Splicing the elision marker between two base64
    // runs produced a `preview_head` that is not base64 at all, so nothing
    // could decode it; and the counter beside it was the *character* count,
    // inflating the bytes-shown figure by a third against `original_bytes`.
    const allocator = std.testing.allocator;
    const binary = try allocator.alloc(u8, 30 * 1024);
    defer allocator.free(binary);
    @memset(binary, 0x01); // not inline-safe -> base64 preview
    const content: []const u8 = try renderFallbackEnvelope(allocator, "application/octet-stream", binary, .of(24 * 1024), "artifact_store_unavailable");
    defer allocator.free(@constCast(content));

    var original = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer original.deinit();
    try std.testing.expectEqualStrings("base64", original.value.object.get("preview_encoding").?.string);

    const shrunk = shrinkStructuredResult(allocator, content, content.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const head = object.get("preview_head").?.string;
    try std.testing.expect(head.len > 0);

    // Decodes, and to exactly what the counter claims.
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(head);
    const decoded = try allocator.alloc(u8, size);
    defer allocator.free(decoded);
    try decoder.decode(decoded, head);
    try std.testing.expectEqual(
        @as(i64, @intCast(decoded.len)),
        object.get("preview_head_bytes").?.integer,
    );
    for (decoded) |byte| try std.testing.expectEqual(@as(u8, 0x01), byte);

    // And the elision count is in the same unit, so the invariant is real
    // rather than two unit errors cancelling.
    const shown = object.get("preview_head_bytes").?.integer + object.get("preview_tail_bytes").?.integer;
    try std.testing.expectEqual(
        object.get("original_bytes").?.integer,
        shown + object.get("omitted_bytes").?.integer,
    );
}

test "structured counter repair does not depend on JSON key order" {
    const allocator = std.testing.allocator;
    const binary = try allocator.alloc(u8, 30 * 1024);
    defer allocator.free(binary);
    @memset(binary, 0x01);
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(binary.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, binary);

    // Deliberately put the encoding and counters after the preview values,
    // unlike our canonical envelope writer.  A consumer may legally reorder
    // object keys before handing the result back to the projection valve.
    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"preview_head\":\"{s}\",\"preview_head_bytes\":999999,\"omitted_bytes\":0,\"preview_encoding\":\"base64\",\"preview_tail\":\"{s}\",\"preview_tail_bytes\":999999,\"original_bytes\":{d}}}",
        .{ encoded, encoded, binary.len },
    );
    defer allocator.free(content);

    const shrunk = shrinkStructuredResult(allocator, content, content.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const head = object.get("preview_head").?.string;
    const tail = object.get("preview_tail").?.string;
    try std.testing.expectEqualStrings("base64", object.get("preview_encoding").?.string);
    _ = try std.base64.standard.Decoder.calcSizeForSlice(head);
    _ = try std.base64.standard.Decoder.calcSizeForSlice(tail);
    const head_bytes = object.get("preview_head_bytes").?.integer;
    const tail_bytes = object.get("preview_tail_bytes").?.integer;
    const omitted = object.get("omitted_bytes").?.integer;
    try std.testing.expectEqual(object.get("original_bytes").?.integer, head_bytes + tail_bytes + omitted);
}

test "a top-level array is structured too, and is trimmed rather than mangled" {
    // `isStructuredObject` only recognised objects, so a tool returning a
    // top-level array or scalar fell straight through to the text truncation
    // the object case was protected from.
    const allocator = std.testing.allocator;
    const filler = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(filler);
    @memset(filler, 'a');
    filler[0] = 'H';
    filler[filler.len - 1] = 'T';
    const array = try std.fmt.allocPrint(allocator, "[{{\"text\":\"{s}\"}},1,2,3]", .{filler});
    defer allocator.free(array);
    try std.testing.expect(isStructuredObject(array));

    const shrunk = shrinkStructuredResult(allocator, array, array.len / 3) orelse
        return error.ShrinkRefused;
    defer allocator.free(shrunk);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, shrunk, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    const items = parsed.value.array.items;
    // Shape and the scalar elements survive; only the long string was cut.
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqual(@as(i64, 3), items[3].integer);
    const text = items[0].object.get("text").?.string;
    try std.testing.expect(text.len < filler.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "H"));

    // A bare scalar is structured as well - never text-truncated.
    try std.testing.expect(isStructuredObject("12345"));
    try std.testing.expect(isStructuredObject("\"a string result\""));
    try std.testing.expect(!isStructuredObject("not json at all, just prose"));
}

test "per-turn image byte cap spills the largest images into envelopes, keeps the rest native" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var small: []const u8 = try testImageResult(allocator, 2048);
    defer allocator.free(@constCast(small));
    var big: []const u8 = try testImageResult(allocator, 8192);
    var mid: []const u8 = try testImageResult(allocator, 4096);
    defer allocator.free(@constCast(mid));
    var items = [_]Item{
        .{ .tool_name = "Read", .content = &small, .is_error = false },
        .{ .tool_name = "Read", .content = &big, .is_error = false },
        .{ .tool_name = "Read", .content = &mid, .is_error = false },
    };
    // Cap admits small + mid but not big: exactly the largest one spills.
    const stats = try project(allocator, &items, .{
        .session_root = root,
        .budget = .{ .per_result_bytes = 1 << 20, .per_turn_bytes = 1 << 20 },
        .per_turn_image_bytes = 8000,
    });
    defer allocator.free(@constCast(big));
    try std.testing.expectEqual(@as(usize, 1), stats.image_spills);
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);
    try std.testing.expect(isRecoverableEnvelope(big));
    // No base64 preview of the picture leaks into the envelope.
    try std.testing.expect(std.mem.indexOf(u8, big, "AAAAAAAA") == null);
    try std.testing.expect(isImageResult(small));
    try std.testing.expect(isImageResult(mid));
    // The spilled image is priced as an envelope from here on, the others at the estimate.
    try std.testing.expectEqual(2 * IMAGE_RESULT_BUDGET_BYTES + big.len, accountedTotal(&items));
    try std.testing.expect(!stats.budget_exhausted);
}
