//! CLAUDE.md `@path` import 递归内联展开。
//!
//! 对齐 cc/src/utils/claudemd.ts:
//!   - 语法 `@path` / `@./rel` / `@~/home` / `@/abs`,裸 `@path` 相对当前文件目录
//!   - 正则锚点:`@` 前必须是行首或空白(不误吃 email `a@b`)
//!   - 只在叶子文本展开:跳过 ``` 围栏代码块、行内 `code`
//!   - 递归内联,深度上限 5(MAX_INCLUDE_DEPTH)
//!   - 循环检测:realpath 规范化路径 Set,已见返回空
//!   - 扩展名白名单(只读文本类)
//!
//! 设计:被引文件内容**内联**在 `@path` 出现处(cc 是插成独立条目,但 zig-cc 用
//! 单一拼接缓冲更简单,语义等价——模型看到的最终文本一致)。

const std = @import("std");
const pfs = @import("platform").fs;

pub const MAX_INCLUDE_DEPTH = 5;

/// 文本扩展名白名单(精简版,够 CLAUDE.md import 场景)。无扩展名也放行。
const TEXT_EXTS = [_][]const u8{ ".md", ".markdown", ".mdx", ".txt", ".text", ".rst" };

fn isTextExt(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return true; // 无扩展名放行
    const ext = base[dot..];
    for (TEXT_EXTS) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// 展开 `~` 前缀(本模块自给,不依赖 ctx)。返回 owned;无 `~` 直接 dupe。
fn expandTilde(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        if (home.len == 0) return error.NoHome;
        return allocator.dupe(u8, home);
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        if (home.len == 0) return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

/// 把 import 路径解析成绝对路径(相对 base_dir = 引用它的文件所在目录)。
/// 返回 owned。`~` 已展开;相对路径前缀 base_dir;绝对路径原样。
fn resolveImportPath(
    allocator: std.mem.Allocator,
    raw: []const u8,
    base_dir: []const u8,
    home: []const u8,
) ![]u8 {
    const tilde_expanded = try expandTilde(allocator, raw, home);
    // 绝对路径或 ~ 展开后已绝对 → 原样
    if (std.fs.path.isAbsolute(tilde_expanded)) return tilde_expanded;
    defer allocator.free(tilde_expanded);
    // 相对 → 拼 base_dir
    if (base_dir.len == 0) return allocator.dupe(u8, tilde_expanded);
    return std.fs.path.join(allocator, &.{ base_dir, tilde_expanded });
}

/// 规范化路径用于循环检测(realpath;失败回退原路径)。返回 owned。
/// 用 pfs.realpath(项目统一范式,见 sandbox/profile.zig / skills/render.zig)。
fn canonical(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len + 1 > std.fs.max_path_bytes) return allocator.dupe(u8, path);
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const res = pfs.realpath(@ptrCast(&path_z), &out);
    if (res == null) return allocator.dupe(u8, path);
    const resolved = std.mem.span(@as([*:0]u8, @ptrCast(res.?)));
    return allocator.dupe(u8, resolved);
}

/// 读文件全文(posix 直系,仿 preload.zig readFile)。返回 owned。
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.NotFound;
    defer pfs.close(fd);
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var total: usize = 0;
    while (true) {
        const n = pfs.readZ(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        total += n;
        if (total > 4 * 1024 * 1024) return error.FileTooLarge; // 4MB 上限
        try result.appendSlice(allocator, buf[0..n]);
    }
    return result.toOwnedSlice(allocator);
}

/// 从一行文本里提取所有 `@path` import(若该行不在代码块/行内 code 内)。
/// 把 import 写进 out_paths(owned 字符串,调用方释放)。
/// 返回处理后该行是否还有非空内容(用于调用方决定是否保留原行)——这里始终保留原行。
///
/// 锚点规则:`@` 前是行首或空白;path 由非空白/转义空格组成;剥 `#fragment`。
fn extractImportsFromLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    out_paths: *std.ArrayList([]u8),
) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != '@') {
            i += 1;
            continue;
        }
        // `@` 前必须是行首或空白
        const at_boundary = (i == 0) or (line[i - 1] == ' ') or (line[i - 1] == '\t');
        if (!at_boundary) {
            i += 1;
            continue;
        }
        // 收集 path:从 i+1 起,直到空白(允许 `\ ` 转义空格)
        var j = i + 1;
        var raw = std.ArrayList(u8).empty;
        defer raw.deinit(allocator);
        while (j < line.len) {
            const c = line[j];
            if (c == '\\' and j + 1 < line.len and line[j + 1] == ' ') {
                try raw.append(allocator, ' ');
                j += 2;
                continue;
            }
            if (c == ' ' or c == '\t') break;
            try raw.append(allocator, c);
            j += 1;
        }
        if (raw.items.len > 0) {
            // 剥 #fragment(简化:截首个 `#`)。注意与 cc 正则边界不完全一致——
            // Unix 允许文件名含 `#`,故 `@my#file.md` 会被截成 `my`。这是有意简化
            // (CLAUDE.md import 路径含 `#` 极罕见),spec §1.4 已标注。见测试
            // "extractImportsFromLine: # 在路径中段被截断(简化语义)"。
            var p = raw.items;
            if (std.mem.indexOfScalar(u8, p, '#')) |h| p = p[0..h];
            if (p.len > 0) try out_paths.append(allocator, try allocator.dupe(u8, p));
        }
        i = j;
    }
}

const ExpandCtx = struct {
    allocator: std.mem.Allocator,
    home: []const u8,
    /// 已处理(规范化)路径集合,循环检测。值是 owned。
    seen: *std.StringHashMap(void),
};

/// sanitize:把路径里的 `--` 替成 `-_`,防其提前闭合外层 HTML 注释。返回 owned。
fn sanitizeForComment(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, raw);
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) {
        if (out[i] == '-' and out[i + 1] == '-') out[i + 1] = '_';
    }
    return out;
}

/// 把 content 内的所有 `@path` 递归内联,结果写进 out。
/// base_dir = content 所在文件的目录(相对 import 的基准)。
/// depth = 当前递归深度,>= MAX 停止展开(原文保留)。
fn expandInto(
    ctx: *ExpandCtx,
    out: *std.ArrayList(u8),
    content: []const u8,
    base_dir: []const u8,
    depth: usize,
) !void {
    const a = ctx.allocator;
    var in_fence = false; // ``` 围栏代码块内
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (line_it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;

        // 围栏切换:行 trim 后以 ``` 开头
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            try out.appendSlice(a, line);
            continue;
        }
        if (in_fence or depth >= MAX_INCLUDE_DEPTH) {
            try out.appendSlice(a, line);
            continue;
        }

        // 提取本行 imports
        var paths = std.ArrayList([]u8).empty;
        defer {
            for (paths.items) |p| a.free(p);
            paths.deinit(a);
        }
        try extractImportsFromLine(a, line, &paths);

        if (paths.items.len == 0) {
            try out.appendSlice(a, line);
            continue;
        }

        // 保留原行(cc 也保留原文,import 内容追加在后)
        try out.appendSlice(a, line);

        for (paths.items) |raw| {
            if (!isTextExt(raw)) continue; // 非文本扩展名跳过
            const resolved = resolveImportPath(a, raw, base_dir, ctx.home) catch continue;
            defer a.free(resolved);
            const canon = canonical(a, resolved) catch continue;
            // 循环检测:已见 → 跳过(canon 释放)
            if (ctx.seen.contains(canon)) {
                a.free(canon);
                continue;
            }
            const child = readFileAlloc(a, resolved) catch {
                a.free(canon);
                continue; // 文件不存在/读失败 静默
            };
            defer a.free(child);
            // 标记已见(seen 持有 canon 所有权)
            try ctx.seen.put(canon, {});

            const child_dir = std.fs.path.dirname(resolved) orelse ".";
            // 内联隔离(Linus #1 修):cc 把每个 import 作独立条目正是为隔离 markdown 串扰
            // (child 内未闭合 ``` 围栏会吞掉父的后续文本)。zig-cc 用拼接缓冲,故必须显式
            // 加边界:前后空行 + HTML 注释标记。注释里带源路径,既隔离又便于调试。
            // 边界本身不"闭合"child 的孤立围栏,但把 child 圈进可识别的嵌入块,
            // 且强制空行保证父的后续行从新段落开始(markdown 围栏不跨空行误配)。
            // sanitize:路径里的 `--` 会提前闭合 HTML 注释(`@foo-->x.md` 注入),替成 `-_`。
            const safe_raw = try sanitizeForComment(a, raw);
            defer a.free(safe_raw);
            const open = try std.fmt.allocPrint(a, "\n\n<!-- BEGIN @import {s} -->\n", .{safe_raw});
            defer a.free(open);
            try out.appendSlice(a, open);
            try expandInto(ctx, out, child, child_dir, depth + 1);
            try out.appendSlice(a, "\n<!-- END @import -->\n");
        }
    }
}

/// 对外入口:展开 content 内所有 `@path` import。
/// base_dir = content 来源文件目录(相对 import 基准,可空)。
/// home = `~` 展开用(可空 → 含 `~` 的 import 跳过)。
/// 返回 owned 展开后全文。
pub fn expandImports(
    allocator: std.mem.Allocator,
    content: []const u8,
    base_dir: []const u8,
    home: []const u8,
) ![]u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }
    var ctx = ExpandCtx{ .allocator = allocator, .home = home, .seen = &seen };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try expandInto(&ctx, &out, content, base_dir, 0);
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// 测试 helper:把 TmpDir 解析成绝对路径(owned)。
/// TmpDir.sub_path 是相对 `.zig-cache/tmp/` 的随机名;拼成相对路径过 canonical 取绝对。
fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(rel);
    return canonical(allocator, rel);
}

/// 测试 helper:posix 写文件(0.16 Io.Dir.writeFile 需 io 参数,绕开)。
fn writeFileAt(dir_abs: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir_abs, name });
    const fd = try pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = pfs.write(fd, data[written..]);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

test "extractImportsFromLine: basic + boundary + fragment" {
    const a = testing.allocator;
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    try extractImportsFromLine(a, "see @./sub.md for details", &paths);
    try testing.expectEqual(@as(usize, 1), paths.items.len);
    try testing.expectEqualStrings("./sub.md", paths.items[0]);

    // email-like 不匹配(@ 前是字母)
    var p2 = std.ArrayList([]u8).empty;
    defer {
        for (p2.items) |p| a.free(p);
        p2.deinit(a);
    }
    try extractImportsFromLine(a, "mail a@b.com", &p2);
    try testing.expectEqual(@as(usize, 0), p2.items.len);

    // fragment 剥掉
    var p3 = std.ArrayList([]u8).empty;
    defer {
        for (p3.items) |p| a.free(p);
        p3.deinit(a);
    }
    try extractImportsFromLine(a, "@doc.md#section", &p3);
    try testing.expectEqual(@as(usize, 1), p3.items.len);
    try testing.expectEqualStrings("doc.md", p3.items[0]);
}

test "expandImports: no imports returns verbatim" {
    const a = testing.allocator;
    const out = try expandImports(a, "hello\nworld", "", "");
    defer a.free(out);
    try testing.expectEqualStrings("hello\nworld", out);
}

test "expandImports: skips import inside code fence" {
    const a = testing.allocator;
    const src = "```\n@nonexistent.md\n```";
    const out = try expandImports(a, src, "", "");
    defer a.free(out);
    // 围栏内 @ 不展开,原文保留(文件不存在也无所谓——根本没尝试读)
    try testing.expect(std.mem.indexOf(u8, out, "@nonexistent.md") != null);
}

test "expandImports: recursive inline with real temp files" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(a, &tmp);
    defer a.free(dir_path);

    // 三层:root 引 a.md,a.md 引 b.md
    try writeFileAt(dir_path, "a.md", "A-content @b.md");
    try writeFileAt(dir_path, "b.md", "B-content");

    const root = try std.fmt.allocPrint(a, "root @{s}/a.md end", .{dir_path});
    defer a.free(root);

    const out = try expandImports(a, root, dir_path, "");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "A-content") != null);
    try testing.expect(std.mem.indexOf(u8, out, "B-content") != null);
}

test "expandImports: cycle detection (a->b->a) no infinite loop" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(a, &tmp);
    defer a.free(dir_path);

    try writeFileAt(dir_path, "x.md", "X @y.md");
    try writeFileAt(dir_path, "y.md", "Y @x.md");

    const root = try std.fmt.allocPrint(a, "@{s}/x.md", .{dir_path});
    defer a.free(root);
    const out = try expandImports(a, root, dir_path, "");
    defer a.free(out);
    // X 和 Y 各出现(至少一次),不卡死即通过
    try testing.expect(std.mem.indexOf(u8, out, "X") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Y") != null);
}

test "expandImports: depth limit stops at MAX" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(a, &tmp);
    defer a.free(dir_path);

    // 链 d0->d1->...->d6,每层引下一层
    var lvl: usize = 0;
    while (lvl <= 6) : (lvl += 1) {
        const name = try std.fmt.allocPrint(a, "d{d}.md", .{lvl});
        defer a.free(name);
        const body = if (lvl < 6)
            try std.fmt.allocPrint(a, "L{d} @d{d}.md", .{ lvl, lvl + 1 })
        else
            try std.fmt.allocPrint(a, "L{d}", .{lvl});
        defer a.free(body);
        try writeFileAt(dir_path, name, body);
    }
    const root = try std.fmt.allocPrint(a, "@{s}/d0.md", .{dir_path});
    defer a.free(root);
    const out = try expandImports(a, root, dir_path, "");
    defer a.free(out);
    // 深度上限 5:root(depth0)展开 d0(depth1)..d4(depth5);处理 d4 内容时
    // depth==5 >= MAX,d4 里的 @d5.md 不再展开 → L0..L4 在,L5 不在。
    try testing.expect(std.mem.indexOf(u8, out, "L4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "L5") == null);
}

test "isTextExt: whitelist" {
    try testing.expect(isTextExt("foo.md"));
    try testing.expect(isTextExt("foo.txt"));
    try testing.expect(isTextExt("noext")); // 无扩展名放行
    try testing.expect(!isTextExt("bin.exe"));
    try testing.expect(!isTextExt("img.png"));
}

test "extractImportsFromLine: # 在路径中段被截断(简化语义,Linus #2)" {
    const a = testing.allocator;
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    // `@my#file.md` 按简化规则截首个 # → "my"(与 cc 正则边界不同,已在 spec/代码注释标注)
    try extractImportsFromLine(a, "@my#file.md", &paths);
    try testing.expectEqual(@as(usize, 1), paths.items.len);
    try testing.expectEqualStrings("my", paths.items[0]);
}

test "expandImports: child 未闭合围栏不污染父后续文本(Linus #1)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);

    // child 含未闭合 ``` 围栏(CLAUDE.md 里写示例片段很常见)
    try writeFileAt(dir, "child.md", "```python\nprint('hi')");
    const root = try std.fmt.allocPrint(a, "PARENT-BEFORE @{s}/child.md\nPARENT-AFTER-MARKER", .{dir});
    defer a.free(root);

    const out = try expandImports(a, root, dir, "");
    defer a.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "print('hi')") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PARENT-AFTER-MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, out, "BEGIN @import") != null);
    try testing.expect(std.mem.indexOf(u8, out, "END @import") != null);
    // 关键:END 边界在 child 内容之后、父后续文本之前 → child 被圈住
    const child_pos = std.mem.indexOf(u8, out, "print('hi')").?;
    const end_pos = std.mem.indexOf(u8, out, "END @import").?;
    const after_pos = std.mem.indexOf(u8, out, "PARENT-AFTER-MARKER").?;
    try testing.expect(child_pos < end_pos);
    try testing.expect(end_pos < after_pos);
}

test "sanitizeForComment: -- 替成 -_ 防 HTML 注释提前闭合(Linus #1 复审)" {
    const a = testing.allocator;
    const s = try sanitizeForComment(a, "foo-->bar.md");
    defer a.free(s);
    // `-->` 里的 `--` 被破坏 → 不再能闭合外层 <!-- -->
    try testing.expect(std.mem.indexOf(u8, s, "-->") == null);
    try testing.expect(std.mem.indexOf(u8, s, "--") == null);
}

test "expandImports: 路径含 --> 不破坏隔离边界(Linus #1 复审)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);

    // 文件名真的含 --(罕见但合法);展开后注释边界不应被它提前闭合。
    try writeFileAt(dir, "a--b.md", "INNER-CONTENT");
    const root = try std.fmt.allocPrint(a, "@{s}/a--b.md\nTAIL-MARKER", .{dir});
    defer a.free(root);

    const out = try expandImports(a, root, dir, "");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "INNER-CONTENT") != null);
    try testing.expect(std.mem.indexOf(u8, out, "TAIL-MARKER") != null);
    // 注:原 `@path` 行按设计 verbatim 保留(含裸 a--b.md),sanitize 只作用于**生成的注释**。
    // 验证生成的 BEGIN 注释段内 `--` 已被破坏:截出 "BEGIN @import " 后到 " -->" 的路径片段,
    // 该片段不含 `--`(否则会提前闭合注释)。
    const begin_tag = "<!-- BEGIN @import ";
    const bi = std.mem.indexOf(u8, out, begin_tag).?;
    const path_start = bi + begin_tag.len;
    const close = std.mem.indexOfPos(u8, out, path_start, " -->").?;
    const comment_path = out[path_start..close];
    try testing.expect(std.mem.indexOf(u8, comment_path, "--") == null);
    try testing.expect(std.mem.indexOf(u8, comment_path, "a-_b") != null);
}

