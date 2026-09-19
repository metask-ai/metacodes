const std = @import("std");
const shell_mod = @import("../core/shell.zig");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const security = @import("security.zig");
const util_time = @import("../util/time.zig");
const util_json = @import("../util/json.zig");
const ToolContext = @import("context.zig").ToolContext;
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact = @import("../core/tool_result_artifact.zig");
const tool_result = @import("../core/tool_result.zig");
const ResultMetrics = @import("../core/tool_result_metrics.zig").Metrics;
const result_budget = @import("../core/result_budget.zig");

/// nowMs：毫秒时间戳，复用 util/time.zig
fn nowMs() util_time.Millis {
    return util_time.nowMs();
}

/// 默认 timeout：120s（对齐 TS 原版 BashTool）。
pub const DEFAULT_TIMEOUT_MS: u64 = 120_000;
/// 最大 timeout 上限：24h。
pub const MAX_TIMEOUT_MS: u64 = 24 * 3600 * 1000;
/// 同步模式超过此时长自动转后台：与 TS 对齐（ASSISTANT_BLOCKING_BUDGET_MS）
pub const AUTO_BACKGROUND_MS: u64 = 15_000;

/// 自动转后台时那份**部分快照**里单股输出的上限(`formatAutoBackgrounded`)。
/// 已完成的结果不走这里:它按 `ToolContext.result_budget` 派生的额度做头尾预览,
/// 见 `channelAllowances`。(历史上这个常量的注释声称管的是前台输出上限,并被
/// 工具描述照抄成 "~30KB",实际自 c3d1676 起就只覆盖部分快照这一条路径。)
pub const MAX_OUTPUT_BYTES: usize = 30_000;
/// Fixed JSON scaffolding of a completed two-channel envelope: the schema
/// version, both channels' encodings, sizes, digests, artifact ids, read
/// instructions and spool paths, plus the exit code. Measured at ~1.3KB with
/// both channels spilled and a macOS temp path; rounded up so a preview sized
/// against the remaining allowance cannot push the rendered envelope past the
/// per-result budget it was derived from.
pub const ENVELOPE_OVERHEAD_BYTES: result_budget.Encoded = .of(2048);

/// Encoded preview bytes the two channels share, given the turn's budget.
///
/// This used to be a hard-coded 1536 per channel, back-computed from the 8KiB
/// budget *floor* and then applied unchanged on a 262K-window model whose real
/// allowance is 32KB. Because Bash spills before `result_projection` ever sees
/// the result, and because microcompact refuses to touch a recoverable
/// envelope, that constant was the only decision ever made about a Bash
/// result's size for its whole life in the Conversation.
fn channelAllowances(budget: result_budget.Budget, stdout_demand: result_budget.Encoded, stderr_demand: result_budget.Encoded) result_budget.Pair {
    return result_budget.splitPair(
        budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES),
        stdout_demand,
        stderr_demand,
    );
}

/// What one channel actually costs the allowance, in the encoding it will be
/// rendered in.
///
/// A bound was tried here first (`raw * 2`, JSON escaping's worst case) on the
/// theory that unused ceiling is free. It is not: `splitPair` hands a channel
/// its full stated demand and gives only the remainder to the other, so
/// overstating a small channel takes bytes away from a large one. With the
/// 8KiB floor budget, 5000 bytes of stdout beside 1000 bytes of stderr - 6000
/// encoded against a 6144 allowance, comfortably whole - had stdout cut to
/// 4142 and spilled to an artifact, destroying 858 bytes of intact output and
/// buying a recovery round trip. Both channels are in memory here, so the real
/// number is one linear scan away.
fn encodedDemand(bytes: []const u8) result_budget.Encoded {
    return encodedCost(bytes, !isInlineUtf8(bytes));
}

/// The same demand for a channel that lives in a spool file.
///
/// `splitPair` treats every demand at or above the allowance identically, so
/// only a channel small enough to fit needs a precise one - and that channel
/// is by definition cheap to read. Anything larger is bounded rather than
/// measured, which keeps this off the path of a multi-gigabyte spool.
fn fileEncodedDemand(allocator: std.mem.Allocator, path: []const u8, allowance: result_budget.Encoded) result_budget.Encoded {
    const zero = result_budget.Encoded.of(0);
    const raw = artifact.observeFileBytes(allocator, path) catch return zero;
    if (raw == 0) return zero;
    // A channel too large to fit needs no precise demand - `splitPair` treats
    // every demand at or above the allowance identically - so it is bounded by
    // JSON escaping's worst case rather than measured.
    const bound = result_budget.Encoded.of(std.math.cast(usize, raw *| 2) orelse std.math.maxInt(usize));
    if (raw > allowance.raw()) return bound;
    const whole = readWholeFile(path, allocator, @intCast(raw)) catch return bound;
    defer allocator.free(whole);
    return encodedDemand(whole);
}
const PREVIEW_OMISSION_MARKER = "\n...[middle omitted]...\n";

const ChannelPreview = struct {
    content: []u8,
    shown_source_bytes: u64,
    /// The encoding this preview's budget was spent in, carried to
    /// `appendChannel` rather than re-derived there.
    ///
    /// The two used to be decided independently: the budget from the whole
    /// channel, the rendering from the preview. A channel whose only
    /// non-inline byte fell in the omitted middle was therefore budgeted at
    /// base64's 4:3 and then rendered with JSON escaping's 2:1, putting the
    /// envelope ~40% past the per-result budget it was sized against.
    base64: bool = false,
    allocator: std.mem.Allocator,

    fn deinit(self: *ChannelPreview) void {
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

/// 把输出截断到 ≤ MAX_OUTPUT_BYTES(保留头部),超出时追加 `... [N lines truncated] ...`。
/// 切点回退到不超过上限的最近 UTF-8 字符边界 + 最近换行(不切坏多字节/半行)。
/// 返回 owned slice(调用方 free);未超限时返回原文 dupe。
fn truncateHead(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const cut = truncateHeadSourceBytes(s);
    if (cut == s.len) return try allocator.dupe(u8, s);

    // 统计被砍掉的行数(剩余部分的 \n 数 + 1 行尾)。
    var dropped_lines: usize = 0;
    for (s[cut..]) |c| {
        if (c == '\n') dropped_lines += 1;
    }
    if (s[s.len - 1] != '\n') dropped_lines += 1;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(s[0..cut]);
    try out.writer.print("\n... [{d} lines truncated] ...\n", .{dropped_lines});
    return try out.toOwnedSlice();
}

/// Number of source bytes represented by the visible head. The formatted
/// preview also contains an omission marker, so its length is not a safe
/// cursor for BashOutput to resume from.
fn truncateHeadSourceBytes(s: []const u8) usize {
    if (s.len <= MAX_OUTPUT_BYTES) return s.len;
    // 1. 先定到 MAX_OUTPUT_BYTES,回退到 UTF-8 字符边界(continuation byte 0b10xxxxxx)。
    var cut = MAX_OUTPUT_BYTES;
    while (cut > 0 and (s[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
    // 2. 再回退到最近换行(让截断落在行边界,输出更整齐);若该行很长找不到则就用 cut。
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], '\n')) |nl| {
        if (nl + 1 >= MAX_OUTPUT_BYTES / 2) cut = nl + 1; // 仅当不会砍掉过多时才退到换行
    }
    return cut;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Format the model-visible bounded preview while retaining a commitment to
/// the captured bytes before the 30KB display truncation. The zero-gain
/// breaker hashes this whole JSON result, so two commands whose warnings share
/// the same 30KB head but whose diagnostics differ later no longer collide.
fn formatCompletedOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    artifact_root: []const u8,
    capture_complete: bool,
    budget: result_budget.Budget,
    metrics: ?*ResultMetrics,
    attachments: *tool_result.SealedHandles,
) ![]u8 {
    const allowance = channelAllowances(budget, encodedDemand(stdout), encodedDemand(stderr));
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"schema_version\":\"metacodes.bash-result.v2\",");
    try appendMemoryChannel(&aw.writer, allocator, "stdout", stdout, artifact_root, capture_complete, allowance.first, metrics, attachments);
    try aw.writer.writeByte(',');
    try appendMemoryChannel(&aw.writer, allocator, "stderr", stderr, artifact_root, capture_complete, allowance.second, metrics, attachments);
    try aw.writer.print(",\"exit_code\":{d}}}", .{exit_code});
    return try aw.toOwnedSlice();
}

fn appendMemoryChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    bytes: []const u8,
    artifact_root: []const u8,
    capture_complete: bool,
    allowance: result_budget.Encoded,
    metrics: ?*ResultMetrics,
    attachments: *tool_result.SealedHandles,
) !void {
    const digest = sha256Hex(bytes);
    var preview = try headTailPreview(allocator, bytes, allowance);
    defer preview.deinit();
    // Spill only when the preview actually elides something. Deciding from
    // the preview instead of from a size threshold means a channel that fits
    // the allowance whole is never spilled, and a spill always corresponds to
    // bytes the model cannot otherwise see. The spill is *sealed*, not
    // published (#73): the receipt the JSON names is fixed here, the blob is
    // installed by the batch commit boundary.
    var storage_error: ?[]const u8 = null;
    const stored: ?artifact.Receipt = if (preview.shown_source_bytes < bytes.len) blk: {
        break :blk sealBytes(allocator, artifact_root, bytes, label, preview.base64, capture_complete, attachments) catch |err| {
            storage_error = artifact.storageErrorCode(err);
            break :blk null;
        };
    } else null;
    try appendChannel(writer, allocator, label, preview.content, preview.base64, preview.shown_source_bytes, bytes.len, digest, stored, capture_complete, storage_error, metrics);
}

/// Seal one channel's in-memory bytes as an attachment of the result (#73)
/// and return the receipt the JSON embeds. The handle joins `attachments`;
/// the caller's `errdefer attachments.discard()` covers every later failure.
fn sealBytes(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    bytes: []const u8,
    label: []const u8,
    base64: bool,
    capture_complete: bool,
    attachments: *tool_result.SealedHandles,
) !artifact.Receipt {
    var spool = try artifact.Spool.begin(allocator, artifact_root);
    defer spool.deinit(); // a no-op once `seal` has taken the buffers
    try spool.write(bytes);
    var sealed = try spool.seal();
    errdefer sealed.deinit();
    const receipt = sealed.receipt();
    try attachments.append(.{
        .spool = sealed,
        .media_type = if (base64) .binary else .text_utf8,
        .capture_complete = capture_complete,
        .attachment_label = label,
    });
    return receipt;
}

/// Seal a copy of one channel's job spool file as an attachment (#73); the
/// job registry keeps releasing its own file as before.
fn sealFile(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    path: []const u8,
    inspected: artifact.FileSnapshot,
    label: []const u8,
    base64: bool,
    attachments: *tool_result.SealedHandles,
) !artifact.Receipt {
    var sealed = try artifact.sealFileCopy(allocator, artifact_root, path, inspected);
    errdefer sealed.deinit();
    const receipt = sealed.receipt();
    try attachments.append(.{
        .spool = sealed,
        .media_type = if (base64) .binary else .text_utf8,
        .capture_complete = true,
        .attachment_label = label,
    });
    return receipt;
}

fn appendFileChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    artifact_root: []const u8,
    allowance: result_budget.Encoded,
    metrics: ?*ResultMetrics,
    attachments: *tool_result.SealedHandles,
) !void {
    const inspected = artifact.inspectFile(allocator, path) catch |inspect_error| {
        const observed_bytes = artifact.observeFileBytes(allocator, path) catch 0;
        var preview: ChannelPreview = if (observed_bytes > 0)
            headTailFilePreview(allocator, path, observed_bytes, allowance) catch .{
                .content = try allocator.dupe(u8, ""),
                .shown_source_bytes = 0,
                .allocator = allocator,
            }
        else
            .{ .content = try allocator.dupe(u8, ""), .shown_source_bytes = 0, .allocator = allocator };
        defer preview.deinit();
        // Say why it actually failed. Hard-coding `artifact_too_large` here
        // reported a capture past MAX_ARTIFACT_BYTES for every cause there is -
        // an unreadable spool, a permission or safety rejection, a file that
        // changed underneath the run - and the model, told the output was
        // merely too big, has no reason to suspect anything else went wrong.
        try appendChannel(writer, allocator, label, preview.content, preview.base64, preview.shown_source_bytes, observed_bytes, null, null, false, artifact.storageErrorCode(inspect_error), metrics);
        return;
    };
    var preview = try headTailFilePreview(allocator, path, inspected.bytes, allowance);
    defer preview.deinit();
    var storage_error: ?[]const u8 = null;
    const stored: ?artifact.Receipt = if (preview.shown_source_bytes < inspected.bytes) blk: {
        break :blk sealFile(allocator, artifact_root, path, inspected, label, preview.base64, attachments) catch |err| {
            storage_error = artifact.storageErrorCode(err);
            break :blk null;
        };
    } else null;
    try appendChannel(writer, allocator, label, preview.content, preview.base64, preview.shown_source_bytes, inspected.bytes, inspected.sha256, stored, true, storage_error, metrics);
}

fn appendChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    preview: []const u8,
    /// The encoding the preview's budget was spent in. Re-deriving it here
    /// from `preview` is what let the two disagree; see `ChannelPreview`.
    preview_base64: bool,
    shown_source_bytes: u64,
    captured_bytes: u64,
    digest: ?[64]u8,
    stored: ?artifact.Receipt,
    capture_complete: bool,
    storage_error: ?[]const u8,
    metrics: ?*ResultMetrics,
) !void {
    if (metrics) |m| m.recordCapturedStream(captured_bytes);
    if (captured_bytes > shown_source_bytes) {
        if (stored != null) {
            if (metrics) |m| m.recordDirectArtifact(captured_bytes);
        } else if (metrics) |m| {
            m.recordDirectFallback();
        }
    }
    try writer.print("\"{s}\":", .{label});
    if (!preview_base64) {
        try std.json.Stringify.encodeJsonString(preview, .{}, writer);
        try writer.print(",\"{s}_encoding\":\"utf-8\"", .{label});
    } else {
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(preview.len));
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, preview);
        try std.json.Stringify.encodeJsonString(encoded, .{}, writer);
        try writer.print(",\"{s}_encoding\":\"base64\"", .{label});
    }
    try writer.print(",\"{s}_captured_bytes\":{d},\"{s}_original_bytes\":", .{ label, captured_bytes, label });
    if (capture_complete) try writer.print("{d}", .{captured_bytes}) else try writer.writeAll("null");
    try writer.print(",\"{s}_sha256\":", .{label});
    if (digest) |committed_digest| {
        try writer.print("\"{s}\"", .{committed_digest[0..]});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"{s}_capture_complete\":{s},\"{s}_truncated\":{s},\"{s}_artifact_id\":", .{
        label,
        if (capture_complete) "true" else "false",
        label,
        if (captured_bytes > shown_source_bytes) "true" else "false",
        label,
    });
    if (stored) |receipt| {
        try std.json.Stringify.encodeJsonString(receipt.id(), .{}, writer);
        try writer.print(",\"{s}_recoverable\":true,\"{s}_read\":{{\"tool\":\"ReadArtifact\",\"artifact_id\":", .{ label, label });
        try std.json.Stringify.encodeJsonString(receipt.id(), .{}, writer);
        try writer.writeAll(",\"offset\":0,\"limit_max\":32768}");
    } else {
        try writer.writeAll("null");
        try writer.print(",\"{s}_recoverable\":{s}", .{ label, if (captured_bytes <= shown_source_bytes and capture_complete) "true" else "false" });
    }
    // The generic projection envelope has always reported why a publish
    // failed; this family reported only `recoverable:false`, so a full disk
    // and a permanently exhausted session quota looked identical. Same codes,
    // from the same mapper, so the two families cannot drift.
    if (storage_error) |code| {
        try writer.print(",\"{s}_storage_error\":", .{label});
        try std.json.Stringify.encodeJsonString(code, .{}, writer);
    }
}

/// The cut and cost primitives live in `result_budget` so this file and
/// `result_projection` cut previews the same way.
const encodedCost = result_budget.encodedCost;
const cutHeadEncoded = result_budget.headCut;
const cutTailEncoded = result_budget.tailCut;

/// Head/tail split of one encoded allowance, three quarters to the head.
/// The budget is spent in **encoded** bytes: cutting on source length instead
/// would let a quote- or newline-dense channel render at up to twice the
/// allowance it was sized against, which on a wide window is the difference
/// between fitting the per-result budget and having the whole envelope spilled
/// again by the projection layer.
fn splitPreviewBudget(
    head_source: []const u8,
    tail_source: []const u8,
    max_encoded: result_budget.Encoded,
    base64: bool,
) struct { head: result_budget.Source, tail: result_budget.Source } {
    const head_cut = cutHeadEncoded(head_source, max_encoded.scaled(3, 4), base64);
    const spent = encodedCost(head_cut.head(head_source), base64);
    const tail_cut = cutTailEncoded(tail_source, max_encoded.minus(spent), base64);
    return .{ .head = head_cut, .tail = tail_cut };
}

/// Head/tail lengths for one channel under one encoding. `marker` records
/// whether the two halves are separated by the omission marker, so the cost of
/// the marker is only charged when it is actually emitted.
const PreviewPlan = struct { head: result_budget.Source, tail: result_budget.Source, marker: bool };

fn planPreview(bytes: []const u8, max_encoded: result_budget.Encoded, base64: bool) PreviewPlan {
    const none = result_budget.Source.of(0);
    if (encodedCost(bytes, base64).lte(max_encoded))
        return .{ .head = result_budget.Source.of(bytes.len), .tail = none, .marker = false };
    const marker_cost = encodedCost(PREVIEW_OMISSION_MARKER, base64);
    if (max_encoded.lte(marker_cost))
        return .{ .head = cutHeadEncoded(bytes, max_encoded, base64), .tail = none, .marker = false };
    const budget = max_encoded.minus(marker_cost);
    const head_cut = cutHeadEncoded(bytes, budget.scaled(3, 4), base64);
    const head = head_cut.head(bytes);
    const tail_cut = cutTailEncoded(head_cut.rest(bytes), budget.minus(encodedCost(head, base64)), base64);
    return .{ .head = head_cut, .tail = tail_cut, .marker = true };
}

/// Whether the bytes this plan actually shows are inline-safe. The omission
/// marker is plain ASCII, so it cannot change the answer.
fn planIsInlineUtf8(bytes: []const u8, plan: PreviewPlan) bool {
    return isInlineUtf8(plan.head.head(bytes)) and isInlineUtf8(plan.tail.tail(bytes));
}

fn headTailPreview(allocator: std.mem.Allocator, bytes: []const u8, max_encoded: result_budget.Encoded) !ChannelPreview {
    // Plan under JSON escaping first. That is both the common case and the
    // expensive one (2:1 against base64's 4:3), so a plan that turns out to be
    // inline-safe is already paid for. Only when the shown region is *not*
    // inline-safe is the plan redone under base64 - and the decision is then
    // carried in the returned preview, so the renderer cannot pick the other
    // one from a cut the budget never saw.
    var base64 = false;
    var plan = planPreview(bytes, max_encoded, false);
    if (!planIsInlineUtf8(bytes, plan)) {
        base64 = true;
        plan = planPreview(bytes, max_encoded, true);
    }
    const content = if (plan.marker)
        try std.mem.concat(allocator, u8, &.{
            plan.head.head(bytes),
            PREVIEW_OMISSION_MARKER,
            plan.tail.tail(bytes),
        })
    else
        try allocator.dupe(u8, plan.head.head(bytes));
    return .{
        .content = content,
        .shown_source_bytes = plan.head.plus(plan.tail).raw(),
        .base64 = base64,
        .allocator = allocator,
    };
}

fn headTailFilePreview(allocator: std.mem.Allocator, path: []const u8, total_bytes: u64, max_encoded: result_budget.Encoded) !ChannelPreview {
    if (max_encoded.raw() == 0) {
        return .{ .content = try allocator.dupe(u8, ""), .shown_source_bytes = 0, .allocator = allocator };
    }
    // The crossing, written down: an encoded byte never costs less than the
    // source byte it came from, so the encoded allowance is a safe upper bound
    // on how many source bytes could possibly fit - and it bounds the read for
    // a spool that may be gigabytes. This was one variable serving as both
    // units before the units became types.
    const read_bound = result_budget.Source.of(max_encoded.raw());
    if (total_bytes <= read_bound.raw()) {
        const whole = try readWholeFile(path, allocator, read_bound.raw());
        defer allocator.free(whole);
        return try headTailPreview(allocator, whole, max_encoded);
    }
    const head_read: usize = read_bound.raw() * 3 / 4;
    const tail_read: usize = read_bound.raw() - head_read;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buffer.len) return error.PathTooLong;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const fd = pfs.open(@ptrCast(&path_buffer), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);

    const scratch = try allocator.alloc(u8, head_read + tail_read);
    defer allocator.free(scratch);
    try readExactFd(fd, scratch[0..head_read]);
    const tail_offset: i64 = @intCast(total_bytes - tail_read);
    if (pfs.lseek(fd, tail_offset, .set) != tail_offset) return error.SeekFailed;
    try readExactFd(fd, scratch[head_read..]);
    const head_raw = scratch[0..head_read];
    const tail_raw = scratch[head_read..];

    // Decide the encoding from the *aligned* cuts, not from the raw chunks: a
    // read boundary that lands mid-codepoint would otherwise base64 an
    // ordinary text file. Plan under JSON escaping first for the same reason
    // as the in-memory path, and cut against the same budget both times so the
    // decision and the cut it produced always belong together.
    var base64 = false;
    var cut = splitPreviewBudget(
        head_raw,
        tail_raw,
        max_encoded.minus(encodedCost(PREVIEW_OMISSION_MARKER, false)),
        false,
    );
    if (!isInlineUtf8(cut.head.head(head_raw)) or !isInlineUtf8(cut.tail.tail(tail_raw))) {
        base64 = true;
        cut = splitPreviewBudget(
            head_raw,
            tail_raw,
            max_encoded.minus(encodedCost(PREVIEW_OMISSION_MARKER, true)),
            true,
        );
    }
    // An allowance smaller than the marker itself cannot afford to say that
    // something was omitted; emitting it anyway is the one way this path can
    // exceed the budget it was given. `planPreview` makes the same call for
    // the in-memory path.
    const content = if (encodedCost(PREVIEW_OMISSION_MARKER, base64).lte(max_encoded))
        try std.mem.concat(allocator, u8, &.{
            cut.head.head(head_raw),
            PREVIEW_OMISSION_MARKER,
            cut.tail.tail(tail_raw),
        })
    else
        try allocator.dupe(u8, cut.head.head(head_raw));
    return .{
        .content = content,
        .shown_source_bytes = cut.head.plus(cut.tail).raw(),
        .base64 = base64,
        .allocator = allocator,
    };
}

fn readExactFd(fd: pfs.Fd, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
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

fn formatCompletedFiles(
    allocator: std.mem.Allocator,
    stdout_path: []const u8,
    stderr_path: []const u8,
    exit_code: i32,
    artifact_root: []const u8,
    budget: result_budget.Budget,
    metrics: ?*ResultMetrics,
    attachments: *tool_result.SealedHandles,
) ![]u8 {
    // The split needs real demand: giving each channel a fixed half would
    // forfeit half the allowance to the empty stderr that most commands
    // produce, and overstating a small channel takes the difference straight
    // out of the large one.
    const payload = budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES);
    const allowance = channelAllowances(
        budget,
        fileEncodedDemand(allocator, stdout_path, payload),
        fileEncodedDemand(allocator, stderr_path, payload),
    );
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"schema_version\":\"metacodes.bash-result.v2\",");
    try appendFileChannel(&aw.writer, allocator, "stdout", stdout_path, artifact_root, allowance.first, metrics, attachments);
    try aw.writer.writeByte(',');
    try appendFileChannel(&aw.writer, allocator, "stderr", stderr_path, artifact_root, allowance.second, metrics, attachments);
    try aw.writer.print(",\"exit_code\":{d}}}", .{exit_code});
    return aw.toOwnedSlice();
}

/// Execution-time entry for callers without a batch commit boundary (the
/// `!cmd` shell in `session_service.zig`, embedders): the channel spills are
/// sealed and then resolved right here — published, or withdrawn from the JSON
/// when publication fails — so the returned bytes never name a blob that does
/// not exist. The agent loop uses `executeBody`, which leaves the handles
/// sealed for `publishSealedResults` (#73).
pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    var attachments = tool_result.SealedHandles{};
    errdefer attachments.discard();
    const json = try executeInner(ctx, args, &attachments);
    return tool_result.resolveAttachments(ctx.allocator, json, &attachments);
}

fn executeInner(ctx: *const ToolContext, args: []const u8, attachments: *tool_result.SealedHandles) anyerror![]u8 {
    const allocator = ctx.allocator;
    const command_escaped = common.extractJsonArg(args, "command") orelse return error.MissingCommand;
    if (command_escaped.len == 0) return error.EmptyCommand;
    // extractJsonArg 返回的是【含原始 JSON 转义】的串(如 `>`→`>`、换行→`\n`)。
    // 必须 unescape 后才能交给 /bin/sh,否则重定向 `>`、换行等会被当字面量丢失。
    // (对齐 edit.zig 对 old_string/new_string 的处理)
    const raw_command = try util_json.unescapeString(command_escaped, allocator);
    defer allocator.free(raw_command);
    if (raw_command.len == 0) return error.EmptyCommand;
    try security.validateBashCommand(raw_command);

    // A governed Run owns one synchronous observation/formal-decision
    // lifetime.  A background command would return a successful tool result
    // while its real effects continue after the post gate and Run terminal
    // receipt, so reject the explicit detached path before any process is
    // created.  The foreground path below also bypasses JobRegistry while a
    // project gate is active, preventing the 15-second auto-background path.
    if (ctx.project_rule_gate != null and
        (util_json.extractBoolField(args, "run_in_background") orelse false))
        return error.ProjectRulesRequireSynchronousExecution;

    // description 仅作日志用途，本期透传但不输出
    _ = common.extractJsonArg(args, "description");

    // Sandbox 包裹(macOS Seatbelt):若 ctx.sandbox 启用,把 command 改写成
    // `sandbox-exec -f <profile> /bin/bash -c <cmd>`。dangerouslyDisableSandbox=true 跳过。
    // sandbox_wrap 非 null 时持有临时 profile 文件,函数返回前 deinit 清理。
    const disable_sb = blk: {
        if (common.extractJsonArg(args, "dangerouslyDisableSandbox")) |v| {
            break :blk std.mem.eql(u8, v, "true");
        }
        break :blk false;
    };
    var sandbox_wrap: ?@import("../sandbox/exec.zig").ShellWrap = null;
    defer if (sandbox_wrap) |*sw| sw.deinit();
    const command: []const u8 = blk: {
        const sb = ctx.sandbox orelse break :blk raw_command;
        if (!sb.enabled) break :blk raw_command;
        const sandbox_exec = @import("../sandbox/exec.zig");
        const cwd = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else ".";
        const maybe = sandbox_exec.wrapAsShellString(allocator, raw_command, .{
            .cwd = cwd,
            .home = ctx.home_dir,
            .sandbox = sb,
            .additional_dirs = ctx.additional_dirs,
            .disable_for_this_command = disable_sb,
        }) catch |e| {
            // failIfUnavailable=true 时沙箱不可用 → 拒绝执行(不降级裸跑)
            if (e == error.SandboxUnavailable) return error.SandboxUnavailable;
            // 其它 error(profile 写失败等):降级 passthrough
            break :blk raw_command;
        };
        if (maybe) |sw| {
            sandbox_wrap = sw;
            break :blk sw.command;
        }
        break :blk raw_command;
    };

    // 显式 run_in_background=true：直接丢 job 表立刻返
    if (common.extractJsonArg(args, "run_in_background")) |v| {
        if (std.mem.eql(u8, v, "true")) {
            if (ctx.jobs) |registry| {
                // 后台:profile 文件不能删(进程还在跑),detach
                if (sandbox_wrap) |*sw| sw.detached = true;
                const cwd_opt: ?[]const u8 = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else null;
                const j = try registry.spawnBackground(command, cwd_opt);
                // Same rule as the auto-backgrounded snapshot: the spool is a
                // staging path and never model-visible. BashOutput polls by
                // job_id and reads incrementally.
                return try std.fmt.allocPrint(allocator, "{{\"job_id\":\"{s}\",\"status\":\"started\"}}", .{j.id[0..]});
            }
        }
    }

    const timeout_ms: u64 = blk: {
        if (common.extractJsonArg(args, "timeout")) |s| {
            const parsed = std.fmt.parseInt(u64, s, 10) catch DEFAULT_TIMEOUT_MS;
            break :blk @min(parsed, MAX_TIMEOUT_MS);
        }
        break :blk DEFAULT_TIMEOUT_MS;
    };

    // 同步路径 + 自动转后台：
    // 短命令（常态）走原 pipe 捕获；长命令达到 AUTO_BACKGROUND_MS 时转为后台 job。
    //
    // 策略：用 job_registry 一开始就 spawn 到落盘文件；父端 poll 等待，达到
    // min(timeout, AUTO_BACKGROUND_MS) 时决定：
    //   - 进程已退出 → 读 stdout/stderr 文件返回
    //   - 未退出 + 达到 AUTO_BACKGROUND_MS & ctx.jobs 可用 → 返回 {auto_backgrounded, job_id}
    //   - 未退出 + 达到用户 timeout → kill + error.Timeout
    if (ctx.jobs) |registry| {
        // Start spooling at byte zero even for governed synchronous runs. A
        // project-rule gate disables only auto-backgrounding; the process is
        // still awaited before PostToolUse/formal re-observation.
        if (sandbox_wrap) |*sw| sw.detached = true;
        const cwd_opt: ?[]const u8 = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else null;
        return try runAutoBackgroundable(
            allocator,
            registry,
            command,
            timeout_ms,
            ctx.abort,
            cwd_opt,
            ctx.artifact_root,
            ctx.project_rule_gate == null,
            ctx.result_budget,
            ctx.tool_result_metrics,
            attachments,
        );
    }

    // Source embedders may provide artifact storage without a long-lived job
    // registry. Preserve the byte-zero contract by using a transient registry
    // for this synchronous call; never fall back to the 16MiB pipe buffer when
    // the kernel has a recoverable result plane available.
    if (ctx.artifact_root.len != 0) {
        var transient_jobs = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
        defer transient_jobs.deinit();
        const cwd_opt: ?[]const u8 = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else null;
        return try runAutoBackgroundable(
            allocator,
            &transient_jobs,
            command,
            timeout_ms,
            ctx.abort,
            cwd_opt,
            ctx.artifact_root,
            false,
            ctx.result_budget,
            ctx.tool_result_metrics,
            attachments,
        );
    }

    // 可移植 shell(复刻 codex):POSIX /bin/sh -c;Windows 原生 PowerShell/cmd,零 git-bash。
    // wrapCommand:PowerShell 前置 UTF-8 输出编码(否则非 ASCII 输出乱码/stringify 失败)。
    const shell = shell_mod.detectDefault();
    const cmd_z = try shell_mod.wrapCommand(allocator, shell, command);
    defer allocator.free(cmd_z);
    var argv: [6]?[*:0]const u8 = undefined;
    shell_mod.deriveExecArgs(shell, cmd_z.ptr, &argv);
    const cwd_opt: ?[]const u8 = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else null;
    const out = try common.spawnCaptureWithStderrTimed(argv[0..], allocator, ctx.abort, timeout_ms, ctx.spawn_tick_fn, common.MAX_SPAWN_CAPTURE_BYTES, cwd_opt);
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);

    // 无 JobRegistry 也无 artifact root 的兜底路径:管道捕获后按预算做头尾预览。
    return try formatCompletedOutput(allocator, out.stdout, out.stderr, out.exit_code, ctx.artifact_root, out.capture_complete, ctx.result_budget, ctx.tool_result_metrics, attachments);
}

/// Bash already redirects stdout/stderr to JobRegistry files before the child
/// emits byte zero. Its model-visible completion is bounded JSON containing
/// per-channel receipts/previews, so the typed boundary remains inline; the
/// spilled channels travel beside it as sealed attachments and are published
/// by the batch commit boundary, so a fatal sibling leaves no blob (#73).
pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    var attachments = tool_result.SealedHandles{};
    errdefer attachments.discard();
    const json = try executeInner(ctx, args, &attachments);
    return .{ .@"inline" = .{ .bytes = json, .attachments = attachments } };
}

/// 新路径：总是 spawn 到 job_registry（stdout/stderr 落盘），父端轮询等待。
/// - 若在 AUTO_BACKGROUND_MS 内进程退出 → 读文件返回正常 {stdout,stderr,exit_code}
/// - 若超过 AUTO_BACKGROUND_MS 仍未结束 → 返回 {auto_backgrounded,job_id,partial_stdout,partial_stderr}
/// - 若达到 user timeout_ms 仍未结束 → kill + error.Timeout
fn runAutoBackgroundable(
    allocator: std.mem.Allocator,
    registry: *@import("../core/job_registry.zig").JobRegistry,
    command: []const u8,
    timeout_ms: u64,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    cwd: ?[]const u8,
    artifact_root: []const u8,
    allow_auto_background: bool,
    budget: result_budget.Budget,
    metrics: ?*ResultMetrics,
    attachments: *tool_result.SealedHandles,
) ![]u8 {
    // Spooled as private to this call. Every exit below either renders the
    // output and releases the files, or hands the job id to the model and
    // promotes the job so its spool survives for `BashOutput` (issue #37).
    const j_entry = try registry.spawnSynchronous(command, cwd);
    const job_id = j_entry.id; // 值拷贝，不持指针（registry 可能扩容移动）

    const effective_budget = if (allow_auto_background) @min(timeout_ms, AUTO_BACKGROUND_MS) else timeout_ms;
    const start = nowMs();
    // 轮询循环
    while (true) {
        if (abort) |a| if (a.isAborted()) {
            registry.kill(job_id[0..]) catch {};
            registry.releaseSpool(job_id[0..]);
            return error.Aborted;
        };
        util_time.sleepMs(100);

        registry.reapExited();
        const j = registry.get(job_id[0..]) orelse return error.JobNotFound; // 值快照
        if (j.status != .running) {
            // 正常退出：读文件构造完整输出。渲染完成（含 CAS 导入）后 spool 无人
            // 再读——包括非零退出码与渲染失败这两条路径。
            defer registry.releaseSpool(job_id[0..]);
            return try readJobAsSync(allocator, &j, artifact_root, budget, metrics, attachments);
        }

        const elapsed: u64 = @intCast(nowMs() - start);
        if (elapsed >= timeout_ms) {
            // 真 timeout：kill + 错误
            registry.kill(job_id[0..]) catch {};
            registry.releaseSpool(job_id[0..]);
            return error.Timeout;
        }
        if (allow_auto_background and elapsed >= effective_budget) {
            // 达到 auto-background 阈值但未到 timeout：返回 auto_backgrounded。
            // 此刻 job id 进入模型可见结果，BashOutput 随后任何一轮都可能凭它来读
            // → 转为 background 保留期。
            registry.promoteToBackground(job_id[0..]);
            return try formatAutoBackgroundedAndRemember(allocator, &j, registry);
        }
    }
}

fn readJobAsSync(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry, artifact_root: []const u8, budget: result_budget.Budget, metrics: ?*ResultMetrics, attachments: *tool_result.SealedHandles) ![]u8 {
    return try formatCompletedFiles(allocator, j.stdout_path, j.stderr_path, j.exit_code orelse 0, artifact_root, budget, metrics, attachments);
}

fn formatAutoBackgrounded(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry) ![]u8 {
    return formatAutoBackgroundedAndRemember(allocator, j, null);
}

fn formatAutoBackgroundedAndRemember(
    allocator: std.mem.Allocator,
    j: *const @import("../core/job_registry.zig").JobEntry,
    registry: ?*@import("../core/job_registry.zig").JobRegistry,
) ![]u8 {
    const out_bytes = readWholeFile(j.stdout_path, allocator, common.MAX_SPAWN_CAPTURE_BYTES) catch try allocator.dupe(u8, "");
    defer allocator.free(out_bytes);
    const err_bytes = readWholeFile(j.stderr_path, allocator, common.MAX_SPAWN_CAPTURE_BYTES) catch try allocator.dupe(u8, "");
    defer allocator.free(err_bytes);

    const out_trunc = try truncateHead(allocator, out_bytes);
    defer allocator.free(out_trunc);
    const err_trunc = try truncateHead(allocator, err_bytes);
    defer allocator.free(err_trunc);

    // The auto-background result already exposed these head bytes. Remember
    // exactly the shown prefix so the first BashOutput call starts after it;
    // truncateHead's length is the authority, never the full spool size.
    if (registry) |r| r.updateReadCursors(
        j.idSlice(),
        truncateHeadSourceBytes(out_bytes),
        truncateHeadSourceBytes(err_bytes),
    );

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // No staging path here either. `job_id` is the stable handle - it is what
    // BashOutput takes, it does not move between runs of the same command, and
    // it names no host temp directory. Handing back the spool path instead
    // made the same command serialize differently on every run, which is the
    // prompt-cache contract's "random ids" and "staging paths" clauses at once.
    try aw.writer.writeAll("{\"auto_backgrounded\":true,\"job_id\":");
    try std.json.Stringify.encodeJsonString(j.id[0..], .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stdout\":");
    try std.json.Stringify.encodeJsonString(out_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stderr\":");
    try std.json.Stringify.encodeJsonString(err_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"note\":\"Command exceeded 15s; moved to background. BashOutput waits for new lines or exit, so no sleep loop is needed; use this job_id to read incrementally.\"}");
    return try aw.toOwnedSlice();
}

/// 读文件到内存,**上限 max_bytes**(轴A OOM 防线):job 输出文件可能很大(命令疯产 GB 落盘),
/// 而调用方要的只是一个有界前缀 → 读够 cap 就停,防整读 OOM。max_bytes=0 不限。
/// cap 由调用方按各自预算给(preview 给 `max_encoded`、demand 测量给文件真实大小、
/// 部分快照给 `common.MAX_SPAWN_CAPTURE_BYTES`),这里不再钉死某一个常量。
fn readWholeFile(path: []const u8, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        if (max_bytes > 0 and out.items.len >= max_bytes) break;
        const wanted = if (max_bytes > 0) @min(buf.len, max_bytes - out.items.len) else buf.len;
        const n = pfs.read(fd, buf[0..wanted]);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "BashTool missing command" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingCommand, execute(&ctx, "{\"x\":\"y\"}"));
}

test "BashTool dangerous blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.DangerousCommand, execute(&ctx, "{\"command\":\"rm -rf /\"}"));
}

test "BashTool echo" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo hello\"}");
    defer std.testing.allocator.free(result);
    // JSON 返回：{"stdout":"hello\n","stderr":"","exit_code":0}
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":0") != null);
}

test "BashTool stderr captured separately" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // bash 语法命令经 PowerShell 输出/stderr 语义不同,POSIX 专属
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo out; echo err 1>&2; exit 7\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"out\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stderr\":\"err\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":7") != null);
}

test "BashTool nonzero exit visible" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"ls /nonexistent 2>&1; exit 2\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":2") != null);
}

test "BashTool timeout triggers" {
    const ctx = testCtx();
    // sleep 10 with timeout=500ms → 应 Timeout
    const result = execute(&ctx, "{\"command\":\"sleep 10\",\"timeout\":500}");
    try std.testing.expectError(error.Timeout, result);
}

test "BashTool timeout over ms grain is enforced" {
    const ctx = testCtx();
    const t0 = nowMs();
    const result = execute(&ctx, "{\"command\":\"sleep 10\",\"timeout\":300}");
    try std.testing.expectError(error.Timeout, result);
    const dt = nowMs() - t0;
    // killGroup 含 2s SIGTERM 等待期；总耗时 ≈ 300 + ≤2000 < 3000
    try std.testing.expect(dt < 3000);
}

test "BashTool description is parsed without error" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo ok\",\"description\":\"test echo\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "ok") != null);
}

test "BashTool auto-backgrounds after 15s" {
    // 构造 ctx 带 jobs；短测不跑完整 15s；直接验证 run_in_background 路径
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();

    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const result = try execute(&ctx, "{\"command\":\"sleep 30\",\"run_in_background\":\"true\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"job_id\":") != null);

    // 清理
    for (registry.jobs.items) |*j| {
        if (j.status == .running) registry.kill(j.idSlice()) catch {};
    }
}

test "formatAutoBackgrounded 交出稳定的 job_id,而不是 staging 路径" {
    // 曾经交出 stdout_path/stderr_path 让模型直接 Read。但 doc/API.md 的
    // prompt-cache contract 把 staging path 与随机 id 都列为 never
    // model-visible,而 JobRegistry spool 路径两者皆是:同一条命令每次运行都会
    // 因随机 job 目录改变 provider 可见字节,并泄露宿主临时目录。job_id 是稳定
    // 句柄,BashOutput 用它增量读,能力不减。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const j = try registry.spawnBackground("echo hi; sleep 30", null);
    defer registry.kill(j.idSlice()) catch {};
    const result = try formatAutoBackgrounded(a, &j);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"auto_backgrounded\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"job_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "partial_stdout") != null);
    // staging 路径一个都不许出现——字段名与真实路径都不行。
    try std.testing.expect(std.mem.indexOf(u8, result, "stdout_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "stderr_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, j.stdout_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, result, j.stderr_path) == null);
    // note 改为引导 BashOutput + job_id 增量读。
    try std.testing.expect(std.mem.indexOf(u8, result, "BashOutput") != null);
}

test "completed job output becomes a bounded recoverable channel artifact" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
    defer registry.deinit();
    const spawned = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<40000;i++) printf \"x\"; printf \"BASH_TAIL\" }'", null);
    util_time.sleepMs(300);
    registry.reapExited();
    const job = registry.get(spawned.idSlice()) orelse return error.JobNotFound;
    var metrics = ResultMetrics{};
    var attachments = tool_result.SealedHandles{};
    defer attachments.discard();
    const result = try readJobAsSync(allocator, &job, root, .floor, &metrics, &attachments);
    try testPublishAttachments(&attachments);
    defer allocator.free(result);
    try std.testing.expect(result.len < 8 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, result, root) == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const artifact_id = parsed.value.object.get("stdout_artifact_id").?.string;
    try std.testing.expect(parsed.value.object.get("stdout_recoverable").?.bool);
    try std.testing.expectEqual(@as(i64, 40_009), parsed.value.object.get("stdout_original_bytes").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.object.get("stdout").?.string, "...[middle omitted]...") != null);
    try std.testing.expect(std.mem.endsWith(u8, parsed.value.object.get("stdout").?.string, "BASH_TAIL"));
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot().artifact_spill_count);
    try std.testing.expectEqual(@as(u64, 40_009), metrics.snapshot().captured_stream_bytes);
    // The JobRegistry spool is a staging path with a random job id in it, and
    // `doc/API.md`'s prompt-cache contract lists both as never model-visible.
    // Recovery goes through the content-addressed artifact id instead, which is
    // stable for identical output.
    try std.testing.expect(parsed.value.object.get("stdout_path") == null);
    try std.testing.expect(parsed.value.object.get("stderr_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, job.stdout_path) == null);
    var tail = try artifact.readChunk(allocator, root, artifact_id, 39_990, 32);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "BASH_TAIL") != null);
}

test "BashTool embedding without JobRegistry still spools from byte zero" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // Deliberately omit `jobs`: an embedding that supplies the artifact plane
    // must still enter the file-backed process path before the first byte.
    const ctx = ToolContext{ .allocator = allocator, .artifact_root = root };
    var body = try executeBody(&ctx, "{\"command\":\"awk 'BEGIN { for(i=0;i<40000;i++) printf \\\"x\\\"; printf \\\"EMBED_TAIL\\\" }'\"}");
    defer body.deinit(allocator);
    const encoded = switch (body) {
        .@"inline" => |result| result.bytes,
        else => return error.UnexpectedResultBody,
    };
    try std.testing.expect(encoded.len < 8 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, encoded, root) == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const artifact_id = parsed.value.object.get("stdout_artifact_id").?.string;
    try std.testing.expect(parsed.value.object.get("stdout_recoverable").?.bool);
    try std.testing.expectEqual(@as(i64, 40_010), parsed.value.object.get("stdout_original_bytes").?.integer);
    // The spilled channel is a sealed attachment (#73): nothing is in the CAS
    // until the batch commit boundary publishes it.
    const cas = try std.fmt.allocPrint(allocator, "{s}/tool-results/sha256", .{root});
    defer allocator.free(cas);
    try std.testing.expectEqual(@as(usize, 0), try testCountDirectory(allocator, cas));
    var handles = body.takeSealedHandles();
    try testPublishAttachments(&handles);
    var tail = try artifact.readChunk(allocator, root, artifact_id, 39_990, 32);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "EMBED_TAIL") != null);

    // No staging path reaches the model here either; the artifact id above is
    // the whole recovery surface, and `Grep(artifact_id)` searches it in place.
    try std.testing.expect(parsed.value.object.get("stdout_path") == null);
}

fn spoolExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    _ = pfs.close(fd);
    return true;
}

test "a synchronous run leaves no spool behind once its output is durable" {
    // issue #37: the durable import copied the bytes into the CAS and kept the
    // staging source, so the recoverable artifact and the raw spool both
    // survived — the second one forever.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var registry = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = allocator, .jobs = &registry, .artifact_root = root };
    // Sized past the preview allowance so the durable import actually runs —
    // the same 40000-byte fixture the recoverable-artifact test uses. Smaller
    // output fits inline, publishes nothing, and would exercise only the
    // short-output release path the next test already covers.
    const result = try execute(&ctx, "{\"command\":\"awk 'BEGIN { for(i=0;i<40000;i++) printf \\\"x\\\" }'\"}");
    defer allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    // The bytes stayed recoverable: cleanup must not cost the model its
    // ability to read the full output back.
    try std.testing.expect(parsed.value.object.get("stdout_artifact_id").? != .null);
    try std.testing.expect(parsed.value.object.get("stdout_recoverable").?.bool);

    try std.testing.expectEqual(@as(usize, 1), registry.jobs.items.len);
    const job = registry.jobs.items[0];
    try std.testing.expect(!spoolExists(job.stdout_path));
    try std.testing.expect(!spoolExists(job.stderr_path));
}

test "a synchronous run with output too small to publish still releases its spool" {
    // The short-output path never publishes an artifact at all, so a fix that
    // only unlinked after a durable import would leave these files behind —
    // and they are the common case.
    const allocator = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = allocator, .jobs = &registry };
    const result = try execute(&ctx, "{\"command\":\"echo small\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "small") != null);

    try std.testing.expectEqual(@as(usize, 1), registry.jobs.items.len);
    const job = registry.jobs.items[0];
    try std.testing.expect(!spoolExists(job.stdout_path));
    try std.testing.expect(!spoolExists(job.stderr_path));
}

test "an explicitly backgrounded run keeps its spool readable" {
    // The retention boundary in the other direction: BashOutput must still
    // find the files after the tool result has been rendered.
    const allocator = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = allocator, .jobs = &registry };
    const result = try execute(&ctx, "{\"command\":\"sleep 30\",\"run_in_background\":\"true\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"started\"") != null);

    try std.testing.expectEqual(@as(usize, 1), registry.jobs.items.len);
    const job = registry.jobs.items[0];
    try std.testing.expect(spoolExists(job.stdout_path));
    try std.testing.expect(spoolExists(job.stderr_path));
    registry.kill(job.idSlice()) catch {};
}

test "a timed-out run releases the spool of the process it killed" {
    const allocator = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(allocator);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = allocator, .jobs = &registry };
    try std.testing.expectError(
        error.Timeout,
        execute(&ctx, "{\"command\":\"sleep 30\",\"timeout\":300}"),
    );
    try std.testing.expectEqual(@as(usize, 1), registry.jobs.items.len);
    const job = registry.jobs.items[0];
    try std.testing.expect(!spoolExists(job.stdout_path));
    try std.testing.expect(!spoolExists(job.stderr_path));
}

test "over-limit completed spool reports true size without a false commitment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const stdout_path = try std.fmt.allocPrintSentinel(allocator, "{s}/oversize.log", .{root}, 0);
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrintSentinel(allocator, "{s}/empty.err", .{root}, 0);
    defer allocator.free(stderr_path);
    const stdout_fd = pfs.open(stdout_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (stdout_fd < 0) return error.OpenFailed;
    try pfs.setSize(stdout_fd, artifact.MAX_ARTIFACT_BYTES + 1);
    _ = pfs.close(stdout_fd);
    const stderr_fd = pfs.open(stderr_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (stderr_fd < 0) return error.OpenFailed;
    _ = pfs.close(stderr_fd);

    var attachments = tool_result.SealedHandles{};
    defer attachments.discard();
    const result = try formatCompletedFiles(allocator, stdout_path, stderr_path, 0, root, .floor, null, &attachments);
    try testPublishAttachments(&attachments);
    defer allocator.free(result);
    try std.testing.expect(result.len < 8 * 1024);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, artifact.MAX_ARTIFACT_BYTES + 1), parsed.value.object.get("stdout_captured_bytes").?.integer);
    try std.testing.expect(parsed.value.object.get("stdout_original_bytes").? == .null);
    try std.testing.expect(parsed.value.object.get("stdout_sha256").? == .null);
    try std.testing.expect(!parsed.value.object.get("stdout_capture_complete").?.bool);
    try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expect(!parsed.value.object.get("stdout_recoverable").?.bool);
    // A capture too large to publish has no artifact_id and no committed
    // digest, so `recoverable` stays false: there is nothing to make a
    // content-addressed promise about. `<channel>_storage_error` says so
    // explicitly - which is the honest answer, where handing back the staging
    // path would have bought recovery by breaking the prompt-cache contract.
    try std.testing.expect(parsed.value.object.get("stdout_path") == null);
    try std.testing.expect(parsed.value.object.get("stderr_path") == null);
    try std.testing.expect(parsed.value.object.get("stdout_storage_error").? != .null);
}

test "truncateHead: 小输出原样,大输出截断 + 标记" {
    const a = std.testing.allocator;
    // 小输出不截。
    const small = try truncateHead(a, "hello\nworld\n");
    defer a.free(small);
    try std.testing.expectEqualStrings("hello\nworld\n", small);

    // 大输出(> MAX_OUTPUT_BYTES)截到 ≤ 上限 + 含 truncated 标记。
    const big = try a.alloc(u8, MAX_OUTPUT_BYTES + 5000);
    defer a.free(big);
    @memset(big, 'a');
    // 撒一些换行,让回退到换行的逻辑有料。
    var i: usize = 0;
    while (i < big.len) : (i += 80) big[i] = '\n';
    const trunc = try truncateHead(a, big);
    defer a.free(trunc);
    try std.testing.expect(std.mem.indexOf(u8, trunc, "lines truncated") != null);
    // 截断后正文(不含标记)应 ≤ MAX_OUTPUT_BYTES。
    const marker = std.mem.indexOf(u8, trunc, "\n... [").?;
    try std.testing.expect(marker <= MAX_OUTPUT_BYTES);
}

test "BashTool 大输出 becomes bounded even when artifact storage is unavailable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // bash 语法命令经 PowerShell 输出/stderr 语义不同,POSIX 专属
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    // seq 到很大 → stdout 远超 inline budget。无 artifact root 时必须显式
    // recoverable=false，但仍保持合法有界 JSON，不能伪装成完整输出。
    const r = try execute(&ctx, "{\"command\":\"seq 1 100000\"}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"stdout_truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"stdout_recoverable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"stdout_capture_complete\":true") != null);
    try std.testing.expect(r.len < 8 * 1024);
    // No channel ever carries a staging path.
    try std.testing.expect(std.mem.indexOf(u8, r, "\"stdout_path\"") == null);
}

/// Run a command that writes exactly `bytes` bytes to stdout and return the
/// completed envelope, parsed. Caller deinits.
fn runSizedStdout(a: std.mem.Allocator, ctx: *const ToolContext, bytes: usize) ![]u8 {
    const command = try std.fmt.allocPrint(
        a,
        "{{\"command\":\"awk 'BEGIN {{ for(i=0;i<{d};i++) printf \\\"x\\\" }}'\"}}",
        .{bytes},
    );
    defer a.free(command);
    return try execute(ctx, command);
}

test "issue #29: output the budget can afford is delivered inline" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // The reported case: 1890 bytes of stdout, truncated to a 1536-byte
    // head/tail preview against a per-result budget whose floor is 8KiB. The
    // envelope grew by more than the truncation saved and the model lost 354
    // bytes it then spent a round-trip failing to recover.
    const ctx = ToolContext{ .allocator = a };
    const result = try runSizedStdout(a, &ctx, 1890);
    defer a.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expectEqual(@as(i64, 1890), parsed.value.object.get("stdout_original_bytes").?.integer);
    try std.testing.expectEqual(@as(usize, 1890), parsed.value.object.get("stdout").?.string.len);
    // Nothing was spilled, so nothing needs recovering.
    try std.testing.expect(parsed.value.object.get("stdout_artifact_id").? == .null);
    // And the whole envelope still fits the floor budget it was sized against.
    try std.testing.expect(result.len <= result_budget.PER_RESULT_MIN_BYTES);
}

test "the channel allowance follows the provider window" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // 10KB sits between the floor allowance (8KiB budget minus scaffolding)
    // and a 200K-window allowance (25KB minus scaffolding). The same command
    // must therefore truncate on the small window and stay whole on the large
    // one - which is exactly what a hard-coded constant could not express.
    const floor_ctx = ToolContext{ .allocator = a };
    const floor_result = try runSizedStdout(a, &floor_ctx, 10_000);
    defer a.free(floor_result);
    var floor_parsed = try std.json.parseFromSlice(std.json.Value, a, floor_result, .{});
    defer floor_parsed.deinit();
    try std.testing.expect(floor_parsed.value.object.get("stdout_truncated").?.bool);

    const wide_ctx = ToolContext{ .allocator = a, .result_budget = .fromModel(200_000) };
    const wide_result = try runSizedStdout(a, &wide_ctx, 10_000);
    defer a.free(wide_result);
    var wide_parsed = try std.json.parseFromSlice(std.json.Value, a, wide_result, .{});
    defer wide_parsed.deinit();
    try std.testing.expect(!wide_parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 10_000), wide_parsed.value.object.get("stdout").?.string.len);
    try std.testing.expect(wide_result.len <= result_budget.perResultBytes(200_000));
}

test "an empty stderr does not cost stdout half its allowance" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // A fixed half-each split would cap stdout at ~3KB of the floor budget.
    // Max-min fairness hands the empty channel's share to the one using it.
    const ctx = ToolContext{ .allocator = a };
    const result = try runSizedStdout(a, &ctx, 5000);
    defer a.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 5000), parsed.value.object.get("stdout").?.string.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("stderr").?.string.len);
}

test "a quote-dense channel is budgeted by encoded size, not source length" {
    const a = std.testing.allocator;
    // Every byte escapes to two. Budgeting by source length would render an
    // envelope at roughly twice the per-result budget it was sized against,
    // and the projection layer would spill the whole thing straight back out.
    const noisy = try a.alloc(u8, 64 * 1024);
    defer a.free(noisy);
    @memset(noisy, '"');
    const budget = result_budget.Budget.fromModel(200_000);
    var envelope_attachments = tool_result.SealedHandles{};
    defer envelope_attachments.discard();
    const envelope = try formatCompletedOutput(a, noisy, "", 0, "", true, budget, null, &envelope_attachments);
    defer a.free(envelope);
    try std.testing.expect(envelope.len <= budget.per_result_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, envelope, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    // Still a real head/tail preview, not a degenerate one.
    try std.testing.expect(parsed.value.object.get("stdout").?.string.len > 4096);
}

test "channelAllowances keeps the two channels inside one per-result budget" {
    const budget = result_budget.Budget.fromModel(200_000);
    const payload = budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES);
    // Both channels huge: the allowance is shared, never doubled.
    const even = channelAllowances(budget, .of(1 << 20), .of(1 << 20));
    try std.testing.expectEqual(payload, even.first.plus(even.second));
    // Empty stderr: stdout gets everything.
    const lopsided = channelAllowances(budget, .of(1 << 20), .of(0));
    try std.testing.expectEqual(payload, lopsided.first);
    try std.testing.expectEqual(result_budget.Encoded.of(0), lopsided.second);
    // Demands that both fit are both granted in full - the allowance is a
    // ceiling, so granting exactly what was asked for cuts nothing.
    const small = channelAllowances(budget, .of(1000), .of(20));
    try std.testing.expectEqual(result_budget.Encoded.of(1000), small.first);
    try std.testing.expectEqual(result_budget.Encoded.of(20), small.second);
}

test "a channel's demand is what it will cost, not a worst-case bound" {
    // Escape-dense content really does cost two bytes per source byte, and a
    // channel that is not inline-safe is base64'd at 4:3. Both have to be the
    // number the split sees: a bound stated for one channel is subtracted from
    // the other's share, not from thin air.
    const a = std.testing.allocator;
    const quotes = try a.alloc(u8, 1000);
    defer a.free(quotes);
    @memset(quotes, '"');
    try std.testing.expectEqual(result_budget.Encoded.of(2000), encodedDemand(quotes));

    const plain = try a.alloc(u8, 1000);
    defer a.free(plain);
    @memset(plain, 'x');
    try std.testing.expectEqual(result_budget.Encoded.of(1000), encodedDemand(plain));

    const binary = try a.alloc(u8, 999);
    defer a.free(binary);
    @memset(binary, 0x01);
    try std.testing.expectEqual(result_budget.Encoded.of(1332), encodedDemand(binary)); // 999 -> 4/3
}

test "an ordinary stdout/stderr pair that fits is not cut by the split" {
    // issue #29 in miniature. 5000 bytes of stdout beside 1000 of stderr is
    // 6000 encoded against the floor budget's 6144-byte payload allowance:
    // whole, with room to spare. Stating stdout's demand as its worst case
    // used to hand stderr 2000 of those bytes, cut stdout to 4142, spill it to
    // an artifact and mark it truncated - 858 bytes of intact output destroyed
    // and a recovery round trip bought, to save nothing.
    const a = std.testing.allocator;
    const out = try a.alloc(u8, 5000);
    defer a.free(out);
    @memset(out, 'x');
    const err = try a.alloc(u8, 1000);
    defer a.free(err);
    @memset(err, 'e');
    var envelope_attachments = tool_result.SealedHandles{};
    defer envelope_attachments.discard();
    const envelope = try formatCompletedOutput(a, out, err, 0, "", true, .floor, null, &envelope_attachments);
    defer a.free(envelope);
    try std.testing.expect(envelope.len <= result_budget.PER_RESULT_MIN_BYTES);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, envelope, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expect(!parsed.value.object.get("stderr_truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 5000), parsed.value.object.get("stdout").?.string.len);
    try std.testing.expectEqual(@as(usize, 1000), parsed.value.object.get("stderr").?.string.len);
}

test "the budgeted encoding is the rendered encoding" {
    // A channel whose only non-inline byte falls in the omitted middle: the
    // preview that survives is clean text. Budgeting it from the whole channel
    // (base64, 4:3) and then rendering the preview as JSON-escaped text (2:1)
    // put the envelope ~40% past the per-result budget - 35_087 bytes against
    // 25_000 - and the projection layer then spilled the whole structured
    // result, exit code and artifact ids included.
    const a = std.testing.allocator;
    const noisy = try a.alloc(u8, 64 * 1024);
    defer a.free(noisy);
    @memset(noisy, '"');
    noisy[noisy.len / 2] = 0x01;
    const budget = result_budget.Budget.fromModel(200_000);
    var envelope_attachments = tool_result.SealedHandles{};
    defer envelope_attachments.discard();
    const envelope = try formatCompletedOutput(a, noisy, "", 0, "", true, budget, null, &envelope_attachments);
    defer a.free(envelope);
    try std.testing.expect(envelope.len <= budget.per_result_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, envelope, .{});
    defer parsed.deinit();
    // The preview that survived is clean text, so it is rendered as text - the
    // budget and the rendering agree because only one decision was made.
    try std.testing.expectEqualStrings("utf-8", parsed.value.object.get("stdout_encoding").?.string);
    try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expect(parsed.value.object.get("stdout").?.string.len > 4096);

    // And a channel that is binary all the way through is still base64, still
    // inside the budget.
    const binary = try a.alloc(u8, 64 * 1024);
    defer a.free(binary);
    @memset(binary, 0x01);
    var binary_envelope_attachments = tool_result.SealedHandles{};
    defer binary_envelope_attachments.discard();
    const binary_envelope = try formatCompletedOutput(a, binary, "", 0, "", true, budget, null, &binary_envelope_attachments);
    defer a.free(binary_envelope);
    try std.testing.expect(binary_envelope.len <= budget.per_result_bytes);
    var binary_parsed = try std.json.parseFromSlice(std.json.Value, a, binary_envelope, .{});
    defer binary_parsed.deinit();
    try std.testing.expectEqualStrings("base64", binary_parsed.value.object.get("stdout_encoding").?.string);
}

test "an unpublishable Bash channel says why, not just that it failed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // No artifact root: the channel must spill and cannot. Reporting only
    // `recoverable:false` made a missing store, a full disk and an exhausted
    // session quota indistinguishable — the generic projection envelope has
    // always named the reason, and both families now use the same codes.
    const ctx = ToolContext{ .allocator = a };
    const result = try runSizedStdout(a, &ctx, 20_000);
    defer a.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    try std.testing.expect(!parsed.value.object.get("stdout_recoverable").?.bool);
    try std.testing.expectEqualStrings(
        "artifact_store_unavailable",
        parsed.value.object.get("stdout_storage_error").?.string,
    );
    // A channel that was never spilled makes no claim either way.
    try std.testing.expect(parsed.value.object.get("stderr_storage_error") == null);
}

test "显式 run_in_background 也不交出 staging 路径" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // auto-background 那条改掉之后,显式 run_in_background=true 这条还在返回
    // stdout_path/stderr_path —— 同一条契约,漏了一半。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const result = try execute(&ctx, "{\"command\":\"sleep 30\",\"run_in_background\":\"true\"}");
    defer a.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    const job_id = parsed.value.object.get("job_id").?.string;
    defer registry.kill(job_id) catch {};
    try std.testing.expectEqualStrings("started", parsed.value.object.get("status").?.string);
    // 句柄够用(BashOutput 按 job_id 读),但路径一个字节都不出现。
    try std.testing.expect(parsed.value.object.get("stdout_path") == null);
    try std.testing.expect(parsed.value.object.get("stderr_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/metacodes-jobs/") == null);
}

// ── #73: the channel spills are sealed attachments of the inline body ────────

/// What the batch commit boundary does for the loop; the tests that read a
/// blob back call it after rendering.
fn testPublishAttachments(attachments: *tool_result.SealedHandles) !void {
    for (attachments.slice()) |*maybe| {
        if (maybe.*) |*handle| _ = try handle.spool.publish();
    }
    attachments.deinit();
}

fn testCountDirectory(allocator: std.mem.Allocator, directory: []const u8) !usize {
    const pdir = @import("platform").dir;
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return 0;
    defer pdir.close(&iterator);
    var count: usize = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

test "executeBody seals a spilled channel as an attachment and publishes nothing until asked (#73)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const cas = try std.fmt.allocPrint(allocator, "{s}/tool-results/sha256", .{root});
    defer allocator.free(cas);
    var ctx = ToolContext.simple(allocator);
    ctx.artifact_root = root;
    ctx.result_budget = .floor;
    var body = try executeBody(&ctx, "{\"command\":\"awk 'BEGIN { for(i=0;i<40000;i++) printf \\\"x\\\"; printf \\\"BASH_TAIL\\\" }'\"}");
    defer body.deinit(allocator);
    try std.testing.expect(body == .@"inline");
    try std.testing.expectEqual(@as(u8, 1), body.@"inline".attachments.len);
    const handle = &body.@"inline".attachments.items[0].?;
    try std.testing.expectEqualStrings("stdout", handle.attachment_label.?);
    // The JSON already names the receipt; the CAS holds nothing.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.@"inline".bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(handle.spool.receipt().id(), parsed.value.object.get("stdout_artifact_id").?.string);
    try std.testing.expectEqual(@as(usize, 0), try testCountDirectory(allocator, cas));
    // The commit boundary publishes; the id in the JSON is the blob.
    var handles = body.takeSealedHandles();
    for (handles.slice()) |*maybe| {
        if (maybe.*) |*h| _ = try h.spool.publish();
    }
    const id = try allocator.dupe(u8, parsed.value.object.get("stdout_artifact_id").?.string);
    defer allocator.free(id);
    handles.deinit();
    try std.testing.expectEqual(@as(usize, 1), try testCountDirectory(allocator, cas));
    var tail = try artifact.readChunk(allocator, root, id, 40_000, 9);
    defer tail.deinit();
    try std.testing.expectEqualStrings("BASH_TAIL", tail.bytes);
    // The body's bytes were not touched by the take.
    try std.testing.expect(std.mem.indexOf(u8, body.@"inline".bytes, "metacodes.bash-result.v2") != null);
}

test "withdrawAttachmentFromJson and appendChannel agree on the two id sites (#73)" {
    // The withdrawal function rewrites two exact substrings; this renders a
    // real two-channel body and withdraws one channel, so the producer and
    // the withdrawal cannot drift apart unnoticed.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const big = try allocator.alloc(u8, 40_000);
    defer allocator.free(big);
    @memset(big, 'y');
    var attachments = tool_result.SealedHandles{};
    defer attachments.discard();
    const body = try formatCompletedOutput(allocator, big, big, 0, root, true, .floor, null, &attachments);
    defer allocator.free(body);
    try std.testing.expectEqual(@as(u8, 2), attachments.len);
    const stdout_id = try allocator.dupe(u8, attachments.items[0].?.spool.receipt().id());
    defer allocator.free(stdout_id);
    const stderr_id = try allocator.dupe(u8, attachments.items[1].?.spool.receipt().id());
    defer allocator.free(stderr_id);
    const withdrawn = try tool_result.withdrawAttachmentFromJson(allocator, body, "stderr", stderr_id, "session_quota_exceeded");
    defer allocator.free(withdrawn);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, withdrawn, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("stderr_artifact_id").? == .null);
    try std.testing.expectEqualStrings("session_quota_exceeded", object.get("stderr_storage_error").?.string);
    try std.testing.expect(object.get("stderr_recoverable").?.bool == false);
    try std.testing.expect(object.get("stderr_read") == null);
    try std.testing.expectEqualStrings(stdout_id, object.get("stdout_artifact_id").?.string);
    try std.testing.expect(object.get("stdout_recoverable").?.bool == true);
    try std.testing.expect(object.get("stdout_read") != null);
}
