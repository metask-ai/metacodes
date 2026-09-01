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
pub const ENVELOPE_OVERHEAD_BYTES: usize = 2048;

/// Encoded preview bytes the two channels share, given the turn's budget.
///
/// This used to be a hard-coded 1536 per channel, back-computed from the 8KiB
/// budget *floor* and then applied unchanged on a 262K-window model whose real
/// allowance is 32KB. Because Bash spills before `result_projection` ever sees
/// the result, and because microcompact refuses to touch a recoverable
/// envelope, that constant was the only decision ever made about a Bash
/// result's size for its whole life in the Conversation.
fn channelAllowances(budget: result_budget.Budget, stdout_bytes: u64, stderr_bytes: u64) result_budget.Pair {
    return result_budget.splitPair(
        budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES),
        encodedDemand(stdout_bytes),
        encodedDemand(stderr_bytes),
    );
}

/// Upper bound on the encoded size of `raw` source bytes. JSON escaping at
/// most doubles a byte, and a channel that is not inline-safe is base64'd
/// instead, which expands only 4:3. Splitting on this bound rather than on the
/// raw size keeps a quote-dense channel from being cut against a ceiling its
/// own escaping would exceed; when the escaping does not materialise the only
/// cost is unused ceiling, which is free.
fn encodedDemand(raw: u64) u64 {
    return raw *| 2;
}
const PREVIEW_OMISSION_MARKER = "\n...[middle omitted]...\n";

const ChannelPreview = struct {
    content: []u8,
    shown_source_bytes: u64,
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
    if (s.len <= MAX_OUTPUT_BYTES) return try allocator.dupe(u8, s);

    // 1. 先定到 MAX_OUTPUT_BYTES,回退到 UTF-8 字符边界(continuation byte 0b10xxxxxx)。
    var cut = MAX_OUTPUT_BYTES;
    while (cut > 0 and (s[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
    // 2. 再回退到最近换行(让截断落在行边界,输出更整齐);若该行很长找不到则就用 cut。
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], '\n')) |nl| {
        if (nl + 1 >= MAX_OUTPUT_BYTES / 2) cut = nl + 1; // 仅当不会砍掉过多时才退到换行
    }
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
) ![]u8 {
    const allowance = channelAllowances(budget, stdout.len, stderr.len);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"schema_version\":\"metacodes.bash-result.v2\",");
    try appendMemoryChannel(&aw.writer, allocator, "stdout", stdout, artifact_root, capture_complete, allowance.first, metrics);
    try aw.writer.writeByte(',');
    try appendMemoryChannel(&aw.writer, allocator, "stderr", stderr, artifact_root, capture_complete, allowance.second, metrics);
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
    allowance: usize,
    metrics: ?*ResultMetrics,
) !void {
    const digest = sha256Hex(bytes);
    var preview = try headTailPreview(allocator, bytes, allowance);
    defer preview.deinit();
    // Publish only when the preview actually elides something. Deciding from
    // the preview instead of from a size threshold means a channel that fits
    // the allowance whole is never spilled, and a spill always corresponds to
    // bytes the model cannot otherwise see.
    const stored: ?artifact.Receipt = if (preview.shown_source_bytes < bytes.len)
        artifact.persist(allocator, artifact_root, bytes) catch null
    else
        null;
    try appendChannel(writer, allocator, label, preview.content, preview.shown_source_bytes, bytes.len, digest, stored, capture_complete, null, metrics);
}

fn appendFileChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    artifact_root: []const u8,
    allowance: usize,
    metrics: ?*ResultMetrics,
) !void {
    const inspected = artifact.inspectFile(allocator, path) catch {
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
        try appendChannel(writer, allocator, label, preview.content, preview.shown_source_bytes, observed_bytes, null, null, false, path, metrics);
        return;
    };
    var preview = try headTailFilePreview(allocator, path, inspected.bytes, allowance);
    defer preview.deinit();
    const stored: ?artifact.Receipt = if (preview.shown_source_bytes < inspected.bytes)
        artifact.persistInspectedFile(allocator, artifact_root, path, inspected) catch null
    else
        null;
    try appendChannel(writer, allocator, label, preview.content, preview.shown_source_bytes, inspected.bytes, inspected.sha256, stored, true, path, metrics);
}

fn appendChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    preview: []const u8,
    shown_source_bytes: u64,
    captured_bytes: u64,
    digest: ?[64]u8,
    stored: ?artifact.Receipt,
    capture_complete: bool,
    spool_path: ?[]const u8,
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
    if (isInlineUtf8(preview)) {
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
    // The process spool lives in the OS temp directory, never in the
    // kernel-private artifact CAS, and outlives the JobRegistry entry. It is
    // the only recovery capability left when the capture was too large to
    // publish, and it lets Grep/Read answer questions the 32KiB ReadArtifact
    // window cannot. The auto-backgrounded response already exposes it; the
    // completed response withholding it made the completed path strictly
    // weaker than the incomplete one.
    if (spool_path) |path| {
        try writer.print(",\"{s}_path\":", .{label});
        try std.json.Stringify.encodeJsonString(path, .{}, writer);
    }
}

fn encodedCost(source: []const u8, base64: bool) usize {
    if (base64) return std.base64.standard.Encoder.calcSize(source.len);
    return result_budget.encodedLen(source);
}

/// Longest prefix of `source` costing at most `max_encoded` once encoded.
fn cutHeadEncoded(source: []const u8, max_encoded: usize, base64: bool) usize {
    if (base64) return @min(source.len, max_encoded / 4 * 3);
    return result_budget.encodedPrefixLen(source, max_encoded);
}

/// Longest suffix of `source` costing at most `max_encoded` once encoded.
fn cutTailEncoded(source: []const u8, max_encoded: usize, base64: bool) usize {
    if (base64) return @min(source.len, max_encoded / 4 * 3);
    return result_budget.encodedSuffixLen(source, max_encoded);
}

/// Head/tail split of one encoded allowance, three quarters to the head.
/// The budget is spent in **encoded** bytes: cutting on source length instead
/// would let a quote- or newline-dense channel render at up to twice the
/// allowance it was sized against, which on a wide window is the difference
/// between fitting the per-result budget and having the whole envelope spilled
/// again by the projection layer.
fn splitPreviewBudget(
    head_source: []const u8,
    tail_source: []const u8,
    max_encoded: usize,
    base64: bool,
) struct { head_len: usize, tail_len: usize } {
    const head_len = cutHeadEncoded(head_source, max_encoded * 3 / 4, base64);
    const spent = encodedCost(head_source[0..head_len], base64);
    const tail_len = cutTailEncoded(tail_source, max_encoded -| spent, base64);
    return .{ .head_len = head_len, .tail_len = tail_len };
}

fn headTailPreview(allocator: std.mem.Allocator, bytes: []const u8, max_encoded: usize) !ChannelPreview {
    // A channel that is inline-safe stays inline-safe under any UTF-8 aligned
    // cut, so deciding the encoding from the whole channel can only ever
    // over-budget a preview that turns out to be clean - never under-budget a
    // preview that turns out not to be.
    const base64 = !isInlineUtf8(bytes);
    if (encodedCost(bytes, base64) <= max_encoded) {
        return .{
            .content = try allocator.dupe(u8, bytes),
            .shown_source_bytes = bytes.len,
            .allocator = allocator,
        };
    }
    const marker_cost = encodedCost(PREVIEW_OMISSION_MARKER, base64);
    if (max_encoded <= marker_cost) {
        const head_len = cutHeadEncoded(bytes, max_encoded, base64);
        return .{
            .content = try allocator.dupe(u8, bytes[0..head_len]),
            .shown_source_bytes = head_len,
            .allocator = allocator,
        };
    }
    const budget = max_encoded - marker_cost;
    const head_len = cutHeadEncoded(bytes, budget * 3 / 4, base64);
    const rest = bytes[head_len..];
    const tail_len = cutTailEncoded(rest, budget -| encodedCost(bytes[0..head_len], base64), base64);
    const result = try std.mem.concat(allocator, u8, &.{
        bytes[0..head_len],
        PREVIEW_OMISSION_MARKER,
        bytes[bytes.len - tail_len ..],
    });
    return .{
        .content = result,
        .shown_source_bytes = head_len + tail_len,
        .allocator = allocator,
    };
}

fn headTailFilePreview(allocator: std.mem.Allocator, path: []const u8, total_bytes: u64, max_encoded: usize) !ChannelPreview {
    if (max_encoded == 0) {
        return .{ .content = try allocator.dupe(u8, ""), .shown_source_bytes = 0, .allocator = allocator };
    }
    // Encoded size is never below source size, so `max_encoded` source bytes
    // bounds what could possibly fit - and bounds the read for a spool that
    // may be gigabytes.
    if (total_bytes <= max_encoded) {
        const whole = try readWholeFile(path, allocator, max_encoded);
        defer allocator.free(whole);
        return try headTailPreview(allocator, whole, max_encoded);
    }
    const head_read: usize = max_encoded * 3 / 4;
    const tail_read: usize = max_encoded - head_read;
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
    // ordinary text file.
    const provisional = splitPreviewBudget(head_raw, tail_raw, max_encoded, false);
    const base64 = !isInlineUtf8(head_raw[0..provisional.head_len]) or
        !isInlineUtf8(tail_raw[tail_raw.len - provisional.tail_len ..]);
    const marker_cost = encodedCost(PREVIEW_OMISSION_MARKER, base64);
    const cut = if (base64)
        splitPreviewBudget(head_raw, tail_raw, max_encoded -| marker_cost, true)
    else
        splitPreviewBudget(head_raw, tail_raw, max_encoded -| marker_cost, false);
    const content = try std.mem.concat(allocator, u8, &.{
        head_raw[0..cut.head_len],
        PREVIEW_OMISSION_MARKER,
        tail_raw[tail_raw.len - cut.tail_len ..],
    });
    return .{ .content = content, .shown_source_bytes = cut.head_len + cut.tail_len, .allocator = allocator };
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
) ![]u8 {
    // Two extra stats so the split sees real demand: giving each channel a
    // fixed half would forfeit half the allowance to the empty stderr that
    // most commands produce.
    const allowance = channelAllowances(
        budget,
        artifact.observeFileBytes(allocator, stdout_path) catch 0,
        artifact.observeFileBytes(allocator, stderr_path) catch 0,
    );
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"schema_version\":\"metacodes.bash-result.v2\",");
    try appendFileChannel(&aw.writer, allocator, "stdout", stdout_path, artifact_root, allowance.first, metrics);
    try aw.writer.writeByte(',');
    try appendFileChannel(&aw.writer, allocator, "stderr", stderr_path, artifact_root, allowance.second, metrics);
    try aw.writer.print(",\"exit_code\":{d}}}", .{exit_code});
    return aw.toOwnedSlice();
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
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
                return try std.fmt.allocPrint(allocator, "{{\"job_id\":\"{s}\",\"status\":\"started\",\"stdout_path\":\"{s}\",\"stderr_path\":\"{s}\"}}", .{ j.id[0..], j.stdout_path, j.stderr_path });
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
    return try formatCompletedOutput(allocator, out.stdout, out.stderr, out.exit_code, ctx.artifact_root, out.capture_complete, ctx.result_budget, ctx.tool_result_metrics);
}

/// Bash already redirects stdout/stderr to JobRegistry files before the child
/// emits byte zero. Its model-visible completion is bounded JSON containing
/// per-channel CAS receipts/previews, so the typed boundary remains inline.
pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    return ToolResultBody.initInline(try execute(ctx, args));
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
) ![]u8 {
    const j_entry = try registry.spawnBackground(command, cwd);
    const job_id = j_entry.id; // 值拷贝，不持指针（registry 可能扩容移动）

    const effective_budget = if (allow_auto_background) @min(timeout_ms, AUTO_BACKGROUND_MS) else timeout_ms;
    const start = nowMs();
    // 轮询循环
    while (true) {
        if (abort) |a| if (a.isAborted()) {
            registry.kill(job_id[0..]) catch {};
            return error.Aborted;
        };
        util_time.sleepMs(100);

        registry.reapExited();
        const j = registry.get(job_id[0..]) orelse return error.JobNotFound; // 值快照
        if (j.status != .running) {
            // 正常退出：读文件构造完整输出
            return try readJobAsSync(allocator, &j, artifact_root, budget, metrics);
        }

        const elapsed: u64 = @intCast(nowMs() - start);
        if (elapsed >= timeout_ms) {
            // 真 timeout：kill + 错误
            registry.kill(job_id[0..]) catch {};
            return error.Timeout;
        }
        if (allow_auto_background and elapsed >= effective_budget) {
            // 达到 auto-background 阈值但未到 timeout：返回 auto_backgrounded
            return try formatAutoBackgrounded(allocator, &j);
        }
    }
}

fn readJobAsSync(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry, artifact_root: []const u8, budget: result_budget.Budget, metrics: ?*ResultMetrics) ![]u8 {
    return try formatCompletedFiles(allocator, j.stdout_path, j.stderr_path, j.exit_code orelse 0, artifact_root, budget, metrics);
}

fn formatAutoBackgrounded(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry) ![]u8 {
    const out_bytes = readWholeFile(j.stdout_path, allocator, common.MAX_SPAWN_CAPTURE_BYTES) catch try allocator.dupe(u8, "");
    defer allocator.free(out_bytes);
    const err_bytes = readWholeFile(j.stderr_path, allocator, common.MAX_SPAWN_CAPTURE_BYTES) catch try allocator.dupe(u8, "");
    defer allocator.free(err_bytes);

    const out_trunc = try truncateHead(allocator, out_bytes);
    defer allocator.free(out_trunc);
    const err_trunc = try truncateHead(allocator, err_bytes);
    defer allocator.free(err_trunc);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"auto_backgrounded\":true,\"job_id\":");
    try std.json.Stringify.encodeJsonString(j.id[0..], .{}, &aw.writer);
    try aw.writer.writeAll(",\"stdout_path\":");
    try std.json.Stringify.encodeJsonString(j.stdout_path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"stderr_path\":");
    try std.json.Stringify.encodeJsonString(j.stderr_path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stdout\":");
    try std.json.Stringify.encodeJsonString(out_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stderr\":");
    try std.json.Stringify.encodeJsonString(err_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"note\":\"Command exceeded 15s; moved to background. Use BashOutput to poll, or Read on stdout_path/stderr_path to read captured output directly.\"}");
    return try aw.toOwnedSlice();
}

/// 读文件到内存,**上限 max_bytes**(轴A OOM 防线):job 输出文件可能很大(命令疯产 GB 落盘),
/// 但同步返回只需前 MAX_OUTPUT_BYTES(30KB)展示 → 读够 cap 就停,防整读 OOM。max_bytes=0 不限。
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

test "formatAutoBackgrounded 返回 stdout_path/stderr_path 供 Read 直接读" {
    // 对齐 cc: auto-backgrounded 响应必须含 stdout_path/stderr_path,
    // 否则模型被迫 BashOutput 轮询,长任务时陷入"轮询无果"死循环。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const j = try registry.spawnBackground("echo hi; sleep 30", null);
    defer registry.kill(j.idSlice()) catch {};
    const result = try formatAutoBackgrounded(a, &j);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"auto_backgrounded\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"job_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_path\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stderr_path\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "partial_stdout") != null);
    // note 应引导模型用 Read 读 path
    try std.testing.expect(std.mem.indexOf(u8, result, "Read on stdout_path") != null);
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
    const result = try readJobAsSync(allocator, &job, root, .floor, &metrics);
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
    // The process spool path is handed back alongside the artifact id. The
    // `indexOf(result, root) == null` assertion above still holds because the
    // JobRegistry spool lives in the OS temp directory, not in the
    // kernel-private artifact CAS.
    try std.testing.expectEqualStrings(job.stdout_path, parsed.value.object.get("stdout_path").?.string);
    try std.testing.expectEqualStrings(job.stderr_path, parsed.value.object.get("stderr_path").?.string);
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
    var tail = try artifact.readChunk(allocator, root, artifact_id, 39_990, 32);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "EMBED_TAIL") != null);

    // The spool path must be a handle the model can actually act on: Read and
    // Grep answer questions the 32KiB ReadArtifact window cannot. Prove it
    // resolves to the complete bytes even though the transient JobRegistry
    // that produced it has already been torn down.
    const spool_path = parsed.value.object.get("stdout_path").?.string;
    try std.testing.expect(std.mem.indexOf(u8, spool_path, root) == null);
    const spooled = try readWholeFile(spool_path, allocator, 0);
    defer allocator.free(spooled);
    try std.testing.expectEqual(@as(usize, 40_010), spooled.len);
    try std.testing.expect(std.mem.endsWith(u8, spooled, "EMBED_TAIL"));
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

    const result = try formatCompletedFiles(allocator, stdout_path, stderr_path, 0, root, .floor, null);
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
    // content-addressed promise about. The spool path is the weaker but real
    // capability that used to be withheld here, turning an intact on-disk
    // file into a total loss for the model.
    try std.testing.expectEqualStrings(stdout_path, parsed.value.object.get("stdout_path").?.string);
    try std.testing.expectEqualStrings(stderr_path, parsed.value.object.get("stderr_path").?.string);
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
    // No JobRegistry and no artifact root means no on-disk spool exists, so the
    // path field is absent rather than pointing at nothing.
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
    const envelope = try formatCompletedOutput(a, noisy, "", 0, "", true, budget, null);
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
    const even = channelAllowances(budget, 1 << 20, 1 << 20);
    try std.testing.expectEqual(payload, even.first + even.second);
    // Empty stderr: stdout gets everything.
    const lopsided = channelAllowances(budget, 1 << 20, 0);
    try std.testing.expectEqual(payload, lopsided.first);
    try std.testing.expectEqual(@as(usize, 0), lopsided.second);
    // Small channels keep headroom for their own escaping rather than being
    // capped at their raw size.
    const small = channelAllowances(budget, 1000, 20);
    try std.testing.expectEqual(@as(usize, 2000), small.first);
    try std.testing.expectEqual(@as(usize, 40), small.second);
}
