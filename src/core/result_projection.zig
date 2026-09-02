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
const json_mod = @import("../json.zig");

pub const SCHEMA = tool_result.PROJECTION_SCHEMA;
pub const ENVELOPE_PREFIX = tool_result.ENVELOPE_PREFIX;
pub const BASH_SCHEMA = "metacodes.bash-result.v2";
pub const DEFAULT_PREVIEW_BYTES: usize = 1536;
/// Turn-budget charge for one image-shaped result. Vision-capable routes
/// consume these natively (`extractImageResult` → image block / data URL /
/// inlineData) and non-vision routes replace them with a short bounded
/// placeholder, so the model never pays for the base64 length; it pays the
/// vision estimate that already drives auto-compact and request estimation
/// (`types.IMAGE_TOKEN_ESTIMATE`), at the four-bytes-per-token convention of
/// `conversation.toolResultContextBytes`.
pub const IMAGE_RESULT_BUDGET_BYTES: usize = types.IMAGE_TOKEN_ESTIMATE * 4;

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
    /// Aggregate base64 bytes of native image results the turn may keep.
    /// Images bypass the byte budgets above, but providers cap the request
    /// size (types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST); beyond this the
    /// largest images spill into recoverable envelopes.
    per_turn_image_bytes: usize = types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST,
};

pub const Stats = struct {
    /// Bytes the tools actually produced (envelopes count their original size).
    raw_bytes: usize = 0,
    /// Actual byte length of the committed results after projection. An
    /// exempt image keeps its full base64 length here; this is what the
    /// metrics snapshot and the projection log report as bytes.
    projected_bytes: usize = 0,
    /// The same result set in turn-budget units: text at its length, image
    /// results at `IMAGE_RESULT_BUDGET_BYTES`. `budget_exhausted` is decided
    /// on this figure, never on `projected_bytes`.
    budget_bytes: usize = 0,
    artifact_bytes: usize = 0,
    artifact_spill_count: usize = 0,
    unrecoverable_fallback_count: usize = 0,
    structured_result_count: usize = 0,
    structured_projection_failures: usize = 0,
    turn_budget_spills: usize = 0,
    /// Image results spilled because the turn exceeded `per_turn_image_bytes`.
    image_spills: usize = 0,
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

/// Image-shaped tool result (`{"type":"image","media_type":...,"data":...}`,
/// the `Read` tool's picture form; the exact canonical shape is defined by
/// `extractImageResult`). Never spilled: an artifact envelope would turn the
/// picture into a base64 preview string that no dialect recognizes as an
/// image, so every provider would receive text instead of the picture.
pub fn isImageResult(content: []const u8) bool {
    return json_mod.extractImageResult(content) != null;
}

pub fn project(allocator: std.mem.Allocator, items: []Item, config: Config) !Stats {
    var stats = Stats{};
    const structured = try allocator.alloc(bool, items.len);
    defer allocator.free(structured);
    const image = try allocator.alloc(bool, items.len);
    defer allocator.free(image);
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
        image[index] = isImageResult(item.content.*);
    }

    // Per-result bound first. ReadArtifact is itself hard-bounded and must not
    // spill again, otherwise recovery would recurse forever.
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
        // Encoded tool errors are bounded semantic control messages, not bulk
        // content. Replacing them would hide the exact recovery contract from
        // the model; the aggregate budget may report exhaustion instead.
        if (item.is_error) continue;
        // Image results bypass both passes: the dialects serialize them
        // natively and the budget below charges them at
        // IMAGE_RESULT_BUDGET_BYTES, never at their base64 length.
        if (image[index]) continue;
        if (item.content.*.len <= config.per_result_bytes) continue;
        try spillOne(allocator, item, structured[index], config, &stats, false);
    }

    // Wire-size cap for the turn's native images: spill the largest first
    // (strict > keeps the ordinal as the deterministic tie-breaker). A spilled
    // image becomes an ordinary envelope from here on.
    var image_bytes: usize = 0;
    for (items, image) |item, is_image| {
        if (is_image) image_bytes +|= item.content.*.len;
    }
    while (image_bytes > config.per_turn_image_bytes) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (items, 0..) |item, index| {
            if (!image[index]) continue;
            if (item.content.*.len > biggest_len) {
                biggest = index;
                biggest_len = item.content.*.len;
            }
        }
        const index = biggest orelse break;
        const before = items[index].content.*.len;
        try spillOne(allocator, items[index], structured[index], config, &stats, false);
        image[index] = false;
        stats.image_spills += 1;
        image_bytes -= before;
    }

    var total = budgetBytes(items, image);
    while (total > config.per_turn_bytes) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.tool_name, "ReadArtifact")) continue;
            if (item.is_error) continue;
            if (image[index]) continue;
            if (isProjectionEnvelope(item.content.*)) continue;
            // Strict > preserves the original ordinal as the deterministic
            // tie-breaker for equal-size parallel results.
            if (item.content.*.len > biggest_len) {
                biggest = index;
                biggest_len = item.content.*.len;
            }
        }
        const index = biggest orelse break;
        const before = items[index].content.*.len;
        try spillOne(allocator, items[index], structured[index], config, &stats, true);
        const after = items[index].content.*.len;
        total = total - before + after;
        if (after >= before) break;
    }
    stats.projected_bytes = totalBytes(items);
    stats.budget_bytes = budgetBytes(items, image);
    stats.budget_exhausted = stats.budget_bytes > config.per_turn_bytes;
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

fn totalBytes(items: []const Item) usize {
    var total: usize = 0;
    for (items) |item| total +|= item.content.*.len;
    return total;
}

/// Turn-budget size of the result set: text at its length, image results at
/// `IMAGE_RESULT_BUDGET_BYTES` (a 5 MB base64 screenshot must not evict every
/// text sibling from the turn, nor report the budget as exhausted forever).
fn budgetBytes(items: []const Item, image: []const bool) usize {
    var total: usize = 0;
    for (items, image) |item, is_image| {
        total +|= if (is_image) IMAGE_RESULT_BUDGET_BYTES else item.content.*.len;
    }
    return total;
}

fn testImageContent(allocator: std.mem.Allocator, data_len: usize) ![]const u8 {
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    @memset(data, 'A');
    return std.fmt.allocPrint(allocator, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{data});
}

test "image results bypass the per-result bound while an equal-size text sibling spills" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var image_content: []const u8 = try testImageContent(allocator, 4096);
    defer allocator.free(@constCast(image_content));
    const image_before = try allocator.dupe(u8, image_content);
    defer allocator.free(image_before);
    var text_content: []const u8 = try allocator.alloc(u8, image_content.len);
    @memset(@constCast(text_content), 'x');
    var items = [_]Item{
        .{ .tool_name = "Read", .content = &image_content, .is_error = false },
        .{ .tool_name = "Read", .content = &text_content, .is_error = false },
    };
    const stats = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 64, .per_turn_bytes = 1 << 20 });
    defer allocator.free(@constCast(text_content));
    try std.testing.expect(isImageResult(image_content));
    try std.testing.expectEqualStrings(image_before, image_content);
    try std.testing.expect(isRecoverableEnvelope(text_content));
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, 0), stats.turn_budget_spills);
}

test "image results are charged at IMAGE_RESULT_BUDGET_BYTES in the turn budget, never spilled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    // The base64 payload alone is several times the whole turn budget.
    var image_content: []const u8 = try testImageContent(allocator, 4 * IMAGE_RESULT_BUDGET_BYTES);
    defer allocator.free(@constCast(image_content));
    const image_before = try allocator.dupe(u8, image_content);
    defer allocator.free(image_before);
    var text_content: []const u8 = try allocator.alloc(u8, 4096);
    @memset(@constCast(text_content), 'y');
    var items = [_]Item{
        .{ .tool_name = "Read", .content = &image_content, .is_error = false },
        .{ .tool_name = "Grep", .content = &text_content, .is_error = false },
    };

    // Positive: the text sibling fits next to the image's charged estimate, so nothing spills.
    const fits = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 1 << 20, .per_turn_bytes = IMAGE_RESULT_BUDGET_BYTES + 4096 });
    defer allocator.free(@constCast(text_content));
    try std.testing.expectEqual(@as(usize, 0), fits.turn_budget_spills);
    try std.testing.expect(!fits.budget_exhausted);
    try std.testing.expectEqual(IMAGE_RESULT_BUDGET_BYTES + 4096, fits.budget_bytes);
    // projected_bytes stays a real byte count: the exempt image is reported at
    // its full length, so metrics never imply the picture was removed.
    try std.testing.expectEqual(image_content.len + 4096, fits.projected_bytes);
    try std.testing.expectEqualStrings(image_before, image_content);
    try std.testing.expectEqual(@as(usize, 4096), text_content.len);

    // Negative: tighten the budget below the pair. Only the text sibling is a
    // spill candidate; the image stays byte-identical and the budget recovers.
    const tight = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 1 << 20, .per_turn_bytes = IMAGE_RESULT_BUDGET_BYTES + 1024, .preview_bytes = 0 });
    try std.testing.expectEqual(@as(usize, 1), tight.turn_budget_spills);
    try std.testing.expect(isRecoverableEnvelope(text_content));
    try std.testing.expectEqualStrings(image_before, image_content);
    try std.testing.expect(!tight.budget_exhausted);
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

test "per-turn image byte cap spills the largest images into envelopes, keeps the rest native" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var small: []const u8 = try testImageContent(allocator, 2048);
    defer allocator.free(@constCast(small));
    var big: []const u8 = try testImageContent(allocator, 8192);
    const big_before = try allocator.dupe(u8, big);
    defer allocator.free(big_before);
    var mid: []const u8 = try testImageContent(allocator, 4096);
    defer allocator.free(@constCast(mid));
    var items = [_]Item{
        .{ .tool_name = "Read", .content = &small, .is_error = false },
        .{ .tool_name = "Read", .content = &big, .is_error = false },
        .{ .tool_name = "Read", .content = &mid, .is_error = false },
    };
    // Cap admits small + mid but not big: exactly the largest one spills.
    const stats = try project(allocator, &items, .{ .session_root = root, .per_result_bytes = 1 << 20, .per_turn_bytes = 1 << 20, .per_turn_image_bytes = 8000, .preview_bytes = 0 });
    defer allocator.free(@constCast(big));
    try std.testing.expectEqual(@as(usize, 1), stats.image_spills);
    try std.testing.expect(isRecoverableEnvelope(big));
    try std.testing.expect(isImageResult(small));
    try std.testing.expect(isImageResult(mid));
    // The spilled image is charged as text from here on, the others at the estimate.
    try std.testing.expectEqual(2 * IMAGE_RESULT_BUDGET_BYTES + big.len, stats.budget_bytes);
}
