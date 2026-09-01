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
const json_mod = @import("../json.zig");

pub const SCHEMA = tool_result.PROJECTION_SCHEMA;
pub const ENVELOPE_PREFIX = tool_result.ENVELOPE_PREFIX;
pub const BASH_SCHEMA = "metacodes.bash-result.v2";
pub const DEFAULT_PREVIEW_BYTES: usize = 1536;

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
    per_result_bytes: usize,
    per_turn_bytes: usize,
    preview_bytes: usize = DEFAULT_PREVIEW_BYTES,
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
    /// Whether the committed results still exceed `per_turn_bytes` in **budget
    /// weight** (`accountedBytes`: an image costs its token estimate, every
    /// other result costs its bytes). Deliberately not derived from
    /// `projected_bytes`, which is a byte metric.
    budget_exhausted: bool = false,

    pub fn changed(self: Stats) bool {
        return self.artifact_spill_count != 0 or self.unrecoverable_fallback_count != 0;
    }
};

pub fn turnBudgetBytes(max_input_tokens: usize) usize {
    // Approximate four UTF-8 bytes/token, then allocate 30% of one request to
    // all tool results. The caps match the existing production envelope.
    const derived = std.math.mul(usize, max_input_tokens, 6) catch std.math.maxInt(usize);
    const scaled = derived / 5;
    return @min(@max(scaled, 16 * 1024), 200 * 1024);
}

pub fn project(allocator: std.mem.Allocator, items: []Item, config: Config) !Stats {
    var stats = Stats{};
    const structured = try allocator.alloc(bool, items.len);
    defer allocator.free(structured);
    for (items, 0..) |item, index| {
        if (recoverableEnvelopeOriginalBytes(item.content.*)) |original_bytes| {
            stats.raw_bytes +|= original_bytes;
            stats.artifact_bytes +|= original_bytes;
            stats.artifact_spill_count +|= 1;
        } else {
            stats.raw_bytes +|= item.content.*.len;
        }
        structured[index] = isStructuredJson(item.content.*);
        if (structured[index]) stats.structured_result_count += 1;
    }

    // Per-result bound first. ReadArtifact is itself hard-bounded and must not
    // spill again, otherwise recovery would recurse forever.
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
        // Encoded tool errors are bounded semantic control messages, not bulk
        // content. Replacing them would hide the exact recovery contract from
        // the model; the aggregate budget may report exhaustion instead.
        if (item.is_error) continue;
        // Image-shaped results are not bulk text: downstream every dialect
        // turns them into a native vision block (or the explicit non-vision
        // placeholder). Spilling one by byte length would replace the picture
        // with an artifact envelope the model cannot see, and `ReadArtifact`
        // would only hand the base64 back as text.
        if (isImageResult(item.content.*)) {
            if (item.content.*.len > config.per_result_bytes) stats.image_exempt_count += 1;
            continue;
        }
        if (item.content.*.len <= config.per_result_bytes) continue;
        try spillOne(allocator, item, structured[index], config, &stats, false);
    }

    var total = accountedTotal(items);
    while (total > config.per_turn_bytes) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
            if (item.is_error) continue;
            if (isProjectionEnvelope(item.content.*)) continue;
            // Same carve-out as the per-result pass. Without it the budget
            // loop would pick the image first every time, because base64 makes
            // it the largest item even when it is the cheapest in tokens.
            if (isImageResult(item.content.*)) continue;
            // Strict > preserves the original ordinal as the deterministic
            // tie-breaker for equal-size parallel results.
            if (item.content.*.len > biggest_len) {
                biggest = index;
                biggest_len = item.content.*.len;
            }
        }
        const index = biggest orelse break;
        const before = accountedBytes(items[index].content.*);
        try spillOne(allocator, items[index], structured[index], config, &stats, true);
        const after = accountedBytes(items[index].content.*);
        total = total - before + after;
        if (after >= before) break;
    }
    stats.projected_bytes = literalTotal(items);
    stats.budget_exhausted = accountedTotal(items) > config.per_turn_bytes;
    return stats;
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

fn spillOne(
    allocator: std.mem.Allocator,
    item: Item,
    structured: bool,
    config: Config,
    stats: *Stats,
    turn_budget: bool,
) !void {
    const original = item.content.*;
    const media_type = if (structured) "application/json" else "text/plain; charset=utf-8";
    const persisted = artifact.persist(allocator, config.session_root, original);
    const replacement = if (persisted) |stored| blk: {
        stats.artifact_spill_count += 1;
        stats.artifact_bytes +|= original.len;
        break :blk try renderArtifactEnvelope(allocator, stored, media_type, original, config.preview_bytes);
    } else |persist_error| blk: {
        if (persist_error == error.OutOfMemory) return error.OutOfMemory;
        stats.unrecoverable_fallback_count += 1;
        if (structured) stats.structured_projection_failures += 1;
        break :blk try renderFallbackEnvelope(allocator, media_type, original, config.preview_bytes, storageErrorCode(persist_error));
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
    try writer.writeAll(ENVELOPE_PREFIX ++ "\"artifact\",\"artifact_id\":");
    try std.json.Stringify.encodeJsonString(receipt.id(), .{}, writer);
    try writer.writeAll(",\"media_type\":");
    try std.json.Stringify.encodeJsonString(media_type, .{}, writer);
    try writer.print(",\"original_bytes\":{d},\"sha256\":\"{s}\",\"capture_complete\":true,\"recoverable\":true", .{ receipt.bytes, receipt.sha256[0..] });
    try appendPreview(writer, content, preview_bytes);
    try writer.writeAll(",\"read\":{\"tool\":\"ReadArtifact\",\"offset\":0,\"limit_max\":32768}}");
    return out.toOwnedSlice();
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

fn storageErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ArtifactRootUnavailable => "artifact_store_unavailable",
        error.ArtifactTooLarge => "artifact_too_large",
        error.SessionQuotaExceeded => "artifact_session_quota_exceeded",
        error.ArtifactPathSymlink,
        error.ArtifactDirectoryUnsafe,
        error.ArtifactUnsafeFile,
        error.ArtifactDirectoryUntrusted,
        => "artifact_store_unsafe",
        else => "artifact_persist_failed",
    };
}

fn appendPreview(writer: *std.Io.Writer, content: []const u8, preview_bytes: usize) !void {
    const valid_utf8 = isInlineUtf8(content);
    const raw_head_budget = @min(content.len, preview_bytes * 3 / 4);
    const head_end = if (valid_utf8) floorUtf8Boundary(content, raw_head_budget) else raw_head_budget;
    const raw_tail_budget = @min(content.len - head_end, preview_bytes -| head_end);
    var tail_start = content.len - raw_tail_budget;
    if (valid_utf8) tail_start = ceilUtf8Boundary(content, tail_start);
    if (tail_start < head_end) tail_start = head_end;
    const head = content[0..head_end];
    const tail = content[tail_start..];

    try writer.writeAll(if (valid_utf8) ",\"preview_encoding\":\"utf-8\"" else ",\"preview_encoding\":\"base64\"");
    try writer.writeAll(",\"preview_head\":");
    try appendPreviewPart(writer, head, valid_utf8);
    try writer.writeAll(",\"preview_tail\":");
    try appendPreviewPart(writer, tail, valid_utf8);
    try writer.print(",\"preview_head_bytes\":{d},\"preview_tail_bytes\":{d},\"omitted_bytes\":{d}", .{
        head.len,
        tail.len,
        tail_start - head_end,
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

fn floorUtf8Boundary(content: []const u8, desired: usize) usize {
    var end = @min(desired, content.len);
    if (end == content.len) return end;
    while (end > 0 and isUtf8ContinuationByte(content[end])) : (end -= 1) {}
    return end;
}

fn ceilUtf8Boundary(content: []const u8, desired: usize) usize {
    var start = @min(desired, content.len);
    while (start < content.len and isUtf8ContinuationByte(content[start])) : (start += 1) {}
    return start;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
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
    var content: []const u8 = try allocator.dupe(u8, "{\"rows\":[1,2,3],\"padding\":\"xxxxxxxxxxxxxxxx\"}");
    var items = [_]Item{.{ .tool_name = "KgContext", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 16, .per_turn_bytes = 4096 });
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
    var content: []const u8 = try allocator.dupe(u8, "HEAD-中文-abcdefghijklmnopqrstuvwxyz-TAIL🙂");
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};
    _ = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 8, .per_turn_bytes = 4096, .preview_bytes = 36 });
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
    var content: []const u8 = try allocator.dupe(u8, "{\"large\":true,\"padding\":\"xxxxxxxx\"}");
    var items = [_]Item{.{ .tool_name = "Probe", .content = &content, .is_error = false }};
    const stats = try project(allocator, &items, .{ .session_root = "", .per_result_bytes = 8, .per_turn_bytes = 4096 });
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
    const stats = try project(allocator, &items, .{ .session_root = "", .per_result_bytes = 8, .per_turn_bytes = 8 });
    try std.testing.expectEqualStrings(before, content);
    try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
    try std.testing.expect(stats.budget_exhausted);
}

test "aggregate spill uses original ordinal as equal-size tie break" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var first: []const u8 = try allocator.dupe(u8, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    var second: []const u8 = try allocator.dupe(u8, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    var items = [_]Item{
        .{ .tool_name = "A", .content = &first, .is_error = false },
        .{ .tool_name = "B", .content = &second, .is_error = false },
    };
    const stats = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 4096, .per_turn_bytes = 48, .preview_bytes = 0 });
    defer allocator.free(@constCast(first));
    defer allocator.free(@constCast(second));
    try std.testing.expectEqual(@as(usize, 1), stats.turn_budget_spills);
    try std.testing.expect(isRecoverableEnvelope(first));
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", second);
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
        .per_result_bytes = 64 * 1024,
        .per_turn_bytes = 200 * 1024,
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
        .per_result_bytes = 64 * 1024,
        .per_turn_bytes = 16 * 1024,
        .preview_bytes = 0,
    });
    try std.testing.expectEqualStrings(image_original, image);
    try std.testing.expectEqual(@as(usize, 1), stats.turn_budget_spills);
    try std.testing.expect(isRecoverableEnvelope(text));
}
