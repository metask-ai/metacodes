const std = @import("std");
const pprocess = @import("platform").process;
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const read_state = @import("../core/read_state.zig");
const code_map = @import("code_map.zig");
const symbol_provider = @import("symbol_provider.zig");
const ToolContext = @import("context.zig").ToolContext;
const tt = @import("test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)

/// 默认读取行数上限（对齐 TS：限制 200KB/2000 行用户无感截断）。
pub const DEFAULT_LIMIT_LINES: usize = 2000;

/// 整读(不带 offset/limit)的文件字节上限(对齐 Claude Code 256KB)。超出 → 拒读 + 提示用
/// offset/limit 或 Grep,防一次性把大文件灌进上下文。显式传 offset/limit 时不受此限(用户要精确范围)。
pub const MAX_FILE_BYTES: usize = 256 * 1024;

/// 单行字节上限:超长行(如压缩成一行的 minified 文件)截断到此 + 标记,防"1 行几 MB"撑爆。
pub const MAX_LINE_BYTES: usize = 2000;

/// 流式区间读门槛(对齐 cc readFileInRange FAST_PATH_MAX_SIZE=10MB):< 此值整读+内存切片(快);
/// ≥ 此值走流式 chunk 读——只累积区间内的行,区间外计数丢弃,**O(区间) 内存**,防巨型文件整读 OOM。
/// 只有显式 offset/limit 能到这(默认无参路径已被 MAX_FILE_BYTES=256KB 守卫拦)。
pub const STREAM_PATH_MIN_SIZE: u64 = 10 * 1024 * 1024;

/// 单次 Read 返回内容的字节上限(≈ cc 25K-token 后置封顶的字节代理:~4 字节/token × 25K ≈ 100KB)。
/// **为什么不是 256KB**:Read 豁免 50K 落盘兜底,返回内容直接进上下文;256KB≈64K token 对小窗口
/// 模型(glm-5.2 262K)一次吃 ~24% 窗口。100KB≈25K token 对齐 cc,占 glm ~10%,对主流窗口都安全。
/// 超出:截到最后完整行 + 带**精确续读行号**的提示(模型 Read(offset=续读行) 分页取剩余=三件套第③件)。
pub const MAX_READ_OUTPUT_BYTES: usize = 100 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // 兼容：优先 file_path（TS 原版），回退 path（历史）
    const path_raw = common.extractJsonArg(args, "file_path") orelse
        common.extractJsonArg(args, "path") orelse
        return error.MissingPath;
    if (path_raw.len == 0) return error.EmptyPath;
    // 归一化(展开 ~、折叠、查 traversal)。execve 不经 shell,~ 必须自己展开;openat 同样不认 ~。
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);
    try rejectDevicePath(path);

    // 图像文件：单独路径——不当文本读（会乱码 + 撑爆 token）。
    if (imageMediaType(path)) |media_type| {
        return try readImage(allocator, ctx, path, media_type);
    }

    // outline 模式(opt-in):返回符号大纲(函数/类型/类 + 行号 + 签名)而非文件内容。
    // 三态处理(issue #17):有大纲 → 返大纲;能力在位但文件没符号 → 安静回退正常读;
    // **能力缺失 → 也回退,但把原因记下来,读完在结果末尾交代**——静默回退等于让模型
    // 以为"这文件没结构",和裸 `[]` 是同一类谎报。
    const want_outline = isTrue(common.extractJsonArg(args, "outline"));
    var outline_gap: ?symbol_provider.Unavailable = null;
    if (want_outline) {
        switch (symbol_provider.capabilityFor(ctx, path)) {
            .unavailable => |u| outline_gap = u,
            .available => switch (try readOutline(allocator, ctx, path)) {
                .text => |outline| return outline,
                .no_symbols => {},
                .unavailable => |u| outline_gap = u,
            },
        }
    }

    const has_offset = common.extractJsonArg(args, "offset") != null;
    const has_limit = common.extractJsonArg(args, "limit") != null;
    const offset_1based: usize = if (common.extractJsonArg(args, "offset")) |s|
        std.fmt.parseInt(usize, s, 10) catch 1
    else
        1;
    const limit: usize = if (common.extractJsonArg(args, "limit")) |s|
        std.fmt.parseInt(usize, s, 10) catch DEFAULT_LIMIT_LINES
    else
        DEFAULT_LIMIT_LINES;
    if (offset_1based == 0) return error.InvalidOffset;

    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch {
        // 缓存失效优雅提示:tool-results 落盘缓存被 TTL/LRU 清理后,transcript 里的旧 path → 打不开。
        // 返回可操作提示(而非裸 FileNotFound),消除"文件被清了 vs 路径错了"的神秘失败。
        if (std.mem.indexOf(u8, path, "/.metacodes/tool-results/") != null) {
            return try allocator.dupe(u8, "{\"error\":\"This cached tool-result file no longer exists (expired by cache TTL or evicted by size limit). Re-run the original tool to regenerate its output.\"}");
        }
        return error.FileNotFound;
    };
    defer _ = pfs.close(fd);

    // 在读之前 fstat 一次拿 mtime/size，供 ReadState 记录用（must-read-first/staleness 校验）
    const st = read_state.statFd(fd) catch null;

    // 大文件守卫:整读(未显式传 offset/limit)且 > MAX_FILE_BYTES → 不再死胡同报错;
    // 若该语言的 LSP server 可用,返回符号大纲 + 提示(用 offset/limit 读具体范围);
    // 否则维持原"too large"错误串(无 server 无法出大纲)。显式 offset/limit 放行。
    if (!has_offset and !has_limit) {
        if (st) |s| {
            if (s.size > MAX_FILE_BYTES) {
                if (symbol_provider.hasSymbolsFor(ctx, path)) {
                    switch (try readOutlineFromFd(allocator, ctx, path, fd)) {
                        .text => |outline| {
                            defer allocator.free(outline);
                            return try std.fmt.allocPrint(allocator, "File too large to show in full ({d} bytes, limit {d}). Outline below; Read a range with offset+limit for bodies.\n\n{s}", .{ s.size, MAX_FILE_BYTES, outline });
                        },
                        .no_symbols => {},
                        // 走到这里说明门禁刚判过 .available(hasSymbolsFor 与上面同一个谓词),
                        // 所以只有 server 在两次调用之间死掉才会命中——兜底,不是主路径。
                        .unavailable => |u| {
                            if (want_outline and outline_gap == null) outline_gap = u;
                        },
                    }
                }
                // 这条已经是终局提示,没有"末尾追加"的机会 → 显式请求过 outline 的话就地交代。
                if (outline_gap) |u| {
                    var why_buf: [symbol_provider.capability.WHY_BUF]u8 = undefined;
                    return try std.fmt.allocPrint(allocator, "{{\"error\":\"file too large ({d} bytes, limit {d}). Read a range with offset+limit, or use Grep to find specific content. No outline was available: {s}.\"}}", .{ s.size, MAX_FILE_BYTES, u.why(&why_buf) });
                }
                return try std.fmt.allocPrint(allocator, "{{\"error\":\"file too large ({d} bytes, limit {d}). Read a range with offset+limit, or use Grep to find specific content.\"}}", .{ s.size, MAX_FILE_BYTES });
            }
        }
    }

    // 大文件(≥10MB)走流式区间读(O(区间) 内存,对齐 cc readFileInRange 流式路径)。只有显式
    // offset/limit 能到这——默认无参路径已被 256KB 守卫拦。
    if (st) |s| {
        if (s.size >= STREAM_PATH_MIN_SIZE) {
            return try readRangeStreaming(allocator, ctx, path, fd, s, offset_1based, limit);
        }
    }

    // fast path(< 10MB):整读 + 内存切片(快)。
    const full = try common.readAllFromFd(fd, allocator);
    defer allocator.free(full);

    // 切片 [offset .. offset+limit) 行（1-based，offset=1 表示第一行）
    var line_start: usize = 0;
    var line_idx: usize = 1;
    while (line_idx < offset_1based and line_start < full.len) : (line_idx += 1) {
        const nl = std.mem.indexOfScalarPos(u8, full, line_start, '\n') orelse {
            // 不足 offset 行 → 返回空
            return try emptyBodyOrOutlineNote(allocator, outline_gap);
        };
        line_start = nl + 1;
    }
    // 空文件/区间越界:内容为空。要过 outline 却没能力时,这里同样得交代——否则
    // 空串就成了另一种"能力缺失伪装成没内容"。
    if (line_start >= full.len) return try emptyBodyOrOutlineNote(allocator, outline_gap);

    // 取 limit 行
    var end: usize = line_start;
    var count: usize = 0;
    while (count < limit and end < full.len) : (count += 1) {
        const nl = std.mem.indexOfScalarPos(u8, full, end, '\n') orelse {
            end = full.len;
            break;
        };
        end = nl + 1;
    }

    // 成功读取（不管有没有内容）都记录 ReadState，后续 Write/Edit 才能放行
    if (ctx.read_state) |rs| {
        if (st) |s| rs.recordHashed(path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, full)) catch {};
    }

    // 输出封顶(对齐 cc maxBytes):区间内容超 MAX_READ_OUTPUT_BYTES → 截到最后完整行 + 提示。
    // 覆盖显式 limit=huge 在 <10MB 文件上绕过守卫返回过多的情形。
    const capd = capToLastLine(full[line_start..end], MAX_READ_OUTPUT_BYTES);
    var rendered = try renderWithLineNumbers(capd.slice, offset_1based, allocator);
    if (capd.truncated) {
        // 有完整行 → 给精确续读行号(offset 分页);无完整行(单行超 cap)→ 长行提示(offset 会死循环)。
        const lines_shown = countLines(capd.slice);
        const noted = if (lines_shown > 0)
            try appendTruncNote(allocator, rendered, offset_1based + lines_shown)
        else
            try appendLongLineNote(allocator, rendered);
        allocator.free(rendered);
        rendered = noted;
    }

    // 显式要过 outline 但能力缺失 → 在正常内容后交代原因(别让"回退正常读"看起来像"这文件没结构")。
    if (outline_gap) |u| {
        var why_buf: [symbol_provider.capability.WHY_BUF]u8 = undefined;
        const noted = try std.fmt.allocPrint(allocator, "{s}\n\n<system-reminder>Outline was requested but is unavailable: {s}. The full file content is shown above instead; this does NOT mean the file has no structure.</system-reminder>", .{ rendered, u.why(&why_buf) });
        allocator.free(rendered);
        rendered = noted;
    }

    // 弱提示(搭车):整读(无 offset/limit)一个**有 LSP server 的**大源码文件时,在结果末尾追加
    // system-reminder,引导"定位定义可用 CodeMap/FindSymbol 更快"。频控:同一文件本 session 只提
    // 一次(read_state.hinted)。触发(全满足):无 offset/limit + hasSymbolsFor(有 server)+ >150 行 +
    // 没提过。Y2 砍 tree-sitter 后不再廉价解析验"真有符号"(为 hint 起 LSP server 太浪费)——用
    // "有 server" 作 CodeMap/FindSymbol 可用的代理,过度提示的代价仅一句软提醒。
    // outline_gap != null 时不提:大纲刚因为能力缺失落空,再劝"用 CodeMap/FindSymbol 更快"
    // 是把模型往同一堵墙上引。
    // **判定顺序按成本排**:hasSymbolsFor 要扫一遍 PATH(30 段实测 36µs),而 Read 是高频工具;
    // 去重命中和小文件本来就不该提示,先用它们把绝大多数 Read 挡在 PATH 扫描之前。
    if (!has_offset and !has_limit and outline_gap == null) {
        const already = if (ctx.read_state) |rs| rs.wasHinted(path) else false;
        const total_lines = std.mem.count(u8, full, "\n") + 1;
        if (!already and total_lines > 150 and symbol_provider.hasSymbolsFor(ctx, path)) {
            if (ctx.read_state) |rs| rs.markHinted(path);
            defer allocator.free(rendered);
            return try std.fmt.allocPrint(allocator, "{s}\n\n<system-reminder>This is a {d}-line source file. If you only need to find where something is defined, CodeMap (a structural outline) or FindSymbol (jump to a named definition) would be faster and cheaper than reading the whole file.</system-reminder>", .{ rendered, total_lines });
        }
    }
    return rendered;
}

const CapResult = struct { slice: []const u8, truncated: bool };
/// 截到 ≤max 内最后一个完整行(保留末尾 '\n');无换行则硬截到 max。
fn capToLastLine(content: []const u8, max: usize) CapResult {
    if (content.len <= max) return .{ .slice = content, .truncated = false };
    const nl = std.mem.lastIndexOfScalar(u8, content[0..max], '\n');
    const cut = if (nl) |i| i + 1 else max;
    return .{ .slice = content[0..cut], .truncated = true };
}

/// 内容为空时的返回值:没有待说明的 outline 缺失 → 空串(旧行为);有 → 只回一句说明。
fn emptyBodyOrOutlineNote(allocator: std.mem.Allocator, gap: ?symbol_provider.Unavailable) ![]u8 {
    const u = gap orelse return try allocator.dupe(u8, "");
    var why_buf: [symbol_provider.capability.WHY_BUF]u8 = undefined;
    return try std.fmt.allocPrint(allocator, "<system-reminder>Outline was requested but is unavailable: {s}. The file (or the requested range) is empty.</system-reminder>", .{u.why(&why_buf)});
}

/// 截断提示带**精确续读行号**(三件套第③件:分页导引)。resume_line = 已展示的最后一行的下一行,
/// 模型 `Read(offset=resume_line)` 即从截断处无缝续读。比"narrow the range"猜测式提示精确得多。
fn appendTruncNote(allocator: std.mem.Allocator, rendered: []const u8, resume_line: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n… [output truncated at {d} bytes to protect the context window. To continue, Read this file again with offset={d} (and an optional limit). Or use Grep to jump to specific content.]",
        .{ rendered, MAX_READ_OUTPUT_BYTES, resume_line },
    );
}

/// 数一段内容里的行数(\n 数),用于算续读行号。
fn countLines(s: []const u8) usize {
    return std.mem.count(u8, s, "\n");
}

/// 单行超 cap(无完整行边界)的截断提示:**不给 offset**(续读行号不前进 → 模型死循环)。改引导 Grep。
fn appendLongLineNote(allocator: std.mem.Allocator, rendered: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n… [output truncated: this content is a single line longer than {d} bytes (each line is also per-line-truncated). offset paging can't advance within one line — use Grep to find specific content.]",
        .{ rendered, MAX_READ_OUTPUT_BYTES },
    );
}

/// 大文件(≥10MB)流式区间读:chunk 读,只累积 [offset, offset+limit) 行,区间外计数丢弃(**O(区间)
/// 内存**,不整读)。输出封顶 MAX_READ_OUTPUT_BYTES。ReadState content_hash=0(未读全文件 → mtime
/// staleness 兜底,保守)。对齐 cc readFileInRange 的 createReadStream 流式路径。
fn readRangeStreaming(
    allocator: std.mem.Allocator,
    ctx: *const ToolContext,
    path: []const u8,
    fd: pfs.Fd,
    st: read_state.StatInfo,
    offset_1based: usize,
    limit: usize,
) ![]u8 {
    var chunk: [65536]u8 = undefined;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var line_no: usize = 1;
    const end_line = offset_1based +| limit; // saturating:limit 巨大不溢出
    var capped = false;
    stream: while (true) {
        const n = pfs.readZ(fd, &chunk) catch return error.ReadError;
        if (n == 0) break;
        for (chunk[0..@intCast(n)]) |b| {
            if (line_no >= offset_1based and line_no < end_line) {
                if (out.items.len < MAX_READ_OUTPUT_BYTES) {
                    try out.append(allocator, b);
                } else {
                    capped = true;
                }
            }
            if (b == '\n') {
                line_no += 1;
                if (line_no >= end_line) break :stream;
            }
        }
        if (capped) break;
    }
    // offset 超文件行数 → 空(与 fast path 一致)。
    if (out.items.len == 0) return try allocator.dupe(u8, "");
    // 字节封顶可能停在半行——对齐 fast path 的 capToLastLine:有完整行则裁回最后一个 '\n'(半行不
    // 伪装成完整行、续读行号精确);无 '\n'(单行超 cap)保留,交 renderWithLineNumbers 的 MAX_LINE_BYTES。
    if (capped) {
        if (std.mem.lastIndexOfScalar(u8, out.items, '\n')) |nl| out.items.len = nl + 1;
    }
    // 流式未读全文件 → content_hash=0(保守:mtime 变即 stale,强制重读)。
    if (ctx.read_state) |rs| rs.recordHashed(path, st.mtime_ns, st.size, 0) catch {};
    var rendered = try renderWithLineNumbers(out.items, offset_1based, allocator);
    if (capped) {
        const lines_shown = countLines(out.items);
        const noted = if (lines_shown > 0)
            try appendTruncNote(allocator, rendered, offset_1based + lines_shown)
        else
            try appendLongLineNote(allocator, rendered);
        allocator.free(rendered);
        rendered = noted;
    }
    return rendered;
}

fn isTrue(s: ?[]const u8) bool {
    return s != null and std.mem.eql(u8, s.?, "true");
}

/// outline 模式:打开文件、读全量、渲染符号大纲。三态见 `code_map.Outline`(调用方按态分流)。
fn readOutline(allocator: std.mem.Allocator, ctx: *const ToolContext, path: []const u8) !code_map.Outline {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = pfs.close(fd);
    return try readOutlineFromFd(allocator, ctx, path, fd);
}

/// 已有 fd 时渲染大纲(大文件守卫路径复用,避免重开)。三态见 `code_map.Outline`。
fn readOutlineFromFd(allocator: std.mem.Allocator, ctx: *const ToolContext, path: []const u8, fd: pfs.Fd) !code_map.Outline {
    const source = try common.readAllFromFd(fd, allocator);
    defer allocator.free(source);
    return try code_map.renderOutlineForSource(ctx, allocator, path, source);
}

/// 把切片按行加 "%6d\t" 前缀（对齐 TS cat -n）。
/// 输入 slice 可能以 \n 结尾或不以 \n 结尾；尾行不足时仍带前缀，尾部不强制补 \n。
/// 行号从 start_line 开始递增。空切片返回空串。
fn renderWithLineNumbers(slice: []const u8, start_line: usize, allocator: std.mem.Allocator) ![]u8 {
    if (slice.len == 0) return try allocator.dupe(u8, "");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_no = start_line;
    var pos: usize = 0;
    while (pos < slice.len) {
        const nl = std.mem.indexOfScalarPos(u8, slice, pos, '\n');
        const line_end = nl orelse slice.len;
        var buf: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&buf, "{d: >6}\t", .{line_no});
        try out.appendSlice(allocator, prefix);
        // 单行超长 → 截断到 MAX_LINE_BYTES(UTF-8 边界安全)+ 标记,防 minified 一行几 MB 撑爆。
        const raw_line = slice[pos..line_end];
        if (raw_line.len > MAX_LINE_BYTES) {
            var cut = MAX_LINE_BYTES;
            while (cut > 0 and (raw_line[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
            try out.appendSlice(allocator, raw_line[0..cut]);
            try out.appendSlice(allocator, " … [line truncated]");
        } else {
            try out.appendSlice(allocator, raw_line);
        }
        if (nl) |i| {
            try out.append(allocator, '\n');
            pos = i + 1;
        } else {
            pos = slice.len;
        }
        line_no += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

/// 阻塞/无限设备路径黑名单——读这些会 hang 或无限流。
const DEVICE_PATHS = [_][]const u8{
    "/dev/zero",  "/dev/random", "/dev/urandom", "/dev/null",
    "/dev/stdin", "/dev/stdout", "/dev/stderr",  "/dev/full",
    "/dev/tty",   "/dev/ptmx",
};

fn rejectDevicePath(path: []const u8) !void {
    for (DEVICE_PATHS) |dp| {
        if (std.mem.eql(u8, path, dp)) return error.DevicePathBlocked;
    }
    // /dev/fd/* 与 /proc/*/fd/* 也容易 hang
    if (std.mem.startsWith(u8, path, "/dev/fd/")) return error.DevicePathBlocked;
}

/// 按扩展名判定图像 media_type；非图像返 null。
/// pub:headless --image 入口复用同一 MIME 白名单(png/jpg/jpeg/gif/webp)。
pub fn imageMediaType(path: []const u8) ?[]const u8 {
    const Ext = struct { suffix: []const u8, mt: []const u8 };
    const table = [_]Ext{
        .{ .suffix = ".png", .mt = "image/png" },
        .{ .suffix = ".jpg", .mt = "image/jpeg" },
        .{ .suffix = ".jpeg", .mt = "image/jpeg" },
        .{ .suffix = ".gif", .mt = "image/gif" },
        .{ .suffix = ".webp", .mt = "image/webp" },
    };
    for (table) |e| {
        if (endsWithIgnoreCase(path, e.suffix)) return e.mt;
    }
    return null;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    const tail = s[s.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// 图像读取上限（base64 前的原始字节）。Anthropic 单图 ~5MB 限制，留余量取 3.75MB。
/// pub:headless --image 入口沿用同一上限(单一真相)。
pub const MAX_IMAGE_BYTES: usize = 3_750_000;

/// 读图像 → base64 → 返回结构化 JSON：{"type":"image","media_type":"...","data":"<b64>"}。
/// api/request.zig 的 serializeContent 检测到此形态会发成真正的 image content block。
fn readImage(allocator: std.mem.Allocator, ctx: *const ToolContext, path: []const u8, media_type: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = pfs.close(fd);

    const st = read_state.statFd(fd) catch null;
    if (st) |s| {
        if (s.size > MAX_IMAGE_BYTES) return error.ImageTooLarge;
    }

    const raw = try common.readAllFromFd(fd, allocator);
    defer allocator.free(raw);
    if (raw.len > MAX_IMAGE_BYTES) return error.ImageTooLarge;

    // base64 编码
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(raw.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = enc.encode(b64, raw);

    // 记录 ReadState（图像也算"读过"，后续 Write 才放行）
    if (ctx.read_state) |rs| {
        if (st) |s| rs.recordHashed(path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, raw)) catch {};
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"type\":\"image\",\"media_type\":");
    try std.json.Stringify.encodeJsonString(media_type, .{}, &out.writer);
    try out.writer.writeAll(",\"data\":");
    try std.json.Stringify.encodeJsonString(b64, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

test "imageMediaType detects extensions" {
    try std.testing.expectEqualStrings("image/png", imageMediaType("/x/y.png").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("a.JPG").?);
    try std.testing.expectEqualStrings("image/webp", imageMediaType("z.webp").?);
    try std.testing.expect(imageMediaType("foo.txt") == null);
    try std.testing.expect(imageMediaType("noext") == null);
}

test "rejectDevicePath blocks devices" {
    try std.testing.expectError(error.DevicePathBlocked, rejectDevicePath("/dev/zero"));
    try std.testing.expectError(error.DevicePathBlocked, rejectDevicePath("/dev/fd/3"));
    try rejectDevicePath("/tmp/normal.txt"); // 不报错
}

test "ReadTool device path blocked via execute" {
    const ctx = testCtx();
    try std.testing.expectError(error.DevicePathBlocked, execute(&ctx, "{\"file_path\":\"/dev/zero\"}"));
}

test "ReadTool image returns structured json" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-img-test.png";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 4 字节假 PNG header
    const bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47 };
    _ = pfs.write(fd, &bytes);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-img-test.png\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"media_type\":\"image/png\"") != null);
    // base64 of 0x89504E47 = "iVBORw=="
    try std.testing.expect(std.mem.indexOf(u8, r, "iVBORw") != null);
}

test "ReadTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"x\"}"));
}

test "ReadTool path traversal blocked (file_path)" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"file_path\":\"../../etc/passwd\"}"));
}

test "ReadTool read /etc/hosts via file_path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:读 /etc/hosts 系统文件 / inline shell 执行
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool read /etc/hosts via legacy path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:读 /etc/hosts 系统文件 / inline shell 执行
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool offset beyond file returns empty" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:读 /etc/hosts 系统文件 / inline shell 执行
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"offset\":1000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len == 0);
}

test "ReadTool offset=0 is invalid" {
    const ctx = testCtx();
    try std.testing.expectError(error.InvalidOffset, execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"offset\":0}"));
}

test "ReadTool offset/limit extracts correct slice" {
    const ctx = testCtx();
    // 直接用 libc 写一个 10 行的文件（绕过 write 工具的 JSON 转义差异）
    const path_cstr = "/tmp/cc-zig-read-offset-test.txt";
    const fd = pfs.open(path_cstr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path_cstr);

    // offset=3, limit=2 → 带 cat -n 前缀，行号从 3 开始
    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-offset-test.txt\",\"offset\":3,\"limit\":2}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     3\tline3\n     4\tline4\n", r);
}

test "ReadTool first line has line-number prefix 1" {
    const ctx = testCtx();
    const path_cstr = "/tmp/cc-zig-read-ln1-test.txt";
    const fd = pfs.open(path_cstr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "hello\nworld\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path_cstr);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-ln1-test.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     1\thello\n     2\tworld\n", r);
}

test "ReadTool file without trailing newline still gets prefix" {
    const ctx = testCtx();
    const path_cstr = "/tmp/cc-zig-read-noeol-test.txt";
    const fd = pfs.open(path_cstr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "noeol";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path_cstr);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-noeol-test.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     1\tnoeol", r);
}

test "ReadTool limit caps very large file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:读 /etc/hosts 系统文件 / inline shell 执行
    const ctx = testCtx();
    // /etc/hosts 一般 1 行；limit=10000 不会报错
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"limit\":10000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool default limit reads at least first line" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:读 /etc/hosts 系统文件 / inline shell 执行
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool 大文件整读被拒(防撑爆);带 offset/limit 放行" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-toobig.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 > 256KB(每行短,行数也多)。
    const line = "abcdefghij\n"; // 11 bytes
    var i: usize = 0;
    while (i < 30000) : (i += 1) _ = pfs.write(fd, line); // ~330KB
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    // 整读(无 offset/limit)→ 拒读 + too large 提示。
    const r1 = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-toobig.txt\"}");
    defer std.testing.allocator.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "too large") != null);

    // 带 limit → 放行(读前 N 行)。
    const r2 = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-toobig.txt\",\"limit\":5}");
    defer std.testing.allocator.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "too large") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "abcdefghij") != null);
}

test "ReadTool 超长单行被截断 + 标记" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-longline.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 一行 5000 个 'x'(超过 MAX_LINE_BYTES=2000),文件总字节 < 256KB 不触发大文件守卫。
    const big_line = "x" ** 5000;
    _ = pfs.write(fd, big_line);
    _ = pfs.write(fd, "\n");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-longline.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "line truncated") != null);
    // 截断后该行的 x 数应 ≤ MAX_LINE_BYTES。
    var xcount: usize = 0;
    for (r) |c| {
        if (c == 'x') xcount += 1;
    }
    try std.testing.expect(xcount <= MAX_LINE_BYTES);
}

test "Read 缓存失效提示:tool-results 下不存在的 path → 可操作提示,非裸 FileNotFound" {
    const ctx = testCtx();
    // tool-results 缓存被 TTL/LRU 清理后的旧 path → 提示重跑原工具(非神秘 FileNotFound)。
    const r = try execute(&ctx, "{\"file_path\":\"/tmp/nope-xyz/.metacodes/tool-results/deadbeef.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "no longer exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "Re-run") != null);
    // 普通不存在路径(不在 tool-results 下)仍是 FileNotFound。
    try std.testing.expectError(error.FileNotFound, execute(&ctx, "{\"file_path\":\"/tmp/nope-xyz/regular-missing.txt\"}"));
}

test "Read 输出封顶:显式 limit=huge 在 <10MB 文件上超 256KB → 截到最后完整行 + 提示" {
    const a = std.testing.allocator;
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-outcap.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 ~320KB(8000 行 × 40 字节,编号可区分),<10MB 走 fast path。显式 limit 绕过 256KB 整读守卫。
    // 每行 = "L" + 6 位编号 + 32 个 '.' + '\n' = 40 字节。
    var lbuf: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        _ = std.fmt.bufPrint(&lbuf, "L{d:0>6}", .{i}) catch unreachable; // "L000000"
        @memset(lbuf[7..39], '.');
        lbuf[39] = '\n';
        _ = pfs.write(fd, &lbuf);
    }
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-outcap.txt\",\"limit\":999999}");
    defer a.free(r);
    // 封顶:输出被截 + 精确续读提示。100KB/40 ≈ 2560 行 → 早行在、晚行被截掉。
    try std.testing.expect(std.mem.indexOf(u8, r, "output truncated") != null);
    // 精确续读行号:100KB/40字节=2560 行整除 → 展示 1..2560 → 续读 offset=2561(pin 死数值防 render 改动漂移)。
    try std.testing.expect(std.mem.indexOf(u8, r, "offset=2561") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "L000100") != null); // 早行在
    try std.testing.expect(std.mem.indexOf(u8, r, "L003000") == null); // 晚行被截(第 3000 行 > 2560)
}

test "Read 输出封顶:单行 >100KB → 长行提示不给 offset(防死循环)" {
    const a = std.testing.allocator;
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-longline-cap.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 一整行 150KB(无 '\n',>MAX_READ_OUTPUT_BYTES=100KB),<256KB 不触发大文件守卫。
    var payload: [150 * 1024]u8 = undefined;
    @memset(&payload, 'q');
    _ = pfs.write(fd, &payload);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-longline-cap.txt\"}");
    defer a.free(r);
    // capToLastLine 无 '\n' → countLines=0 → 走长行提示:引导 Grep,**绝不**给 offset(否则模型死循环)。
    try std.testing.expect(std.mem.indexOf(u8, r, "single line longer") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "offset=") == null); // 无 offset 续读指引
}

test "Read 流式:≥10MB 文件读中间区间不 OOM,返回正确的中间行" {
    const a = std.testing.allocator;
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-stream.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 ~11MB(>10MB 触发流式路径):每行 "L<编号>\n"。用 1000 行/块的缓冲减少 syscall。
    var buf: [64 * 1024]u8 = undefined;
    var n_lines: usize = 0;
    while (n_lines < 400_000) { // 400k 行 × ~28 字节 ≈ 11MB
        var w: usize = 0;
        while (w < buf.len - 32 and n_lines < 400_000) {
            const s = std.fmt.bufPrint(buf[w..], "L{d}\n", .{n_lines}) catch break;
            w += s.len;
            n_lines += 1;
        }
        _ = pfs.write(fd, buf[0..w]);
    }
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    // 读中间:offset=200000, limit=3 → 应返回 L199999/L200000/L200001(1-based offset=200000 = 第 200000 行)。
    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-stream.txt\",\"offset\":200000,\"limit\":3}");
    defer a.free(r);
    // 第 200000 行内容是 "L199999"(0-based 编号,1-based 行号差 1)。
    try std.testing.expect(std.mem.indexOf(u8, r, "L199999") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "L200001") != null);
    // 不应含开头/结尾行(证明只读了中间区间,没整读)。
    try std.testing.expect(std.mem.indexOf(u8, r, "L0\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "L399999") == null);
}

test "Read 流式:≥10MB 大范围触发 100KB 封顶 → 裁到完整行 + 精确续读 offset" {
    const a = std.testing.allocator;
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-stream-cap.txt";
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // ~11MB(>10MB 流式);读大范围 → 累积到 100KB 封顶。行 "R<6位>....\n" = 40 字节。
    var buf: [64 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < 300_000) {
        var w: usize = 0;
        while (w + 40 <= buf.len and n < 300_000) {
            var lb: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&lb, "R{d:0>6}", .{n}) catch unreachable;
            @memset(lb[7..39], '.');
            lb[39] = '\n';
            @memcpy(buf[w .. w + 40], &lb);
            w += 40;
            n += 1;
        }
        _ = pfs.write(fd, buf[0..w]);
    }
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path);

    // offset=1 大 limit → 流式从头累积到 100KB(2560 行)封顶。
    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-stream-cap.txt\",\"offset\":1,\"limit\":9999999}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "output truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "offset=2561") != null); // 裁到完整行 → 续读精确
    try std.testing.expect(std.mem.indexOf(u8, r, "R000010") != null); // 早行在
    try std.testing.expect(std.mem.indexOf(u8, r, "R003000") == null); // 封顶后不在
    // 裁到完整行 → 末尾不是半行(不含伪装成完整行的半行)。
    try std.testing.expect(std.mem.indexOf(u8, r, "line truncated") == null);
}

test "Read 流式:offset 超文件行数 → 空" {
    const a = std.testing.allocator;
    const ctx = testCtx();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/read-stream-eof.txt", .{root_buf[0..root_len]});
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // ~11MB 文件,offset 远超行数。
    var buf: [64 * 1024]u8 = undefined;
    @memset(&buf, 'a');
    buf[buf.len - 1] = '\n';
    var w: usize = 0;
    while (w < 176) : (w += 1) _ = pfs.write(fd, &buf); // ~11MB,~176 行(每行 64KB)
    _ = pfs.close(fd);

    const args = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"offset\":9999999,\"limit\":5}}", .{path});
    defer a.free(args);
    const r = try execute(&ctx, args);
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

/// hint 的门禁自 issue #17 起包含"那个 server 的二进制真的装了",所以断言必须**跟着机器变**:
/// 装了 zls → 该提;没装 → 不该提(CodeMap/FindSymbol 那时也用不了,提了是误导)。
/// 刻意不写成"没装就 SkipZigTest"——被 skip 掉的正是这个 bug 当初藏身的那一侧。
fn zlsInstalled() bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return @import("../lsp/servers.zig").which("zls", &buf) != null;
}

test "Read 弱提示:--lsp 开 + >150行 + zls 真装了 → CodeMap reminder;小文件/非源码/无 --lsp/没装 server 不追加" {
    const a = std.testing.allocator;
    // Y2 砍 tree-sitter 后:hint 由 hasSymbolsFor gate(ctx.lsp 开 + 该扩展名有注册 server +
    // 该 server 二进制可解析)。
    const Service = @import("../lsp/service.zig").Service;
    var svc = Service.create(a, "/tmp", null) catch return;
    defer svc.shutdown();
    var ctx = testCtx();
    ctx.lsp = svc;

    // 大源码文件(200 行 .zig)→ 装了 zls 才带 reminder
    const want_hint = zlsInstalled();
    {
        const path = "/tmp/cc-zig-read-hint-big.zig";
        const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const line = "const x = 1;\n";
            _ = pfs.write(fd, line);
        }
        _ = pfs.close(fd);
        defer _ = std.c.unlink(path);

        const r = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-read-hint-big.zig\"}");
        defer a.free(r);
        try std.testing.expectEqual(want_hint, std.mem.indexOf(u8, r, "<system-reminder>") != null);
        try std.testing.expectEqual(want_hint, std.mem.indexOf(u8, r, "CodeMap") != null);
    }
    // 小源码文件(10 行)→ 不带 reminder
    {
        const path = "/tmp/cc-zig-read-hint-small.zig";
        const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        const text = "const a = 1;\nconst b = 2;\n";
        _ = pfs.write(fd, text);
        _ = pfs.close(fd);
        defer _ = std.c.unlink(path);

        const r = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-read-hint-small.zig\"}");
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "<system-reminder>") == null);
    }
    // 大的非源码文件(.txt 200 行,无 server)→ 不带 reminder
    {
        const path = "/tmp/cc-zig-read-hint-big.txt";
        const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const line = "plain text line\n";
            _ = pfs.write(fd, line);
        }
        _ = pfs.close(fd);
        defer _ = std.c.unlink(path);

        const r = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-read-hint-big.txt\"}");
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "<system-reminder>") == null);
    }
    // **无 --lsp**(ctx.lsp==null):即便大源码文件也不 hint(Y2 砍 tree-sitter 后 hint 依赖 LSP)。
    {
        const noctx = testCtx();
        const path = "/tmp/cc-zig-read-hint-nolsp.zig";
        const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const line = "const x = 1;\n";
            _ = pfs.write(fd, line);
        }
        _ = pfs.close(fd);
        defer _ = std.c.unlink(path);

        const r = try execute(&noctx, "{\"path\":\"/tmp/cc-zig-read-hint-nolsp.zig\"}");
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "<system-reminder>") == null);
    }
}

test "Read 弱提示:同 session 同文件只提一次(dedup);没装 server 则一次都不提" {
    // Y2 砍 tree-sitter 后 hint 不再廉价验"真有符号"(为 hint 起 LSP server 太浪费),简化为
    // hasSymbolsFor(有 server 且装了)+ >150 行——纯注释源码也会提(轻微 over-hint,登记的取舍)。
    const a = std.testing.allocator;
    const Service = @import("../lsp/service.zig").Service;
    var svc = Service.create(a, "/tmp", null) catch return;
    defer svc.shutdown();

    // 带真 ReadState 的 ctx:同一文件读两次,只有第一次带 reminder(session 去重)
    {
        var rs = read_state.ReadState.init(a);
        defer rs.deinit();
        var ctx = testCtx();
        ctx.read_state = &rs;
        ctx.lsp = svc;

        const path = "/tmp/cc-zig-read-hint-dedup.zig";
        const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const line = "pub fn f() void {}\n";
            _ = pfs.write(fd, line);
        }
        _ = pfs.close(fd);
        defer _ = std.c.unlink(path);

        const r1 = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-read-hint-dedup.zig\"}");
        defer a.free(r1);
        // 装了 zls:第一次提。没装:两次都不提(能力缺失时提 CodeMap 是误导)。
        try std.testing.expectEqual(zlsInstalled(), std.mem.indexOf(u8, r1, "<system-reminder>") != null);

        const r2 = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-read-hint-dedup.zig\"}");
        defer a.free(r2);
        try std.testing.expect(std.mem.indexOf(u8, r2, "<system-reminder>") == null); // 第二次一律不提
    }
}

test "ReadTool ~ 展开端到端(主 bug 回归)" {
    // 原始 bug:~/foo 不展开 → openat 找字面 ~ 目录 → FileNotFound。
    // 写 fixture 到 tmpdir,把 home_dir 注入为 tmpdir,Read `~/fixture` 应展开并读到内容。
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const fpath = tt.path(&pbuf, "tilde-expand-read.txt");
    const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "tilde-needle-content";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(fpath.ptr);

    // home_dir = per-pid 临时目录(可移植);故 ~/tilde-expand-read.txt 展开到 fixture。
    var hbuf: [512]u8 = undefined;
    const home = tt.dir(&hbuf);
    var ctx = ToolContext.simple(a);
    ctx.home_dir = home;

    const r = try execute(&ctx, "{\"file_path\":\"~/tilde-expand-read.txt\"}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "tilde-needle-content") != null);
}

test "ReadTool 含 .. 的合法文件名不被误杀" {
    // 旧 indexOf("..") 会误杀;新 containsTraversal 只匹配路径段 .. → 这个文件名应放行。
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const fpath = tt.path(&pbuf, "my..legit..file.txt");
    const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = pfs.write(fd, "ok");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(fpath.ptr);

    var abuf: [320]u8 = undefined;
    const args = std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\"}}", .{fpath}) catch unreachable;
    const ctx = testCtx();
    const r = try execute(&ctx, args); // 不应 PathTraversal
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "ok") != null);
}

test "Read outline e2e: 真 zls documentSymbol → 大纲(需装 zls)" {
    const a = std.testing.allocator;
    const lsp_servers = @import("../lsp/servers.zig");
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (lsp_servers.which("zls", &zbuf) == null) return error.SkipZigTest; // 未装 → skip

    const base = std.fmt.allocPrint(a, "/tmp/cc_lsp_read_{d}", .{pprocess.currentPid()}) catch return;
    defer a.free(base);
    e2eMkdir(base);
    const gitdir = std.fmt.allocPrint(a, "{s}/.git", .{base}) catch return;
    defer a.free(gitdir);
    e2eMkdir(gitdir);
    const file = std.fmt.allocPrint(a, "{s}/mod.zig", .{base}) catch return;
    defer a.free(file);
    e2eWrite(file,
        \\pub const Widget = struct {
        \\    id: u32,
        \\};
        \\
        \\pub fn build() Widget {
        \\    return .{ .id = 0 };
        \\}
        \\
    );

    const Service = @import("../lsp/service.zig").Service;
    var svc = Service.create(a, base, null) catch return;
    defer svc.shutdown();

    var ctx = ToolContext.simple(a);
    ctx.lsp = svc;
    ctx.cwd_abs = base;

    var abuf: [512]u8 = undefined;
    const args = std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"outline\":true}}", .{file}) catch unreachable;
    const r = try execute(&ctx, args);
    defer a.free(r);

    // 大纲应含 zls 报出的 Widget 与 build 符号(证 read→provider→LSP→真 zls 全链)。
    try std.testing.expect(std.mem.indexOf(u8, r, "Widget") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "build") != null);
}

fn e2eMkdir(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.mkdir(z.ptr, 0o755);
}
fn e2eWrite(path: []const u8, content: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = pfs.close(fd);
    _ = pfs.write(fd, content);
}
