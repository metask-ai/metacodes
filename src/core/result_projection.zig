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
const conversation_mod = @import("conversation.zig");
const result_budget = @import("result_budget.zig");
const json_mod = @import("../json.zig");

pub const SCHEMA = tool_result.PROJECTION_SCHEMA;
pub const ENVELOPE_PREFIX = tool_result.ENVELOPE_PREFIX;
pub const BASH_SCHEMA = "metacodes.bash-result.v2";

/// Fixed JSON scaffolding of one artifact/fallback envelope: schema version,
/// projection kind, artifact id, media type, original size, digest, the two
/// capture flags, the preview field names and the read instruction. Measured
/// at ~500 bytes with the longest production media type; rounded up so a
/// preview sized against `payloadAllowance` cannot push the rendered envelope
/// past the per-result budget it was derived from.
pub const ENVELOPE_OVERHEAD_BYTES: usize = 640;

/// Budget bytes per token, the same approximation `turnBudgetBytes` uses to
/// turn a token window into a byte budget.
const BUDGET_BYTES_PER_TOKEN: usize = 4;

/// What one image tool result costs this layer's byte budget. A vision block is
/// billed by the provider at a fixed token price (`IMAGE_TOKEN_ESTIMATE`),
/// never by its base64 length, so measuring it in bytes would let a single
/// 3.75 MB screenshot evict every unrelated result in the same turn.
const IMAGE_ACCOUNTED_BYTES: usize =
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
    return if (isImageResult(content)) IMAGE_ACCOUNTED_BYTES else content.len;
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
    /// A caller that overrides this is asking for a preview *smaller* than the
    /// budget permits; the value is a ceiling, never a floor.
    preview_bytes: ?usize = null,

    fn previewCap(self: Config) usize {
        return self.preview_bytes orelse
            self.budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES);
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
    structured_result_count: usize = 0,
    structured_projection_failures: usize = 0,
    turn_budget_spills: usize = 0,
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
    fn previewBytes(self: Allowance) usize {
        if (!self.underPressure()) return self.preview_cap;
        return @min(self.preview_cap, self.ceiling -| ENVELOPE_OVERHEAD_BYTES);
    }

    fn spillCost(self: Allowance) usize {
        return ENVELOPE_OVERHEAD_BYTES +| self.previewBytes();
    }

    /// Model-visible cost of a result of `len` bytes.
    ///
    /// Spilling is only ever chosen when it actually saves bytes. An envelope
    /// is ~640 bytes of scaffolding, so replacing a 700-byte result with one
    /// loses content *and* grows the request - the exact negative-sum trade
    /// the Bash channel preview used to make between 1537 and ~1760 bytes.
    /// The `@min(len, ...)` makes that outcome unrepresentable.
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
    items: []const Item,
    plan: []const ItemPlan,
    fixed_cost: usize,
    per_turn_bytes: usize,
    allowance: Allowance,
) usize {
    if (turnCost(items, plan, fixed_cost, allowance) <= per_turn_bytes)
        return allowance.per_result_bytes;
    var low: usize = 0;
    var high: usize = allowance.per_result_bytes;
    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        if (turnCost(items, plan, fixed_cost, allowance.at(mid)) <= per_turn_bytes)
            low = mid
        else
            high = mid - 1;
    }
    return low;
}

fn turnCost(
    items: []const Item,
    plan: []const ItemPlan,
    fixed_cost: usize,
    allowance: Allowance,
) usize {
    var total = fixed_cost;
    for (items, plan) |item, entry| {
        if (entry.exempt) continue;
        total +|= allowance.cost(item.content.*.len);
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

    // Correct capture-time previews before anything is planned: an envelope
    // may be re-inlined outright here, which changes both what it costs and
    // whether it is exempt at all.
    const uncapped = Allowance{
        .per_result_bytes = config.budget.per_result_bytes,
        .preview_cap = config.previewCap(),
        .ceiling = config.budget.per_result_bytes,
    };
    for (items) |item| {
        if (item.is_error) continue;
        if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
        if (!isRecoverableEnvelope(item.content.*)) continue;
        if (try regrowCommittedEnvelope(allocator, item, config, uncapped)) {
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
        const structured = isStructuredJson(content);
        if (structured) stats.structured_result_count += 1;
        const image = isImageResult(content);
        const exempt = image or
            item.is_error or
            isProjectionEnvelope(content) or
            std.mem.eql(u8, item.tool_name, "ReadArtifact");
        if (image and content.len > config.budget.per_result_bytes) stats.image_exempt_count += 1;
        if (exempt) fixed_cost +|= accountedBytes(content);
        plan[index] = .{ .exempt = exempt, .structured = structured };
    }

    // One allowance decision for every result, then one render each. The
    // previous shape decided per-result first and then re-spilled the largest
    // item in a loop, which could render the same result twice and could not
    // shrink anything it had already turned into an envelope.
    const allowance = uncapped.at(
        resolveTurnCeiling(items, plan, fixed_cost, config.budget.per_turn_bytes, uncapped),
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
    return stats;
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
/// recovery capability. Bash owns its channel artifacts directly, while all
/// other tools use the generic projection envelope.
pub fn hasRecoverableArtifact(content: []const u8) bool {
    if (isRecoverableEnvelope(content)) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const version = parsed.value.object.get("schema_version") orelse return false;
    if (version != .string or !std.mem.eql(u8, version.string, BASH_SCHEMA)) return false;
    return bashChannelRecoverable(parsed.value.object, "stdout_artifact_id", "stdout_recoverable") or
        bashChannelRecoverable(parsed.value.object, "stderr_artifact_id", "stderr_recoverable");
}

fn bashChannelRecoverable(object: std.json.ObjectMap, id_key: []const u8, recoverable_key: []const u8) bool {
    const recoverable = object.get(recoverable_key) orelse return false;
    if (recoverable != .bool or !recoverable.bool) return false;
    const id = object.get(id_key) orelse return false;
    return id == .string and validArtifactId(id.string);
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

    const id_value = object.get("artifact_id") orelse return false;
    if (id_value != .string or !validArtifactId(id_value.string)) return false;
    const original_value = object.get("original_bytes") orelse return false;
    if (original_value != .integer or original_value.integer < 0) return false;
    const original_bytes: u64 = @intCast(original_value.integer);
    const media_type = switch (object.get("media_type") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    const digest = switch (object.get("sha256") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    if (digest.len != artifact.ID_HEX_BYTES) return false;
    const capture_complete = switch (object.get("capture_complete") orelse return false) {
        .bool => |value| value,
        else => return false,
    };
    const shown = previewShownBytes(object);

    // Re-inline whenever the whole original now fits. This is the case the
    // constant got most wrong: a result a few kilobytes long, spilled at
    // capture time, then kept as a 1.5KB preview under a budget with room for
    // all of it.
    if (capture_complete and original_bytes <= allowance.ceiling) {
        if (readWholeArtifact(allocator, config.session_root, id_value.string, original_bytes)) |whole| {
            allocator.free(@constCast(current));
            item.content.* = whole;
            return true;
        } else |_| {}
    }

    const target = allowance.previewBytes();
    if (shown >= target) return false;

    // One chunk per side keeps this to two reads of the artifact, which each
    // re-verify its digest; the preview is bounded by the budget anyway.
    const head_len: usize = @min(target * 3 / 4, artifact.MAX_READ_BYTES);
    const tail_len: usize = @min(target -| head_len, artifact.MAX_READ_BYTES);
    if (head_len == 0) return false;
    var head = artifact.readChunk(allocator, config.session_root, id_value.string, 0, head_len) catch return false;
    defer head.deinit();
    const tail_offset = original_bytes -| tail_len;
    var tail = if (tail_len > 0 and tail_offset >= head.bytes.len)
        artifact.readChunk(allocator, config.session_root, id_value.string, tail_offset, tail_len) catch return false
    else
        null;
    defer if (tail) |*chunk| chunk.deinit();
    const tail_bytes: []const u8 = if (tail) |chunk| chunk.bytes else "";
    if (head.bytes.len + tail_bytes.len <= shown) return false;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writeArtifactEnvelopeHead(writer, id_value.string, media_type, original_bytes, digest, capture_complete);
    const utf8 = isInlineUtf8(head.bytes) and isInlineUtf8(tail_bytes);
    try appendPreviewParts(
        writer,
        head.bytes,
        tail_bytes,
        original_bytes -| head.bytes.len -| tail_bytes.len,
        utf8,
    );
    try writer.writeAll(ARTIFACT_ENVELOPE_TAIL);
    const replacement = try out.toOwnedSlice();
    allocator.free(@constCast(current));
    item.content.* = replacement;
    return true;
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
    preview_bytes: usize,
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
    preview_bytes: usize,
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
    try std.json.Stringify.encodeJsonString(artifact_id, .{}, writer);
    try writer.writeAll(",\"media_type\":");
    try std.json.Stringify.encodeJsonString(media_type, .{}, writer);
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
    preview_bytes: usize,
    storage_error: []const u8,
) ![]u8 {
    const digest = artifact.sha256Hex(content);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(ENVELOPE_PREFIX ++ "\"fallback\",\"artifact_id\":null,\"media_type\":");
    try std.json.Stringify.encodeJsonString(media_type, .{}, writer);
    try writer.print(",\"original_bytes\":{d},\"sha256\":\"{s}\",\"capture_complete\":true,\"recoverable\":false,\"storage_error\":", .{ content.len, digest[0..] });
    try std.json.Stringify.encodeJsonString(storage_error, .{}, writer);
    try appendPreview(writer, content, preview_bytes);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn appendPreview(writer: *std.Io.Writer, content: []const u8, preview_bytes: usize) !void {
    const valid_utf8 = isInlineUtf8(content);
    // `preview_bytes` is an encoded budget. Cutting on source length would let
    // a quote- or newline-dense result render at up to twice the size it was
    // sized against, so the head/tail cuts are chosen by encoded cost. The
    // base64 branch has no escapes but expands 4:3, which the same accounting
    // covers by converting the budget back into source bytes.
    const head_budget = preview_bytes * 3 / 4;
    const head_end = if (valid_utf8)
        result_budget.encodedPrefixLen(content, head_budget)
    else
        @min(content.len, head_budget * 3 / 4);
    const remaining = content[head_end..];
    const tail_budget = preview_bytes -| (if (valid_utf8) result_budget.encodedLen(content[0..head_end]) else head_end * 4 / 3);
    const tail_len = if (valid_utf8)
        result_budget.encodedSuffixLen(remaining, tail_budget)
    else
        @min(remaining.len, tail_budget * 3 / 4);
    const tail_start = content.len - tail_len;
    try appendPreviewParts(writer, content[0..head_end], content[tail_start..], tail_start - head_end, valid_utf8);
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
    if (utf8) return std.json.Stringify.encodeJsonString(bytes, .{}, writer);
    const encoder = std.base64.standard.Encoder;
    const encoded = try std.heap.page_allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer std.heap.page_allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);
    try std.json.Stringify.encodeJsonString(encoded, .{}, writer);
}

fn isInlineUtf8(content: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(content)) return false;
    for (content) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') return false;
    }
    return true;
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
    var content: []const u8 = try allocator.alloc(u8, ENVELOPE_OVERHEAD_BYTES - 1);
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
