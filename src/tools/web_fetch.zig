//! WebFetch：拉取 URL 内容并返回纯文本摘要。
//!
//! 实现策略：
//! - 用系统 curl（已有 vendor/curl 或 /usr/bin/curl）抓 HTML
//! - 简单 HTML-to-text：strip <script>/<style>/标签 + HTML entity decode
//! - **返回全文**（受 128MiB artifact 上界）。**不再自截 8KB**——由 Tool Result 内核的 Session CAS
//!   统一处理三件套：小页 inline 全文，大页进入 Session CAS 并返回无路径 artifact receipt，
//!   模型用 ReadArtifact(offset,limit) 分页取剩余。curl、HTML 清洗和 JSON 编码均为固定块流式路径。
//!
//! 不做：
//! - JS 渲染页面（需要无头浏览器）
//! - Markdown 格式保留（只做粗粒度文本提取）
//! - 预批准域名（P2）
//!
//! 返回 JSON: {"url":"...","bytes":N,"content":"<全文>"}(大页直接返回 typed artifact receipt)

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

// 出站 User-Agent 与产品版本同源;不再附带早期误标的第三方主页。
const user_agent = "metacodes/" ++ @import("../version.zig").semver;
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_spool = @import("result_spool.zig");

const STDERR_CAPTURE_BYTES: usize = 64 * 1024;
const MAX_TEXT_CAPTURE_BYTES: usize = 60 * 1024 * 1024;

/// v39 G4 离线熔断(终局取证:离线容器里 agent 陷 WebFetch 并行重试风暴后
/// 进程死亡、零结果事件,整个 harbor run 中止)。进程级连续失败计数:达阈值
/// 后本 run 拒绝继续外呼,给模型"环境离线,改用本地手段"的明确信号;任一次
/// 成功即复位——长交互会话不会被一段网络抖动永久禁用。进程级=eval 每
/// trial 独立进程,作用域天然正确。
pub const OFFLINE_BREAKER_THRESHOLD: u32 = 5;
var consecutive_failures = std.atomic.Value(u32).init(0);

/// 测试钩子:复位熔断计数。
pub fn resetOfflineBreakerForTest() void {
    consecutive_failures.store(0, .release);
}

/// 测试钩子:模拟一次网络失败(与 execute 失败路径同一计数器)。
pub fn noteFetchFailureForTest() u32 {
    return consecutive_failures.fetchAdd(1, .acq_rel) + 1;
}

pub fn offlineBreakerTripped() bool {
    return consecutive_failures.load(.acquire) >= OFFLINE_BREAKER_THRESHOLD;
}

/// Production byte-zero path. curl stdout first lands in a private Capture;
/// HTML stripping and JSON encoding each stream through bounded captures, so
/// no stage owns the full downloaded page or the full encoded tool result.
pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    if (ctx.artifact_root.len == 0)
        return ToolResultBody.initInline(try execute(ctx, args));

    const allocator = ctx.allocator;
    const url = common.extractJsonArg(args, "url") orelse return error.MissingUrl;
    if (url.len == 0) return error.EmptyUrl;
    _ = common.extractJsonArg(args, "prompt");
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://"))
        return error.InvalidUrl;
    if (offlineBreakerTripped()) {
        common.setErrorDetail(ctx.error_detail, allocator, "WebFetch disabled for this run after {d} consecutive network failures — the environment appears to be OFFLINE. Do not retry any network tool; solve the task with local files and commands only.", .{consecutive_failures.load(.acquire)});
        return error.FetchFailed;
    }

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const argv0: [*:0]const u8 = if (builtin.os.tag == .windows) "curl" else "/usr/bin/curl";
    var argv: [9]?[*:0]const u8 = .{
        argv0,
        "-s",
        "-L",
        "--max-time",
        "15",
        "--user-agent",
        user_agent,
        url_z.ptr,
        null,
    };
    var spawned = try common.spawnCaptureToSpoolTimed(
        argv[0..],
        allocator,
        ctx.artifact_root,
        ctx.abort,
        20_000,
        ctx.spawn_tick_fn,
        artifact_store.MAX_ARTIFACT_BYTES,
        STDERR_CAPTURE_BYTES,
        null,
    );
    defer spawned.deinit();
    if (spawned.exit_code != 0 and (spawned.capture_complete or spawned.stdout.bytes == 0)) {
        const failures = consecutive_failures.fetchAdd(1, .acq_rel) + 1;
        if (failures >= OFFLINE_BREAKER_THRESHOLD) {
            common.setErrorDetail(ctx.error_detail, allocator, "WebFetch failed ({d} consecutive network failures) — the environment appears to be OFFLINE. Further WebFetch calls this run will be rejected; solve the task with local files and commands only.", .{failures});
        }
        return error.FetchFailed;
    }
    consecutive_failures.store(0, .release);

    var text_capture = try artifact_store.Capture.begin(
        allocator,
        ctx.artifact_root,
        MAX_TEXT_CAPTURE_BYTES,
    );
    defer text_capture.deinit();
    try streamHtmlToText(&spawned.stdout, &text_capture);
    _ = try text_capture.sealExternal(); // local writer; permits an empty page

    var result_capture = try artifact_store.Capture.begin(
        allocator,
        ctx.artifact_root,
        artifact_store.MAX_ARTIFACT_BYTES,
    );
    defer result_capture.deinit();
    var result_writer = result_spool.CaptureWriter.init(&result_capture);
    try result_writer.writer.writeAll("{\"url\":");
    try std.json.Stringify.encodeJsonString(url, .{}, &result_writer.writer);
    try result_writer.writer.print(",\"bytes\":{d},\"content\":\"", .{text_capture.bytes});
    try text_capture.rewind();
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try text_capture.read(&buffer);
        if (count == 0) break;
        try std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &result_writer.writer);
    }
    try result_writer.writer.writeAll("\"}");
    try result_writer.check();
    try result_capture.seal();
    return result_spool.finishCaptureAsBody(
        allocator,
        ctx.artifact_root,
        &result_capture,
        .json,
        spawned.capture_complete,
        ctx.result_budget,
    );
}

const HtmlStream = struct {
    destination: *artifact_store.Capture,
    tag: [1024]u8 = undefined,
    tag_len: usize = 0,
    in_tag: bool = false,
    skip: enum { none, script, style } = .none,
    entity: [16]u8 = undefined,
    entity_len: usize = 0,
    last_was_space: bool = true,

    fn feed(self: *HtmlStream, bytes: []const u8) !void {
        for (bytes) |byte| try self.feedByte(byte);
    }

    fn finish(self: *HtmlStream) !void {
        if (self.entity_len != 0) try self.writeLiteral(self.entity[0..self.entity_len]);
    }

    fn feedByte(self: *HtmlStream, byte: u8) !void {
        if (self.in_tag) {
            if (byte == '>') {
                self.in_tag = false;
                try self.finishTag();
            } else if (self.tag_len < self.tag.len) {
                self.tag[self.tag_len] = byte;
                self.tag_len += 1;
            }
            return;
        }
        if (byte == '<') {
            if (self.entity_len != 0) {
                try self.writeLiteral(self.entity[0..self.entity_len]);
                self.entity_len = 0;
            }
            self.in_tag = true;
            self.tag_len = 0;
            return;
        }
        if (self.skip != .none) return;

        if (self.entity_len != 0) {
            if (self.entity_len < self.entity.len) {
                self.entity[self.entity_len] = byte;
                self.entity_len += 1;
                if (byte == ';') {
                    const encoded = self.entity[0..self.entity_len];
                    if (parseEntity(encoded)) |decoded|
                        try self.writeLiteral(decoded.text)
                    else
                        try self.writeLiteral(encoded);
                    self.entity_len = 0;
                }
                return;
            }
            try self.writeLiteral(self.entity[0..self.entity_len]);
            self.entity_len = 0;
        }
        if (byte == '&') {
            self.entity[0] = '&';
            self.entity_len = 1;
            return;
        }
        try self.writeTextByte(byte);
    }

    fn finishTag(self: *HtmlStream) !void {
        const raw = std.mem.trim(u8, self.tag[0..self.tag_len], " \t\r\n");
        const closing = raw.len > 0 and raw[0] == '/';
        const start: usize = if (closing) 1 else 0;
        var end = start;
        while (end < raw.len and (std.ascii.isAlphanumeric(raw[end]) or raw[end] == '-')) : (end += 1) {}
        const name = raw[start..end];
        if (self.skip != .none) {
            if (closing and ((self.skip == .script and std.ascii.eqlIgnoreCase(name, "script")) or
                (self.skip == .style and std.ascii.eqlIgnoreCase(name, "style")))) self.skip = .none;
            return;
        }
        if (!closing and std.ascii.eqlIgnoreCase(name, "script")) {
            self.skip = .script;
            return;
        }
        if (!closing and std.ascii.eqlIgnoreCase(name, "style")) {
            self.skip = .style;
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style")) return;
        try self.writeSpace();
    }

    fn writeTextByte(self: *HtmlStream, byte: u8) !void {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return self.writeSpace();
        if (byte < 0x20) return;
        if (self.last_was_space and self.destination.bytes != 0)
            try self.destination.write(" ");
        try self.destination.write(&.{byte});
        self.last_was_space = false;
    }

    fn writeLiteral(self: *HtmlStream, bytes: []const u8) !void {
        for (bytes) |byte| try self.writeTextByte(byte);
    }

    fn writeSpace(self: *HtmlStream) !void {
        self.last_was_space = true;
    }
};

fn streamHtmlToText(source: *artifact_store.Capture, destination: *artifact_store.Capture) !void {
    try source.rewind();
    var stream = HtmlStream{ .destination = destination };
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try source.read(&buffer);
        if (count == 0) break;
        try stream.feed(buffer[0..count]);
    }
    try stream.finish();
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const url = common.extractJsonArg(args, "url") orelse return error.MissingUrl;
    if (url.len == 0) return error.EmptyUrl;
    // prompt 字段目前不使用（让模型自己在收到 content 后做分析），但保留接口
    _ = common.extractJsonArg(args, "prompt");

    // 基本 URL 合法性：必须以 http:// 或 https:// 开头
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidUrl;
    }

    if (offlineBreakerTripped()) {
        common.setErrorDetail(ctx.error_detail, allocator, "WebFetch disabled for this run after {d} consecutive network failures — the environment appears to be OFFLINE. Do not retry any network tool; solve the task with local files and commands only.", .{consecutive_failures.load(.acquire)});
        return error.FetchFailed;
    }

    // 用 curl 抓取
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    // curl -s -L --max-time 15 --user-agent "..." "<url>"
    const argv0: [*:0]const u8 = if (builtin.os.tag == .windows) "curl" else "/usr/bin/curl";
    var argv: [9]?[*:0]const u8 = .{
        argv0,
        "-s", // silent
        "-L", // follow redirects
        "--max-time",
        "15",
        "--user-agent",
        user_agent,
        url_z.ptr,
        null,
    };
    const out = try common.spawnCaptureWithStderrTimed(argv[0..argv.len], allocator, ctx.abort, 20_000, ctx.spawn_tick_fn, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);

    if (out.exit_code != 0) {
        const n = consecutive_failures.fetchAdd(1, .acq_rel) + 1;
        if (n >= OFFLINE_BREAKER_THRESHOLD) {
            common.setErrorDetail(ctx.error_detail, allocator, "WebFetch failed ({d} consecutive network failures) — the environment appears to be OFFLINE. Further WebFetch calls this run will be rejected; solve the task with local files and commands only.", .{n});
        }
        return error.FetchFailed;
    }
    consecutive_failures.store(0, .release);

    // Legacy no-artifact-root compatibility path: HTML → text(受 16MiB 捕获上界)。
    const text = try htmlToText(out.stdout, allocator);
    defer allocator.free(text);

    // 返回全文；大页在 AgentLoop 投影为 content-addressed receipt，模型用 ReadArtifact 分片恢复。
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"url\":");
    try std.json.Stringify.encodeJsonString(url, .{}, &aw.writer);
    try aw.writer.print(",\"bytes\":{d},\"content\":", .{text.len});
    try std.json.Stringify.encodeJsonString(text, .{}, &aw.writer);
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

/// 极简 HTML 到文本：strip <script>/<style> 块 + strip 所有 tags + 折叠空白 + 基本 entity decode。
/// 不做：表格渲染、li 项目符号、heading 层级。适合"把网页内容塞进 prompt 让模型理解"场景。
fn htmlToText(html: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var last_was_space = true; // 首字符不输出 leading whitespace
    while (i < html.len) {
        // 跳过 <script>...</script> 和 <style>...</style>
        if (html[i] == '<' and i + 1 < html.len) {
            if (skipBlock(html, i, "<script", "</script>")) |end| {
                i = end;
                continue;
            }
            if (skipBlock(html, i, "<style", "</style>")) |end| {
                i = end;
                continue;
            }
            // 普通 tag：跳到 '>'
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            // 一些 block-level tag 之后插一个空格，避免 "foo</p><p>bar" → "foobar"
            if (!last_was_space) {
                try out.append(allocator, ' ');
                last_was_space = true;
            }
            i = gt + 1;
            continue;
        }

        const c = html[i];
        if (c == '&') {
            // entity decode：只处理常见的
            if (parseEntity(html[i..])) |pair| {
                try out.appendSlice(allocator, pair.text);
                i += pair.consumed;
                last_was_space = false;
                continue;
            }
        }
        // 空白折叠
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_was_space) {
                try out.append(allocator, ' ');
                last_was_space = true;
            }
            i += 1;
            continue;
        }
        // 控制字节(NUL 等 <0x20,\t\n\r 上面已处理)是提取文本里的垃圾,丢弃——顺带防
        // 二进制 URL 的控制字节经 encodeJsonString 转 \u00XX 6x 膨胀(Linus 登记的内存尖峰)。
        if (c < 0x20) {
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        last_was_space = false;
        i += 1;
    }

    // trim trailing space
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return try out.toOwnedSlice(allocator);
}

/// 若从 start 开始匹配 open_prefix（大小写不敏感），跳到 close 之后，返新 index。
fn skipBlock(html: []const u8, start: usize, open_prefix: []const u8, close: []const u8) ?usize {
    if (start + open_prefix.len > html.len) return null;
    if (!std.ascii.eqlIgnoreCase(html[start..][0..open_prefix.len], open_prefix)) return null;
    const end = std.mem.indexOfPos(u8, html, start, close) orelse return null;
    return end + close.len;
}

const EntityPair = struct { text: []const u8, consumed: usize };

fn parseEntity(s: []const u8) ?EntityPair {
    // 命名实体（最常见几个）
    const named = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "&amp;", .text = "&" },
        .{ .name = "&lt;", .text = "<" },
        .{ .name = "&gt;", .text = ">" },
        .{ .name = "&quot;", .text = "\"" },
        .{ .name = "&apos;", .text = "'" },
        .{ .name = "&nbsp;", .text = " " },
        .{ .name = "&copy;", .text = "©" },
        .{ .name = "&reg;", .text = "®" },
        .{ .name = "&hellip;", .text = "…" },
        .{ .name = "&mdash;", .text = "—" },
        .{ .name = "&ndash;", .text = "–" },
    };
    for (named) |e| {
        if (std.mem.startsWith(u8, s, e.name)) return .{ .text = e.text, .consumed = e.name.len };
    }
    // 数字实体 &#NNN; — 略过不处理，原样输出 '&'
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "htmlToText strips tags" {
    const a = std.testing.allocator;
    const html = "<html><body><h1>Hi</h1><p>World</p></body></html>";
    const t = try htmlToText(html, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("Hi World", t);
}

test "htmlToText strips script and style" {
    const a = std.testing.allocator;
    const html = "<style>body{}</style>Hello<script>alert(1)</script>World";
    const t = try htmlToText(html, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("HelloWorld", t);
}

test "htmlToText decodes basic entities" {
    const a = std.testing.allocator;
    const html = "A &amp; B &lt;C&gt; &quot;D&quot;";
    const t = try htmlToText(html, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("A & B <C> \"D\"", t);
}

test "htmlToText collapses whitespace" {
    const a = std.testing.allocator;
    const html = "  a  \n\n  b  \t c  ";
    const t = try htmlToText(html, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("a b c", t);
}

test "streamHtmlToText preserves legacy semantics across tag and entity chunk boundaries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const html = "<html><body>Hello <scr" ++
        "ipt>ignored &amp;</scr" ++
        "ipt><p>A &am" ++
        "p; B</p><style>x{}</style> Tail</body></html>";
    const expected = try htmlToText(html, allocator);
    defer allocator.free(expected);

    var source = try artifact_store.Capture.begin(allocator, root, 4096);
    defer source.deinit();
    try source.write(html[0..21]);
    try source.write(html[21..47]);
    try source.write(html[47..63]);
    try source.write(html[63..]);
    try source.seal();
    var destination = try artifact_store.Capture.begin(allocator, root, 4096);
    defer destination.deinit();
    try streamHtmlToText(&source, &destination);
    _ = try destination.sealExternal();
    const actual = try destination.readRangeAlloc(allocator, 0, @intCast(destination.bytes));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "WebFetch rejects non-http URLs" {
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    try std.testing.expectError(error.InvalidUrl, execute(&ctx, "{\"url\":\"file:///etc/passwd\"}"));
    try std.testing.expectError(error.InvalidUrl, execute(&ctx, "{\"url\":\"ftp://x\"}"));
}

test "v39 offline breaker trips after threshold and rejects before spawn" {
    resetOfflineBreakerForTest();
    defer resetOfflineBreakerForTest();
    var i: u32 = 0;
    while (i < OFFLINE_BREAKER_THRESHOLD - 1) : (i += 1) {
        _ = noteFetchFailureForTest();
    }
    try std.testing.expect(!offlineBreakerTripped());
    _ = noteFetchFailureForTest();
    try std.testing.expect(offlineBreakerTripped());
    // tripped 后 execute 必须在 spawn 前拒绝,并携带 OFFLINE 提示。
    var detail: ?[]const u8 = null;
    var ctx = ToolContext{ .allocator = std.testing.allocator, .error_detail = &detail };
    defer if (detail) |d| std.testing.allocator.free(d);
    const r = execute(&ctx, "{\"url\":\"https://example.com/x\"}");
    try std.testing.expectError(error.FetchFailed, r);
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "OFFLINE") != null);
}
