//! WebFetch：拉取 URL 内容并返回纯文本摘要。
//!
//! 实现策略：
//! - 用系统 curl（已有 vendor/curl 或 /usr/bin/curl）抓 HTML
//! - 简单 HTML-to-text：strip <script>/<style>/标签 + HTML entity decode
//! - **返回全文**（受 16MB 捕获守卫上界）。**不再自截 8KB**——由 tool_exec 的通用 maybePersist
//!   (50KB 落盘)统一处理三件套:小页 inline 全文、大页缓存到 tool-results 返回 preview+path,
//!   模型用 Read(path,offset) 分页取剩余。WebFetch 遂从"特殊的 guard-and-drop"回归"普通工具走通用防线"。
//!
//! 不做：
//! - JS 渲染页面（需要无头浏览器）
//! - Markdown 格式保留（只做粗粒度文本提取）
//! - 预批准域名（P2）
//!
//! 返回 JSON: {"url":"...","bytes":N,"content":"<全文>"}(大页由 tool_exec 落盘换成 persisted 信封)

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

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

    // 用 curl 抓取
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    // curl -s -L --max-time 15 --user-agent "..." "<url>"
    const argv0: [*:0]const u8 = "/usr/bin/curl";
    var argv: [9]?[*:0]const u8 = .{
        argv0,
        "-s", // silent
        "-L", // follow redirects
        "--max-time",
        "15",
        "--user-agent",
        "metacodes/0.1 (+https://anthropic.com)",
        url_z.ptr,
        null,
    };
    const out = try common.spawnCaptureWithStderrTimed(argv[0..argv.len], allocator, ctx.abort, 20_000, ctx.spawn_tick_fn, common.MAX_SPAWN_CAPTURE_BYTES);
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);

    if (out.exit_code != 0) {
        return error.FetchFailed;
    }

    // HTML → text(全文,受 16MB 捕获守卫上界)。
    const text = try htmlToText(out.stdout, allocator);
    defer allocator.free(text);

    // 返回全文;大页由 tool_exec 的 maybePersist 统一落盘换成 preview+path(三件套),模型 Read(path) 取剩余。
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

test "WebFetch rejects non-http URLs" {
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    try std.testing.expectError(error.InvalidUrl, execute(&ctx, "{\"url\":\"file:///etc/passwd\"}"));
    try std.testing.expectError(error.InvalidUrl, execute(&ctx, "{\"url\":\"ftp://x\"}"));
}
