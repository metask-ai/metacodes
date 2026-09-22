const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const util_json = @import("../util/json.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;
const tt = @import("test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const file_path_raw = common.extractJsonArg(args, "file_path") orelse return error.MissingFilePath;
    const old_raw = common.extractJsonArg(args, "old_string") orelse return error.MissingOldString;
    const new_raw = common.extractJsonArg(args, "new_string") orelse return error.MissingNewString;

    if (file_path_raw.len == 0) return error.EmptyFilePath;
    // Tool arguments are still JSON-escaped slices.  Write already decodes
    // its path before normalization; Edit must do the same, especially for a
    // host-synthesized exact Edit whose normalized path was encoded back into
    // JSON.  Otherwise a legal quote or backslash in the filename passes the
    // formal sensor but reaches a different native path.
    const file_path_unescaped = try util_json.unescapeString(file_path_raw, allocator);
    defer allocator.free(file_path_unescaped);
    if (file_path_unescaped.len == 0) return error.EmptyFilePath;
    // Empty existing files are a valid whole-file recovery source. Ordinary
    // Edit still rejects an empty needle because substring replacement would
    // be undefined/degenerate.
    if (old_raw.len == 0 and ctx.project_edit_mode != .whole_file_exact)
        return error.EmptyOldString;
    // 归一化(展开 ~、折叠、查 traversal)。openat 不认 ~,必须自己展开。
    const file_path = try path_mod.normalizeChecked(allocator, file_path_unescaped, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(file_path);

    // Ordinary Edit requires a prior model-visible Read. A Lean-admitted
    // whole-file recovery is different: the host already captured the exact
    // source bytes, recovery-pre proved the source commitment current, and
    // executeWholeFileExact reopens one no-follow fd and compares every byte
    // again before writing. Requiring ReadState here would reintroduce a model
    // round trip after the deterministic host rewrite and can reject a valid
    // recovery even though its stronger source check is already authoritative.
    if (ctx.project_edit_mode != .whole_file_exact) {
        if (ctx.read_state) |rs| {
            const st = read_state.statPath(file_path) catch return error.FileNotFound;
            const rec = rs.get(file_path) orelse return error.NotRead;
            // staleness 双判:mtime 变但内容哈希没变 → 不算 stale(对齐 cc FileEdit)。
            if (rec.mtime_ns != st.mtime_ns) {
                const cur_hash = read_state.hashFileContent(file_path);
                if (rec.content_hash == 0 or cur_hash != rec.content_hash) return error.StaleFile;
            }
        }
    }

    // old/new 是 JSON 字符串值的原始切片（未 unescape）。Edit 对字节精确匹配敏感，
    // 必须先反转义回真实字节（\n → LF，\t → TAB 等）。
    const old_unesc = try util_json.unescapeString(old_raw, allocator);
    defer allocator.free(old_unesc);
    const new_unesc = try util_json.unescapeString(new_raw, allocator);
    defer allocator.free(new_unesc);

    // #1 no-op 拒绝(对齐 cc 错误码1):old==new 改了等于没改,空 diff,白费一轮。
    if (std.mem.eql(u8, old_unesc, new_unesc)) {
        setDetail(ctx, allocator, "Edit is a no-op: old_string and new_string are identical. Provide a different new_string.", .{});
        return error.NoOpEdit;
    }

    if (ctx.project_edit_mode == .whole_file_exact) {
        return executeWholeFileExact(
            ctx,
            allocator,
            file_path,
            old_unesc,
            new_unesc,
            args,
        );
    }

    // 处理 Read 注入的 "%6d\t" 行号前缀：模型可能原样复制。strip 后作为 fallback 匹配。
    const old_stripped = try stripLineNumberPrefix(old_unesc, allocator);
    defer allocator.free(old_stripped);
    const new_stripped = try stripLineNumberPrefix(new_unesc, allocator);
    defer allocator.free(new_stripped);

    const fd = pfs.openZ(file_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    const original = blk: {
        defer _ = pfs.close(fd);
        const sz = read_state.statFd(fd) catch null;
        if (sz) |s| {
            if (s.size > MAX_EDIT_FILE_SIZE) return error.FileTooLarge;
        }
        break :blk try common.readAllFromFd(fd, allocator);
    };
    defer allocator.free(original);

    // 先尝试原样（unescaped）匹配；没匹配到再用 stripped 版本。
    // 这样：1) 真实文件里本来就有类似 "    5\t" 这种前缀的行不被误改；2) 模型带前缀复制过来也能工作。
    const use_stripped = std.mem.indexOf(u8, original, old_unesc) == null;
    if (use_stripped and std.mem.indexOf(u8, original, old_stripped) == null) {
        // 第三次尝试：smart-quote 归一化（文件里是弯引号 “ ” ‘ ’，模型 old_string 打了直引号）。
        // 在归一化空间里定位，再映射回 original 的真实字节范围做替换。
        if (findSmartQuote(original, old_unesc)) |range| {
            var nc = std.ArrayList(u8).empty;
            defer nc.deinit(allocator);
            try nc.appendSlice(allocator, original[0..range.start]);
            try nc.appendSlice(allocator, new_unesc);
            try nc.appendSlice(allocator, original[range.end..]);
            return try finalizeWrite(ctx, allocator, file_path, original, nc.items);
        }
        setDetail(ctx, allocator, "{s}", .{notFoundDetail(original, old_unesc)});
        return error.StringNotFound;
    }
    const old_string = if (use_stripped) old_stripped else old_unesc;
    const new_string = if (use_stripped) new_stripped else new_unesc;

    const replace_all_str = common.extractJsonArg(args, "replace_all");
    const replace_all = replace_all_str != null and std.mem.eql(u8, replace_all_str.?, "true");

    if (!replace_all) {
        const first = std.mem.indexOf(u8, original, old_string).?;
        if (std.mem.indexOfPos(u8, original, first + old_string.len, old_string) != null) {
            return error.MultipleMatches;
        }
    }

    var new_content = std.ArrayList(u8).empty;
    defer new_content.deinit(allocator);

    if (replace_all) {
        var cursor: usize = 0;
        while (std.mem.indexOf(u8, original[cursor..], old_string)) |rel| {
            const abs = cursor + rel;
            try new_content.appendSlice(allocator, original[cursor..abs]);
            try new_content.appendSlice(allocator, new_string);
            cursor = abs + old_string.len;
        }
        try new_content.appendSlice(allocator, original[cursor..]);
    } else {
        const i = std.mem.indexOf(u8, original, old_string).?;
        try new_content.appendSlice(allocator, original[0..i]);
        try new_content.appendSlice(allocator, new_string);
        try new_content.appendSlice(allocator, original[i + old_string.len ..]);
    }

    return try finalizeWrite(ctx, allocator, file_path, original, new_content.items);
}

/// 写入新内容 + 刷新 ReadState mtime + 返回结果 JSON（含 structuredPatch + gitDiff）。
/// Edit 的正常路径与 smart-quote fallback 路径共用。
fn finalizeWrite(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_content: []const u8,
    content: []const u8,
) ![]u8 {
    const write_fd = pfs.openZ(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = pfs.close(write_fd);

    var pos: usize = 0;
    while (pos < content.len) {
        const written = pfs.write(write_fd, content[pos..]);
        if (written <= 0) return error.WriteError;
        pos += @intCast(written);
    }

    return finalizeCommittedWrite(
        ctx,
        allocator,
        file_path,
        old_content,
        content,
        write_fd,
        true,
    );
}

/// Lean-admitted recovery path.  It intentionally has none of ordinary
/// Edit's substring, line-number, smart-quote, or replace-all behavior.  The
/// full-file comparison and mutation use one O_NOFOLLOW RDWR descriptor so a
/// replacement of the final pathname component after formal admission cannot
/// redirect the write. Parent-directory integrity remains an environment and
/// sandbox responsibility; O_NOFOLLOW alone does not freeze every component.
fn executeWholeFileExact(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    args: []const u8,
) ![]u8 {
    if (!pfs.atomic_final_nofollow)
        return error.ProjectExactEditNativeUnavailable;
    const replace_all = common.extractJsonArg(args, "replace_all");
    if (replace_all != null and std.mem.eql(u8, replace_all.?, "true"))
        return error.ExactRecoveryReplaceAllForbidden;

    const fd = pfs.openZ(
        file_path,
        .{ .ACCMODE = .RDWR, .NOFOLLOW = true },
        0,
    ) catch return error.ExactRecoveryTargetUnavailable;
    defer _ = pfs.close(fd);
    pfs.makeCloseOnExec(fd) catch return error.ExactRecoveryTargetUnavailable;

    const before = pfs.fileInfo(fd) catch return error.ExactRecoveryTargetUnavailable;
    if (!before.is_regular or before.link_count != 1)
        return error.ExactRecoveryTargetUnavailable;
    if (before.size > MAX_EDIT_FILE_SIZE) return error.FileTooLarge;

    const observed = common.readAllFromFdCapped(
        fd,
        allocator,
        @intCast(MAX_EDIT_FILE_SIZE),
    ) catch |err| switch (err) {
        error.FileTooLarge => return error.FileTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadError,
    };
    defer allocator.free(observed);
    const after_read = pfs.fileInfo(fd) catch return error.ExactRecoveryTargetUnavailable;
    if (!after_read.is_regular or after_read.link_count != 1 or
        after_read.size != before.size or observed.len != @as(usize, @intCast(before.size)) or
        !std.mem.eql(u8, observed, old_content))
    {
        setDetail(ctx, allocator, "Exact recovery source changed after formal admission, so the old recovery obligation is stale. Re-Read the file, submit the intended Write proposal again to obtain a fresh governed recovery contract, then follow that contract; do not retry this Edit against the old obligation.", .{});
        return error.ExactRecoverySourceChanged;
    }

    replaceWholeFileFd(fd, observed, new_content) catch |err| {
        // A short write may already have changed the inode. Publish the
        // intended mutation so executeOne's mandatory re-observation records
        // the mismatch instead of accepting an invisible partial effect. The
        // helper first attempts to restore `observed`, but the post-check must
        // not trust that best-effort rollback without reading the host again.
        ctx.reportFileMutation(file_path, .{ .known = observed }, new_content);
        // A short write may already have changed the inode and the best-effort
        // rollback is not trusted. Report `partial`, not `failed`: the caller
        // must be told the file may differ from both before and after.
        ctx.reportFileChange(.{
            .path = file_path,
            .kind = .modified,
            .status = .partial,
            .before_bytes = observed.len,
            .after_bytes = new_content.len,
            .unified_diff = null,
            .diff_complete = false,
        });
        return err;
    };

    return finalizeCommittedWrite(
        ctx,
        allocator,
        file_path,
        observed,
        new_content,
        fd,
        false,
    );
}

fn writeWholeFileFd(fd: pfs.Fd, content: []const u8) error{WriteError}!void {
    if (pfs.lseek(fd, 0, .set) != 0) return error.WriteError;
    var pos: usize = 0;
    while (pos < content.len) {
        const written = pfs.write(fd, content[pos..]);
        if (written <= 0) return error.WriteError;
        pos += @intCast(written);
    }
    pfs.setSize(fd, @intCast(content.len)) catch return error.WriteError;
}

fn replaceWholeFileFd(
    fd: pfs.Fd,
    original: []const u8,
    replacement: []const u8,
) error{WriteError}!void {
    writeWholeFileFd(fd, replacement) catch {
        writeWholeFileFd(fd, original) catch {};
        pfs.fsyncChecked(fd) catch {};
        return error.WriteError;
    };
    pfs.fsyncChecked(fd) catch {
        writeWholeFileFd(fd, original) catch {};
        pfs.fsyncChecked(fd) catch {};
        return error.WriteError;
    };
}

/// Publish a committed Edit on the stable file-change contract, computing the
/// diff locally. Used by the paths that do not already have one: the Lean
/// recovery receipt (deliberately diff-free for the model) and the
/// patch-computation fallback.
fn publishCommittedChange(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_content: []const u8,
    content: []const u8,
) void {
    const patch_mod = @import("../core/patch.zig");
    var diff: ?[]u8 = null;
    defer if (diff) |d| allocator.free(d);
    if (patch_mod.compute(allocator, old_content, content)) |computed| {
        var owned = computed;
        defer owned.deinit(allocator);
        diff = patch_mod.toGitDiff(allocator, file_path, owned.hunks) catch null;
    } else |_| {}
    ctx.reportFileChange(.{
        .path = file_path,
        .kind = .modified,
        .status = if (std.mem.eql(u8, old_content, content)) .no_change else .applied,
        .before_bytes = old_content.len,
        .after_bytes = content.len,
        .unified_diff = diff,
        .diff_complete = diff != null,
    });
}

fn finalizeCommittedWrite(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_content: []const u8,
    content: []const u8,
    write_fd: pfs.Fd,
    expose_diff_to_model: bool,
) ![]u8 {
    ctx.reportFileMutation(file_path, .{ .known = old_content }, content);

    // 写完后刷新 ReadState 的 mtime + content_hash，避免紧接着再次 Edit 报 stale
    if (ctx.read_state) |rs| {
        const st = read_state.statFd(write_fd) catch null;
        if (st) |s| rs.recordHashed(file_path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, content)) catch {};
    }

    // 旁路缓存新旧全文(供 diff 工具卡 hl-zig 高亮;不进对话历史)。key=本次 tool_use id。
    if (ctx.edit_hl_cache) |cache| {
        cache.put(ctx.progress_tool_id, old_content, content);
    }

    // M2:LSP baseline snapshot 移到**盘写之后**——LSP 用 in-memory old_content 分析(不读盘),故语义
    // 不变,但盘写不再被 LSP initialize(最长 12s)阻塞。写已完成,只有工具**结果**等诊断。
    @import("lsp_diag.zig").snapshotBaseline(ctx, file_path, old_content);

    // B/C 合并:memdir 记忆 markdown 自动入图(best-effort;content=编辑后全文)。
    @import("../kg/autosync.zig").maybeImportMemoryFile(ctx, file_path, content);

    // The exact recovery source was captured by the host and was never made
    // model-visible through Read.  Ordinary Edit/Write results include removed
    // lines, but doing so here would turn Write permission into an implicit
    // read/exfiltration channel.  Keep the old/new bytes in the local effect and
    // highlight cache for host audit/UI, while returning only a bounded success
    // receipt to the provider.  The replacement content is already present in
    // the model's original Write proposal.
    if (!expose_diff_to_model) {
        // Host-side contract still owes the consumer this file's real change.
        // The diff stays out of the model-visible receipt (it would turn Write
        // permission into a read channel) but the host may see it, exactly like
        // the effect and highlight caches above.
        publishCommittedChange(ctx, allocator, file_path, old_content, content);
        var receipt: std.Io.Writer.Allocating = .init(allocator);
        defer receipt.deinit();
        try receipt.writer.writeAll("{\"file_path\":");
        try util_json.writeJsonString(&receipt.writer, file_path);
        try receipt.writer.writeAll(",\"success\":true,\"recovery\":\"lean_authorized_source_cas\"");
        try @import("lsp_diag.zig").appendToResult(
            ctx,
            allocator,
            &receipt.writer,
            file_path,
            content,
        );
        try receipt.writer.writeByte('}');
        return try receipt.toOwnedSlice();
    }

    // structuredPatch + gitDiff
    const patch_mod = @import("../core/patch.zig");
    var patch = patch_mod.compute(allocator, old_content, content) catch {
        publishCommittedChange(ctx, allocator, file_path, old_content, content);
        var receipt: std.Io.Writer.Allocating = .init(allocator);
        defer receipt.deinit();
        try receipt.writer.writeAll("{\"file_path\":");
        try util_json.writeJsonString(&receipt.writer, file_path);
        try receipt.writer.writeAll(",\"old_string\":");
        try util_json.writeJsonString(&receipt.writer, old_content);
        try receipt.writer.writeAll(",\"new_string\":");
        try util_json.writeJsonString(&receipt.writer, content);
        try receipt.writer.writeAll(",\"success\":true}");
        return receipt.toOwnedSlice();
    };
    defer patch.deinit(allocator);
    const structured = try patch_mod.toStructuredJson(allocator, patch.hunks);
    defer allocator.free(structured);
    const git_diff = try patch_mod.toGitDiff(allocator, file_path, patch.hunks);
    defer allocator.free(git_diff);
    ctx.reportFileChange(.{
        .path = file_path,
        .kind = .modified,
        .status = if (std.mem.eql(u8, old_content, content)) .no_change else .applied,
        .before_bytes = old_content.len,
        .after_bytes = content.len,
        .unified_diff = git_diff,
        .diff_complete = true,
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"file_path\":");
    try util_json.writeJsonString(&out.writer, file_path);
    try out.writer.writeAll(",\"success\":true,\"structuredPatch\":");
    try out.writer.writeAll(structured);
    try out.writer.writeAll(",\"gitDiff\":");
    try util_json.writeJsonString(&out.writer, git_diff);
    // EOF 事实:尾换行数是模型最常算错的字节级事实——old_string 不带原文件尾
    // \n、new_string 又自带 \n 会留下双尾换行,事后 Read 回读时末尾空行还容易
    // 被误判成"恰好一个换行"。直接把终态事实放进结果,不让模型做换行算术。
    var final_newlines: usize = 0;
    while (final_newlines < content.len and content[content.len - 1 - final_newlines] == '\n')
        final_newlines += 1;
    try out.writer.print(",\"final_newlines\":{d}", .{final_newlines});
    // 改后诊断:Y2 砍 tree-sitter 后,原 tree-sitter 语法检查(syntaxWarning)由 LSP 被动诊断取代
    // ——更准(真类型/未声明/语法错)。**取舍登记**:LSP 不在位(`--no-lsp`,或该语言的 server
    // 没装)时编辑不再有免费语法警告(tree-sitter 时代无条件提供);在位则得 server 级诊断,更强。
    // 写后用**新内容**取 delta 诊断(vs 写前 baseline),非空则附进结果给模型。
    try @import("lsp_diag.zig").appendToResult(ctx, allocator, &out.writer, file_path, content);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

/// 写入工具富错误 detail(经 ctx.error_detail 通道传给模型)。无通道则静默。
/// msg 用 ctx.allocator 分配——errorToJson 会拷贝,arena 释放前读取安全。
fn setDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const slot = ctx.error_detail orelse return;
    slot.* = std.fmt.allocPrint(allocator, fmt, args) catch null;
}

/// #2 not-found 诊断:给模型可操作线索而非干巴巴 "not found"。返回静态字符串
/// (setDetail 会拷贝)。诊断顺序:空白差异 → 首行在但块不在 → 通用。
fn notFoundDetail(original: []const u8, old_string: []const u8) []const u8 {
    // ① 空白归一后能匹配 → 多半是缩进/行尾空白差异。
    if (whitespaceInsensitiveContains(original, old_string)) {
        return "old_string not found exactly, but a whitespace-insensitive match exists — the indentation or trailing whitespace differs. Re-Read the file and copy the exact bytes (tabs vs spaces, leading indent).";
    }
    // ② old_string 首个非空行在文件里出现,但整块没匹配 → 周边行/缩进对不上。
    const first = firstNonBlankLine(old_string);
    if (first.len > 0 and std.mem.indexOf(u8, original, first) != null) {
        return "old_string not found as a block, though its first line appears in the file — the following lines or their indentation don't match. Re-Read the surrounding lines and copy them verbatim.";
    }
    // ③ 通用:压根不在。
    return "old_string not found in the file. Re-Read the file to get its exact current content; it may have changed or the text may never have existed.";
}

/// 去掉所有 ASCII 空白(空格/tab/CR/LF)后,original 是否含 old_string。
/// 用于判断"仅空白差异"。线性扫描,O(n·m) 最坏但 old_string 通常短。
fn whitespaceInsensitiveContains(original: []const u8, old_string: []const u8) bool {
    if (old_string.len == 0) return false;
    var oi: usize = 0;
    while (oi < original.len) : (oi += 1) {
        if (matchSkippingWs(original, oi, old_string)) return true;
    }
    return false;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// 从 original[start] 起,跳过两侧空白逐字符匹配 needle。
fn matchSkippingWs(original: []const u8, start: usize, needle: []const u8) bool {
    var hi = start;
    var ni: usize = 0;
    while (ni < needle.len) {
        while (ni < needle.len and isWs(needle[ni])) ni += 1;
        while (hi < original.len and isWs(original[hi])) hi += 1;
        if (ni >= needle.len) return true;
        if (hi >= original.len) return false;
        if (original[hi] != needle[ni]) return false;
        hi += 1;
        ni += 1;
    }
    return true;
}

/// 返回首个非空行(去前后空白)。无则空。
fn firstNonBlankLine(s: []const u8) []const u8 {
    var pos: usize = 0;
    while (pos < s.len) {
        const eol = std.mem.indexOfScalarPos(u8, s, pos, '\n') orelse s.len;
        const line = std.mem.trim(u8, s[pos..eol], " \t\r");
        if (line.len > 0) return line;
        pos = eol + 1;
    }
    return "";
}

/// Edit 文件大小上限（1 GiB）：防止误传巨型文件把内存读爆。
const MAX_EDIT_FILE_SIZE: u64 = 1 << 30;

const Range = struct { start: usize, end: usize };

/// 在 `haystack` 里以"弯/直引号等价"语义搜索 `needle`，返回命中的真实字节范围。
/// 归一化规则：左右弯双引号 “ ” (U+201C/201D) ↔ 直双引号 "；左右弯单引号 ‘ ’ (U+2018/2019) ↔ 直单引号 '。
/// 比较在归一化字符层面进行，但返回的是 haystack 中的原始字节偏移（可直接切片替换）。
fn findSmartQuote(haystack: []const u8, needle: []const u8) ?Range {
    if (needle.len == 0) return null;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (matchAt(haystack, i, needle)) |end| return .{ .start = i, .end = end };
    }
    return null;
}

/// 从 haystack[start] 起尝试匹配 needle（引号归一化）。成功返回 haystack 中的结束偏移。
fn matchAt(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var hi = start;
    var ni: usize = 0;
    while (ni < needle.len) {
        if (hi >= haystack.len) return null;
        const h = nextNormChar(haystack, &hi);
        const n = nextNormChar(needle, &ni);
        if (h != n) return null;
    }
    return hi;
}

/// 读下一个"归一化字符"：弯引号→对应直引号（返回 ASCII），其它字节原样返回。
/// 推进 `idx`（弯引号占 3 字节 UTF-8，前进 3；否则前进 1）。
fn nextNormChar(s: []const u8, idx: *usize) u8 {
    const i = idx.*;
    // U+2018 ‘ = E2 80 98, U+2019 ’ = E2 80 99, U+201C “ = E2 80 9C, U+201D ” = E2 80 9D
    if (i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x80) {
        switch (s[i + 2]) {
            0x98, 0x99 => {
                idx.* = i + 3;
                return '\'';
            },
            0x9C, 0x9D => {
                idx.* = i + 3;
                return '"';
            },
            else => {},
        }
    }
    idx.* = i + 1;
    return s[i];
}

/// 按行扫描；若行首匹配 `^[ ]{0,5}\d+\t` 则去掉该前缀。返回新分配的切片。
/// 行分隔用 '\n'，原样保留。若没有任何行需要剥离，返回原内容的 dupe。
fn stripLineNumberPrefix(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const nl_opt = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl_opt orelse text.len;
        const line = text[line_start..line_end];

        const body_start = detectPrefixLen(line);
        try out.appendSlice(allocator, line[body_start..]);
        if (nl_opt) |i| {
            try out.append(allocator, '\n');
            line_start = i + 1;
        } else {
            break;
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// 返回行首前缀长度（若匹配 `^[ ]{0,5}\d+\t`），否则 0。
fn detectPrefixLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < @min(line.len, 5) and line[i] == ' ') : (i += 1) {}
    const digit_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == digit_start) return 0; // 没数字
    if (i >= line.len or line[i] != '\t') return 0; // 数字后不是 tab
    return i + 1;
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "EditTool missing file_path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingFilePath, execute(&ctx, "{\"old_string\":\"a\",\"new_string\":\"b\"}"));
}

test "EditTool missing old_string" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingOldString, execute(&ctx, "{\"file_path\":\"/tmp/x\",\"new_string\":\"b\"}"));
}

test "EditTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"file_path\":\"../etc/x\",\"old_string\":\"a\",\"new_string\":\"b\"}"));
}

test "EditTool basic replace" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"Hello World\"}}", .{path})));

    var b2: [320]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"World\",\"new_string\":\"Zig\"}}", .{path}));
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect((parsed.value.object.get("success") orelse
        return error.MissingSuccess).bool);
}

test "EditTool replace_all" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-all-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"foo foo foo\"}}", .{path})));

    var b2: [320]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"bar\",\"replace_all\":true}}", .{path}));
    defer std.testing.allocator.free(result);

    const read = @import("read.zig");
    var b3: [320]u8 = undefined;
    const content = try read.execute(&ctx, try std.fmt.bufPrint(&b3, "{{\"path\":\"{s}\"}}", .{path}));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bar bar bar") != null);
}

test "EditTool string not found" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-nf-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"hello\"}}", .{path})));

    var b2: [320]u8 = undefined;
    try std.testing.expectError(error.StringNotFound, execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"missing\",\"new_string\":\"x\"}}", .{path})));
}

test "EditTool MultipleMatches without replace_all" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-multi-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"foo foo foo\"}}", .{path})));

    // 未设 replace_all，foo 多次命中 → MultipleMatches
    var b2: [320]u8 = undefined;
    try std.testing.expectError(error.MultipleMatches, execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"bar\"}}", .{path})));
}

test "EditTool MultipleMatches bypass with replace_all" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-multi-ok-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"foo foo foo\"}}", .{path})));

    // replace_all=true 时多匹配是合法的
    var b2: [320]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"bar\",\"replace_all\":true}}", .{path}));
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "EditTool strips cat-n line numbers from old_string" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-lnstrip-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const write = @import("write.zig");
    var b1: [320]u8 = undefined;
    std.testing.allocator.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"hello\\nworld\"}}", .{path})));

    // 模拟模型从 Read 结果里复制带行号前缀的 old_string:
    //   "     2\\tworld"  —— Edit 应识别并 strip，匹配文件中的 "world"
    var b2: [320]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"     2\\tworld\",\"new_string\":\"     2\\tzig\"}}", .{path}));
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);

    // 读回验证文件现在是 "hello\nzig"（注意 read 会加前缀，检查 content 包含 "zig"）
    const read = @import("read.zig");
    var b3: [320]u8 = undefined;
    const content = try read.execute(&ctx, try std.fmt.bufPrint(&b3, "{{\"path\":\"{s}\"}}", .{path}));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "world") == null);
}

test "stripLineNumberPrefix basic" {
    const a = std.testing.allocator;
    const input = "     1\thello\n     2\tworld\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("hello\nworld\n", stripped);
}

test "stripLineNumberPrefix leaves non-matching lines alone" {
    const a = std.testing.allocator;
    const input = "hello\nworld\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("hello\nworld\n", stripped);
}

test "stripLineNumberPrefix ignores line without tab after digits" {
    const a = std.testing.allocator;
    // "42" 后面跟 space，不是 tab → 不剥离
    const input = "     42 hello\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("     42 hello\n", stripped);
}

test "EditTool not-read-first rejects" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "edit-mrf-test.txt");
    var args_buf: [1024]u8 = undefined;
    defer _ = std.c.unlink(path.ptr);

    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, "hello");
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.NotRead, execute(&ctx, try std.fmt.bufPrint(&args_buf, "{{\"file_path\":\"{s}\",\"old_string\":\"hello\",\"new_string\":\"world\"}}", .{path})));
}

test "EditTool stale rejected" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-stale-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, "hello");
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    try rs.record(path, 1, 5); // 假 mtime

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    var abuf: [320]u8 = undefined;
    try std.testing.expectError(error.StaleFile, execute(&ctx, try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"old_string\":\"hello\",\"new_string\":\"world\"}}", .{path})));
}

test "EditTool after read succeeds" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-after-read-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, "foo");
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    // 先模拟 Read（从文件 stat 出真 mtime 记入）
    const read = @import("read.zig");
    var rb: [320]u8 = undefined;
    const rout = try read.execute(&ctx, try std.fmt.bufPrint(&rb, "{{\"file_path\":\"{s}\"}}", .{path}));
    a.free(rout);

    // 现在 Edit 应成功
    var abuf: [320]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"bar\"}}", .{path}));
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "findSmartQuote matches straight needle against curly haystack" {
    // haystack 含弯双引号 “hi” ；needle 用直引号 "hi"
    const haystack = "say \xE2\x80\x9Chi\xE2\x80\x9D now";
    const r = findSmartQuote(haystack, "\"hi\"").?;
    // “ 起于 index 4，” 占 3 字节，结束于 4 + 3 + 2 + 3 = 12
    try std.testing.expectEqual(@as(usize, 4), r.start);
    try std.testing.expectEqual(@as(usize, 12), r.end);
}

test "findSmartQuote returns null when no match" {
    try std.testing.expect(findSmartQuote("plain text", "\"x\"") == null);
}

test "EditTool old==new 拒绝(NoOpEdit)+ detail" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-noop.txt");
    defer _ = std.c.unlink(path.ptr);
    const write = @import("write.zig");
    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .read_state = &rs, .error_detail = &detail };
    var b1: [320]u8 = undefined;
    a.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"abc\"}}", .{path})));
    // old==new → NoOpEdit,且 detail 被填。
    var b2: [320]u8 = undefined;
    try std.testing.expectError(error.NoOpEdit, execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"abc\",\"new_string\":\"abc\"}}", .{path})));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "no-op") != null);
    if (detail) |d| a.free(d);
}

test "EditTool not-found 诊断:仅空白差异提示" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-wsdiff.txt");
    defer _ = std.c.unlink(path.ptr);
    const write = @import("write.zig");
    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .read_state = &rs, .error_detail = &detail };
    // 文件用 tab 缩进;old_string 用空格缩进 → 仅空白差异。
    var b1: [320]u8 = undefined;
    a.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"\\tfoo()\"}}", .{path})));
    const read = @import("read.zig");
    var b2: [320]u8 = undefined;
    a.free(try read.execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\"}}", .{path})));
    var b3: [320]u8 = undefined;
    try std.testing.expectError(error.StringNotFound, execute(&ctx, try std.fmt.bufPrint(&b3, "{{\"file_path\":\"{s}\",\"old_string\":\"    foo()\",\"new_string\":\"    bar()\"}}", .{path})));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "whitespace") != null);
    if (detail) |d| a.free(d);
}

test "notFoundDetail: 三档诊断" {
    // ① 仅空白差异。
    try std.testing.expect(std.mem.indexOf(u8, notFoundDetail("\tfoo()\n", "    foo()"), "whitespace") != null);
    // ② 首行在但块不在。
    try std.testing.expect(std.mem.indexOf(u8, notFoundDetail("alpha\nXXX\n", "alpha\nbeta"), "first line") != null);
    // ③ 通用。
    try std.testing.expect(std.mem.indexOf(u8, notFoundDetail("nothing here", "zzz"), "not found") != null);
}

test "whitespaceInsensitiveContains" {
    try std.testing.expect(whitespaceInsensitiveContains("\tfoo ( )", "foo()"));
    try std.testing.expect(whitespaceInsensitiveContains("a b c", "abc"));
    try std.testing.expect(!whitespaceInsensitiveContains("abc", "xyz"));
}

test "firstNonBlankLine" {
    try std.testing.expectEqualStrings("hi", firstNonBlankLine("  \n  hi  \nbye"));
    try std.testing.expectEqualStrings("", firstNonBlankLine("   \n\t\n"));
}

test "EditTool smart-quote fallback replaces curly with straight" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "edit-smartquote.txt");
    defer _ = std.c.unlink(path.ptr);
    // 文件含弯引号
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    const content = "const s = \xE2\x80\x9Chello\xE2\x80\x9D;\n";
    _ = pfs.write(fd, content);
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const read = @import("read.zig");
    var rb: [320]u8 = undefined;
    const rout = try read.execute(&ctx, try std.fmt.bufPrint(&rb, "{{\"file_path\":\"{s}\"}}", .{path}));
    a.free(rout);

    // old_string 用直引号；应通过 smart-quote fallback 命中
    var abuf: [384]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"old_string\":\"const s = \\\"hello\\\";\",\"new_string\":\"const s = world;\"}}", .{path}));
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);

    // 验证文件内容已替换
    const vfd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    var rbuf: [128]u8 = undefined;
    const n = pfs.read(vfd, &rbuf);
    _ = pfs.close(vfd);
    try std.testing.expect(std.mem.indexOf(u8, rbuf[0..@intCast(n)], "world") != null);
}

test "Edit result reports final_newlines fact" {
    const a = std.testing.allocator;
    const ctx = ToolContext.simple(a);
    var buf: [512]u8 = undefined;
    const path = tt.path(&buf, "cc-zig-edit-final-newlines.txt");
    defer _ = std.c.unlink(path.ptr);
    const write = @import("write.zig");
    var b1: [640]u8 = undefined;
    a.free(try write.execute(&ctx, try std.fmt.bufPrint(&b1, "{{\"path\":\"{s}\",\"content\":\"gen-old\\n\"}}", .{path})));

    // old_string 不带原尾换行、new_string 自带 \n → 终态双尾换行,工具必须如实上报 2。
    var b2: [640]u8 = undefined;
    const result = try execute(&ctx, try std.fmt.bufPrint(&b2, "{{\"file_path\":\"{s}\",\"old_string\":\"gen-old\",\"new_string\":\"gen-new\\n\"}}", .{path}));
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"final_newlines\":2") != null);
}
