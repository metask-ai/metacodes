const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const util_fs = @import("../util/fs.zig");
const util_json = @import("../util/json.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;
const observation = @import("observation.zig");
const tt = @import("test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // 接受 `file_path`(Claude Code / 真 API 标准字段,也是本项目 descriptions.zig 宣称的)
    // 与历史 `path` 两种字段名(向后兼容)。
    const path_escaped = common.extractJsonArg(args, "file_path") orelse
        common.extractJsonArg(args, "path") orelse return error.MissingPath;
    const content_escaped = common.extractJsonArg(args, "content") orelse return error.MissingContent;
    // unescape:content 里的 `\n`/`\t`/`\"`/`\uXXXX` 要还原成真实字节再落盘
    // (否则模型写的多行文件会变成一行字面 `\n`)。path 一般无转义但 unescape 也安全。
    // path 必须**先 unescape 再归一化**:模型可能写 `"~/foo"`,要先还原成 `~/foo` 再展开 ~。
    const path_unesc = try util_json.unescapeString(path_escaped, allocator);
    defer allocator.free(path_unesc);
    const content = try util_json.unescapeString(content_escaped, allocator);
    defer allocator.free(content);
    if (path_unesc.len == 0) return error.EmptyPath;
    // 归一化(展开 ~、折叠、查 traversal)。openat 不认 ~。
    const path = try path_mod.normalizeChecked(allocator, path_unesc, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);

    // must-read-first 校验：若挂了 ReadState（正式 agent 路径），文件存在但没读过 → 拒绝
    // 两个例外：1) 文件不存在（即将创建）；2) ReadState 未挂（单测/dev 路径）
    if (ctx.read_state) |rs| {
        const exists = read_state.statPath(path) catch |err| switch (err) {
            error.StatFailed => null, // 文件不存在，允许创建
            else => return err,
        };
        if (exists) |st| {
            const rec = rs.get(path) orelse return error.NotRead;
            // staleness 双判:mtime 变了,但内容哈希没变(且记过哈希)→ 不算 stale(对齐 cc)。
            if (rec.mtime_ns != st.mtime_ns) {
                const cur_hash = read_state.hashFileContent(path);
                if (rec.content_hash == 0 or cur_hash != rec.content_hash) return error.StaleFile;
            }
        }
    }

    // 写前抓旧内容（同时用于 structuredPatch / gitDiff 与 typed observation）。
    // 只有明确的 ENOENT 才能声称 missing；权限、类型、过大或读取失败都是
    // unknown，不能为了生成一条好看的 effect 而伪造旧状态。
    const before = captureBeforeContent(allocator, path);
    defer switch (before) {
        .known => |bytes| allocator.free(bytes),
        else => {},
    };
    const old_content: ?[]const u8 = switch (before) {
        .known => |bytes| bytes,
        else => null,
    };

    // 自动建父目录（对齐 TS：Write 到不存在的目录会先 mkdir -p）。
    try util_fs.mkdirParentsOf(path);

    const write_flags: pfs.O = if (ctx.project_write_exclusive_create)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .EXCL = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = pfs.openZ(path, write_flags, 0o666) catch {
        // EACCES/EROFS 与其他 open 失败对模型是不同的可行动作:权限失败应换目标
        // 路径或报告权限问题,而不是盲目重试。带 errno 的富 detail 走 error_detail
        // 通道(与 edit.zig setDetail 同款),无通道时退回裸 WriteError。
        // errno 先读再分配(allocPrint 可能改它);按名查表,没命名的值不裸转枚举(#121)。
        const errno_raw = pfs.lastErrno();
        const errno_tag = pfs.errnoTag(errno_raw);
        if (ctx.error_detail) |slot| {
            slot.* = if (errno_tag) |tag| switch (tag) {
                .ACCES, .ROFS => std.fmt.allocPrint(
                    ctx.allocator,
                    "permission denied writing '{s}' (errno {d}): the target directory is not writable by the current user. Write to a writable location instead or report the permission problem.",
                    .{ path, errno_raw },
                ) catch null,
                .NOENT, .NOTDIR => std.fmt.allocPrint(
                    ctx.allocator,
                    "cannot create '{s}' (errno {d}): a path component is missing or not a directory.",
                    .{ path, errno_raw },
                ) catch null,
                else => null,
            } else null;
        }
        return error.WriteError;
    };
    defer _ = pfs.close(fd);

    var pos: usize = 0;
    while (pos < content.len) {
        const remaining = content.len - pos;
        const n = pfs.write(fd, content[pos..][0..remaining]);
        if (n <= 0) return error.WriteError;
        pos += @as(usize, @intCast(n));
    }

    ctx.reportFileMutation(path, before, content);

    // 写完后刷新 ReadState 的 mtime + content_hash，让紧接着的 Edit/Write 不误报 stale。
    if (ctx.read_state) |rs| {
        const st = read_state.statFd(fd) catch null;
        if (st) |s| rs.recordHashed(path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, content)) catch {};
    }

    // 旁路缓存新旧全文(供 diff 工具卡 hl-zig 高亮;不进对话历史)。新建文件 old="".
    if (ctx.edit_hl_cache) |cache| {
        cache.put(ctx.progress_tool_id, old_content orelse "", content);
    }

    // B/C 合并:memdir 记忆 markdown 自动入图(best-effort,失败仅 log 不影响写结果)。
    @import("../kg/autosync.zig").maybeImportMemoryFile(ctx, path, content);

    // M2:LSP baseline 移到盘写后(新建文件 old="")——盘写不被 LSP 阻塞,只结果等诊断。
    @import("lsp_diag.zig").snapshotBaseline(ctx, path, old_content orelse "");

    return try renderResult(ctx, allocator, path, old_content orelse "", content, before);
}

/// 旧文件读的 size 守卫(轴A):旧内容仅供 diff 展示,巨型文件的 diff 无意义且整读 OOM →
/// 超此值 readAllFromFdCapped 返 error → caller catch null → 无 diff,Write 仍正常写。10MB 对齐 Read 快路径门槛。
const MAX_WRITE_OLD_SIZE: usize = 10 * 1024 * 1024;

/// Capture the exact bytes observed immediately before Write opens the target
/// with TRUNC. This is evidence of the tool's observation, not a claim that the
/// path stayed unchanged across the unavoidable open/read/write interval.
fn captureBeforeContent(allocator: std.mem.Allocator, path: []const u8) observation.BeforeContent {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch {
        // openZ 在没调 CRT 就拒绝(路径过长)时也写了 errno,所以这里读到的总是本次 open 的原因;
        // 整数比较,不裸转枚举(#121)。
        return if (pfs.lastErrnoIs(.NOENT)) .missing else .unknown;
    };
    defer _ = pfs.close(fd);
    const bytes = common.readAllFromFdCapped(fd, allocator, MAX_WRITE_OLD_SIZE) catch return .unknown;
    return .{ .known = bytes };
}

/// 渲染 Write 成功结果：success + path + structuredPatch + gitDiff (+ lspDiagnostics)。
/// 同时把这次写入投到**稳定的文件修改契约**(core/file_change.zig)——上层拿实际改动不再靠
/// 解析下面这个结果 JSON 里的 `gitDiff`(那是工具私有渲染字段)。
fn renderResult(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    path: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    before: observation.BeforeContent,
) ![]u8 {
    const patch_mod = @import("../core/patch.zig");
    var patch = patch_mod.compute(allocator, old_content, new_content) catch {
        // diff 失败不致命：退回最简结果。改动是真的,只是拿不到 diff → 契约上标注证据不完整。
        publishFileChange(ctx, path, before, old_content, new_content, null, false);
        var receipt: std.Io.Writer.Allocating = .init(allocator);
        defer receipt.deinit();
        try receipt.writer.writeAll("{\"success\":true,\"path\":");
        try util_json.writeJsonString(&receipt.writer, path);
        try receipt.writer.writeByte('}');
        return receipt.toOwnedSlice();
    };
    defer patch.deinit(allocator);

    const structured = try patch_mod.toStructuredJson(allocator, patch.hunks);
    defer allocator.free(structured);
    const git_diff = try patch_mod.toGitDiff(allocator, path, patch.hunks);
    defer allocator.free(git_diff);
    publishFileChange(ctx, path, before, old_content, new_content, git_diff, true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"success\":true,\"path\":");
    try util_json.writeJsonString(&out.writer, path);
    try out.writer.writeAll(",\"structuredPatch\":");
    try out.writer.writeAll(structured);
    try out.writer.writeAll(",\"gitDiff\":");
    try util_json.writeJsonString(&out.writer, git_diff);
    // LSP 被动诊断:写后 delta 诊断附进结果(新建文件的诊断也报)。
    try @import("lsp_diag.zig").appendToResult(ctx, allocator, &out.writer, path, new_content);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

/// 投递一条文件修改记录。`before` 决定是新建还是修改:只有明确观察到 ENOENT 才敢说 created;
/// 读不到旧内容(权限/过大/失败)时按 modified 报——不为了好看的分类而编造事实。
fn publishFileChange(
    ctx: *const ToolContext,
    path: []const u8,
    before: observation.BeforeContent,
    old_content: []const u8,
    new_content: []const u8,
    unified_diff: ?[]const u8,
    diff_complete: bool,
) void {
    const created = before == .missing;
    const known_before = before == .known;
    // `.unknown` = 文件在那儿但旧内容读不到(权限/超过 10MB 展示上限/读失败)。此时 diff 是拿
    // **空基线**算的(整篇都显示成新增),before_bytes 也只能报 0——那是"不知道",不是"本来是空的"。
    // 标 incomplete,让消费者知道 before 一侧不可信,而不是拿一份看起来完整的假 diff 去展示。
    const baseline_known = created or known_before;
    ctx.reportFileChange(.{
        .path = path,
        .kind = if (created) .created else .modified,
        .status = if (known_before and std.mem.eql(u8, old_content, new_content))
            .no_change
        else
            .applied,
        .before_bytes = if (created) 0 else old_content.len,
        .after_bytes = new_content.len,
        .unified_diff = unified_diff,
        .diff_complete = diff_complete and baseline_known,
    });
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "WriteTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"test\"}"));
}

test "WriteTool missing content" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingContent, execute(&ctx, "{\"path\":\"/tmp/x\"}"));
}

test "WriteTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"path\":\"../etc/x\",\"content\":\"y\"}"));
}

test "WriteTool create file" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "write-test.txt");
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"hello\"}}", .{path});
    const result = try execute(&ctx, args);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    _ = std.c.unlink(path.ptr);
}

test "WriteTool auto-mkdir creates missing parent directory" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "mkdir-parent-9a8b/sub/foo.txt");
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
    const result = try execute(&ctx, args);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    // cleanup
    _ = std.c.unlink(path.ptr);
    var sbuf: [256]u8 = undefined;
    _ = std.c.rmdir((tt.path(&sbuf, "mkdir-parent-9a8b/sub")).ptr);
    var dbuf: [256]u8 = undefined;
    _ = std.c.rmdir((tt.path(&dbuf, "mkdir-parent-9a8b")).ptr);
}

test "WriteTool EACCES detail names the unwritable directory (errno through error_detail)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root ignores mode bits
    const a = std.testing.allocator;
    var rs = read_state.ReadState.init(a);
    defer rs.deinit();
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .read_state = &rs, .error_detail = &detail };
    var dbuf: [256]u8 = undefined;
    const dir = tt.path(&dbuf, "ro-dir-4c1e");
    try std.testing.expect(pfs.mkdir(dir.ptr, 0o500) == 0);
    defer {
        _ = std.c.chmod(dir.ptr, 0o700);
        _ = std.c.rmdir(dir.ptr);
    }
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "ro-dir-4c1e/x.txt");
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
    try std.testing.expectError(error.WriteError, execute(&ctx, args));
    try std.testing.expect(detail != null);
    defer if (detail) |d| a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "permission denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, path) != null);
}

test "WriteTool ENOTDIR detail: a file as a path component" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var rs = read_state.ReadState.init(a);
    defer rs.deinit();
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .read_state = &rs, .error_detail = &detail };
    var fbuf: [256]u8 = undefined;
    const file = tt.path(&fbuf, "notdir-7b2d");
    {
        const fd = try pfs.openZ(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(file.ptr);
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "notdir-7b2d/child.txt");
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
    try std.testing.expectError(error.WriteError, execute(&ctx, args));
    try std.testing.expect(detail != null);
    defer if (detail) |d| a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "not a directory") != null);
}

test "WriteTool not-read-first rejects existing file" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "write-mrf-test.txt");
    defer _ = std.c.unlink(path.ptr);
    // 先存在一个文件（外部创建）
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, "old");
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"new\"}}", .{path});
    try std.testing.expectError(error.NotRead, execute(&ctx, args));
}

test "WriteTool creating new file does not require read" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "write-new-test.txt");
    _ = std.c.unlink(path.ptr); // 确保不存在
    defer _ = std.c.unlink(path.ptr);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"hello\"}}", .{path});
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "WriteTool stale file rejected" {
    const a = std.testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "write-stale-test.txt");
    defer _ = std.c.unlink(path.ptr);

    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, "v1");
    _ = pfs.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    // 手工记录一个假 mtime，模拟"读完后外部改了"
    try rs.record(path, 1, 2);

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\",\"content\":\"v2\"}}", .{path});
    try std.testing.expectError(error.StaleFile, execute(&ctx, args));
}

test "WriteTool null byte 路径拒绝(防 C 字符串截断)" {
    // write 路径经 unescapeString → JSON  还原成真 \0 → 归一化层 EmbeddedNullByte 拦截。
    // 防止 "/etc/passwd\0.txt" 被 openat 当成 "/etc/passwd" 静默写错文件。
    const ctx = testCtx();
    try std.testing.expectError(error.EmbeddedNullByte, execute(&ctx, "{\"file_path\":\"/tmp/x\\u0000evil\",\"content\":\"y\"}"));
}

test "WriteTool ~ 展开端到端" {
    // ~/file 应展开到 home 并写入。home 指向 test_tmp 的 per-pid 目录(已存在)。
    const a = std.testing.allocator;
    var seed: [256]u8 = undefined;
    _ = tt.path(&seed, "seed"); // 触发 test_tmp 建 /tmp/cc-zig-test-<pid> 目录
    var hbuf: [512]u8 = undefined;
    const home = tt.dir(&hbuf);
    var ctx = testCtx();
    ctx.home_dir = home;
    const r = try execute(&ctx, "{\"file_path\":\"~/tilde-write-test.txt\",\"content\":\"hello-tilde\"}");
    defer a.free(r);
    // 读回验证落盘到展开后的真实路径
    var pbuf: [256]u8 = undefined;
    const real = std.fmt.bufPrintZ(&pbuf, "{s}/tilde-write-test.txt", .{home}) catch unreachable;
    defer _ = std.c.unlink(real.ptr);
    const fd = pfs.open(real.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd >= 0); // 文件存在 = ~ 已展开
    _ = pfs.close(fd);
}

// ── #121:UTF-8 路径必须落到精确的名字 ─────────────────────────────────────────
// Windows 窄字符 CRT(`_open`/`_mkdir`)会把 UTF-8 字节按 ANSI 代码页解码,`测试.txt` 落成乱码名;
// 存在性检查(宽字符 statPath)与实际写入看的是两个对象,must-read-first 因此失守。以下用例
// 全平台跑:POSIX 上 UTF-8 是原生编码,充当回归基线;Windows 原生 CI 是真正的证据。验证一律走
// std.Io(Windows 走 NT 宽字符 API)与 platform/dir 枚举,不用 pfs 自读自证。

/// 目录里除 `.`/`..` 外的条目数,并断言每个条目都叫 `expected_name`。
fn countEntriesNamed(dir_z: [*:0]const u8, expected_name: []const u8) !usize {
    var it = pdir.open(dir_z) orelse return error.TestUnexpectedResult;
    defer pdir.close(&it);
    var entries: usize = 0;
    while (pdir.next(&it)) |ent| {
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        try std.testing.expectEqualStrings(expected_name, ent.name);
        entries += 1;
    }
    return entries;
}

test "WriteTool: a CJK path with CJK parent directories is created at exactly the requested names" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tt.normalizeSlashes(root_buf[0..try tmp.dir.realPath(io, &root_buf)]);
    var rs = read_state.ReadState.init(a);
    defer rs.deinit();
    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const args = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/测试目录/子目录/测试.txt\",\"content\":\"你好\\n\"}}", .{root});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);

    // 独立读回:内容落在精确名下。
    const bytes = try tmp.dir.readFileAlloc(io, "测试目录/子目录/测试.txt", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("你好\n", bytes);
    // 三层各只有一个精确名的条目,没有乱码兄弟(父目录是 Write 自动建的)。
    const root_z = try a.dupeZ(u8, root);
    defer a.free(root_z);
    const l1 = try std.fmt.allocPrintSentinel(a, "{s}/测试目录", .{root}, 0);
    defer a.free(l1);
    const l2 = try std.fmt.allocPrintSentinel(a, "{s}/测试目录/子目录", .{root}, 0);
    defer a.free(l2);
    try std.testing.expectEqual(@as(usize, 1), try countEntriesNamed(root_z.ptr, "测试目录"));
    try std.testing.expectEqual(@as(usize, 1), try countEntriesNamed(l1.ptr, "子目录"));
    try std.testing.expectEqual(@as(usize, 1), try countEntriesNamed(l2.ptr, "测试.txt"));

    // 同一个对象:刚写过的文件已记进 ReadState,紧接着的第二次 Write 走 stale/must-read 校验而不是
    // "文件不存在 → 允许创建"——这证明 statPath(宽字符)与 open 看到的是同一个文件。
    const again = try execute(&ctx, args);
    defer a.free(again);
    try std.testing.expect(std.mem.indexOf(u8, again, "\"success\":true") != null);
}

test "WriteTool: must-read-first still rejects an existing CJK-path file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "测试.txt", .data = "old" }); // 外部(std.Io)创建,从未 Read
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tt.normalizeSlashes(root_buf[0..try tmp.dir.realPath(io, &root_buf)]);
    var rs = read_state.ReadState.init(a);
    defer rs.deinit();
    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const args = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/测试.txt\",\"content\":\"new\"}}", .{root});
    defer a.free(args);
    try std.testing.expectError(error.NotRead, execute(&ctx, args));
    const kept = try tmp.dir.readFileAlloc(io, "测试.txt", a, .limited(16));
    defer a.free(kept);
    try std.testing.expectEqualStrings("old", kept);
}

test "WriteTool (Windows): the ANSI-decoded counterpart of a CJK path is never touched" {
    // 复现 #121 的覆盖场景:请求的 `测试.txt` 不存在,而它按进程 ANSI 代码页误解码出来的名字
    // (窄字符 CRT 实际会打开的那个)存在且可写。Write 必须新建请求的文件,旧文件一字不动。
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tt.normalizeSlashes(root_buf[0..try tmp.dir.realPath(io, &root_buf)]);

    const intended = "测试.txt";
    var wide: [64]u16 = undefined;
    const wlen = MultiByteToWideChar(0, 0, intended.ptr, @intCast(intended.len), &wide, wide.len); // CP_ACP
    if (wlen <= 0) return error.TestUnexpectedResult;
    var mojibake_buf: [256]u8 = undefined;
    const mojibake = mojibake_buf[0..try std.unicode.utf16LeToUtf8(&mojibake_buf, wide[0..@intCast(wlen)])];
    if (std.mem.eql(u8, mojibake, intended)) return error.SkipZigTest; // 进程代码页已是 UTF-8:没有乱码对偶可测
    try tmp.dir.writeFile(io, .{ .sub_path = mojibake, .data = "keep" });

    var rs = read_state.ReadState.init(a);
    defer rs.deinit();
    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const args = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/{s}\",\"content\":\"new\"}}", .{ root, intended });
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);

    const kept = try tmp.dir.readFileAlloc(io, mojibake, a, .limited(16));
    defer a.free(kept);
    try std.testing.expectEqualStrings("keep", kept);
    const written = try tmp.dir.readFileAlloc(io, intended, a, .limited(16));
    defer a.free(written);
    try std.testing.expectEqualStrings("new", written);
}
extern "kernel32" fn MultiByteToWideChar(CodePage: u32, dwFlags: u32, lpMultiByteStr: [*]const u8, cbMultiByte: c_int, lpWideCharStr: ?[*]u16, cchWideChar: c_int) callconv(.winapi) c_int;
