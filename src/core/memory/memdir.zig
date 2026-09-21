//! 通道 B:自动记忆 memdir。
//!
//! 对齐 cc/src/memdir/*。模型用 Write/Read/Grep **自己管理**一个记忆目录(无专用 Memory 工具,
//! 对齐 cc)。本模块只提供:
//!   1. 路径解析:memdir = `{home}/.metacodes/projects/<cwd_hash>/memory/`
//!      (复用 transcript.hashCwd —— 与现有 transcript 布局并列;cc 用 sanitized-git-root,
//!       zig-cc 沿用项目既有 cwd_hash 标准,见 spec §2.1 divergence)
//!   2. MEMORY.md 索引:读取 + 截断(≤200 行 / ≤25KB,对齐 cc MAX_ENTRYPOINT_*)
//!   3. isAutoMemPath:某写入目标是否落在 memdir 子树内(权限豁免用,realpath 前缀匹配防穿越)
//!   4. enable 开关
//!
//! 安全(Linus 盯):isAutoMemPath 必须用 realpath 归一化 + 严格前缀(带分隔符边界),
//! 否则 `~/.metacodes/projects/<hash>/memory-evil` 或 `..` 穿越能骗过前缀匹配 → 任意写洞。

const std = @import("std");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;
const builtin = @import("builtin");
const transcript = @import("../transcript.zig");

/// MEMORY.md 索引上限(对齐 cc MAX_ENTRYPOINT_LINES / MAX_ENTRYPOINT_BYTES)。
pub const MAX_ENTRYPOINT_LINES = 200;
pub const MAX_ENTRYPOINT_BYTES = 25_000;

/// memdir 启用?默认 ON。关:CLAUDE_CODE_DISABLE_AUTO_MEMORY(存在且非 "0"/空)。
/// (--bare / CLAUDE_CODE_SIMPLE 等更高层开关由调用方在更上层处理。)
pub fn isEnabled() bool {
    if (std.c.getenv("CLAUDE_CODE_DISABLE_AUTO_MEMORY")) |v| {
        const s = std.mem.span(v);
        return std.mem.eql(u8, s, "0") or s.len == 0;
    }
    return true;
}

/// memdir 目录全路径:`{home}/.metacodes/projects/<cwd_hash>/memory`。写进 buf,返回 slice。
/// home/cwd 任一为空 → 返回空串(memdir 不可用)。
pub fn memdirPath(home: []const u8, cwd: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or cwd.len == 0) return "";
    const cwd_hash = transcript.hashCwd(cwd);
    return std.fmt.bufPrint(buf, "{s}/.metacodes/projects/{s}/memory", .{ home, cwd_hash[0..] }) catch "";
}

/// MEMORY.md 索引文件全路径:`{memdir}/MEMORY.md`。写进 buf,返回 slice。
pub fn memoryIndexPath(home: []const u8, cwd: []const u8, buf: []u8) []const u8 {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = memdirPath(home, cwd, &dbuf);
    if (dir.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/MEMORY.md", .{dir}) catch "";
}

/// 确保 memdir 存在(mkdir -p)。失败返回 error,调用方决定是否致命(通常降级:不注入)。
pub fn ensureDir(home: []const u8, cwd: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = memdirPath(home, cwd, &buf);
    if (dir.len == 0) return error.NoMemdir;
    try @import("../../util/fs.zig").mkdirParents(dir);
}

/// realpath 归一化(失败回退原路径)。返回 owned。
fn canonical(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len + 1 > std.fs.max_path_bytes) return allocator.dupe(u8, path);
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const res = pfs.realpath(@ptrCast(&path_z), &out);
    if (res == null) return allocator.dupe(u8, path);
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(res.?))));
}

/// candidate(模型要写的目标)是否落在 memdir 子树内 → 权限豁免该写。
/// 安全:严格前缀匹配 + **分隔符边界**(`{memdir}/` 才算内部,`{memdir}-evil` 不算)。
/// candidate 不存在时(新建文件)realpath 会失败 → 退化成对其**父目录** realpath 后拼回文件名,
/// 防"目标尚不存在"导致豁免被绕过/误拒。
///
/// memdir_abs:App 算好的 memdir 绝对路径(已 realpath 或来自可信拼接)。
/// candidate:工具 args 里的 file_path(可能相对/含 ..)。
pub fn isAutoMemPath(allocator: std.mem.Allocator, memdir_abs: []const u8, candidate: []const u8) bool {
    const canon = canonicalAutoMemPath(allocator, memdir_abs, candidate) orelse return false;
    allocator.free(canon);
    return true;
}

/// isAutoMemPath 的"返回 canonical"版:candidate 在 memdir 子树内 → 返回其 **canonical
/// 绝对路径**(owned);否则 null。
/// autosync 的 stable_key 必须哈希 **canonical** 而非模型传入的原始 path(Linus 复审严重条):
/// 同一文件的不同拼写(APFS 大小写不敏感 `Lesson.md`/`lesson.md`、`/tmp` vs `/private/tmp`、
/// symlink、相对路径)若各算一个 key → 各建一个 document → 旧版本永久留在召回里
/// (召回污染从后门溜回)。防穿越与 key 派生用**同一份** canonical,单一基准。
pub fn canonicalAutoMemPath(allocator: std.mem.Allocator, memdir_abs: []const u8, candidate: []const u8) ?[]u8 {
    if (memdir_abs.len == 0 or candidate.len == 0) return null;

    // 归一化 candidate。新建文件 realpath 失败 → realpath 其父目录 + basename 重组。
    const canon = canonicalForWrite(allocator, candidate) catch return null;

    // 归一化 memdir 本身(防 memdir_abs 自身含 symlink/.. → 两侧同基准比较)。
    const mem_canon = canonical(allocator, memdir_abs) catch {
        allocator.free(canon);
        return null;
    };
    defer allocator.free(mem_canon);

    // 严格前缀 + 分隔符边界:canon == mem_canon(写 memdir 本身,罕见)或 canon 以 "mem_canon/" 开头。
    if (std.mem.eql(u8, canon, mem_canon)) return canon;
    // 分隔符用 isSep 判:realpath 在 Windows 上返回反斜杠,写死 '/' 会让已存在文件的
    // canonical 路径永远过不了边界检查——memdir 内的每次 Edit 都失去豁免,autosync 也
    // 跟着失效。src/agents/memory.zig 的 isWithin 用的就是 isSep,同一条纪律。
    if (canon.len > mem_canon.len and
        std.mem.startsWith(u8, canon, mem_canon) and
        std.fs.path.isSep(canon[mem_canon.len]))
    {
        return canon;
    }
    allocator.free(canon);
    return null;
}

/// 为"将写入(可能尚不存在)的路径"做 realpath:
/// 先直接 realpath;失败(文件不存在)则 realpath 其 dirname 再拼 basename。
/// dirname 也不存在 → 返回 error(无法安全判定,宁可拒绝豁免)。
///
/// 安全(Linus #1):**最后一段若是已存在的 symlink → 拒绝**。否则攻击者在 memdir 内放
/// `escape -> /etc/cron.d/evil`(目标不存在时 access(F_OK) 返 false → 走 else 分支),
/// 父目录 realpath 干净 + 裸 basename 拼回 → 误判"memdir 内" → 豁免放行 → Write open
/// 跟随 symlink 写到 memdir 外(TOCTOU symlink-in-last-component)。lstat 不跟随,挡住它。
fn canonicalForWrite(allocator: std.mem.Allocator, candidate: []const u8) ![]u8 {
    // 直接成功(文件已存在,realpath 解析整条含末段 symlink → 后续前缀匹配会拒绝逃逸的)
    if (path_exists(candidate)) return canonical(allocator, candidate);

    // 拆 dirname / basename
    const dir = std.fs.path.dirname(candidate) orelse return error.NoParent;
    const base = std.fs.path.basename(candidate);
    if (base.len == 0) return error.NoBasename;

    const dir_canon = canonical(allocator, dir) catch return error.ParentRealpathFailed;
    defer allocator.free(dir_canon);
    // 父目录 realpath 后若仍 == 原 dir(realpath 对不存在目录回退原值),说明父也不存在 → 拒绝。
    if (!path_exists(dir_canon)) return error.ParentMissing;

    // 末段 symlink 检查:realpath 后的父目录 + 原 basename,lstat 看它本身是不是 symlink。
    // (access(F_OK) 跟随 symlink 到不存在目标会返 false 漏判,故必须 lstat。)
    const recombined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_canon, base });
    if (isSymlink(recombined)) {
        allocator.free(recombined);
        return error.LastComponentIsSymlink;
    }
    return recombined;
}

/// lstat(不跟随 symlink)判断 path 本身是否为 symlink。不存在/出错 → false(非 symlink)。
/// std.c.lstat 在此 zig 0.16 std 无绑定(同 read_state.zig 记的 std.c.stat 缺失),自声明 extern。
/// macOS arm64 ABI 符号为裸 `lstat`($INODE64 后缀是 x86_64 legacy)。
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

// Windows:symlink/junction/mount-point 统一是 **reparse point**(NTFS 概念),
// GetFileAttributesW 的 FILE_ATTRIBUTE_REPARSE_POINT(0x400) 位标识。GetFileAttributesW
// 本身**不跟随** reparse(返回链接自身属性),故等价 lstat 语义——正是防 TOCTOU 逃逸所需。
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

fn isSymlink(path: []const u8) bool {
    if (path.len + 1 > std.fs.max_path_bytes) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (builtin.os.tag == .windows) {
        // UTF-8 → UTF-16,GetFileAttributesW 查 REPARSE_POINT 位(不跟随 → lstat 语义)。
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
        if (wlen >= wbuf.len) return false;
        wbuf[wlen] = 0;
        const attrs = GetFileAttributesW(@ptrCast(&wbuf));
        if (attrs == INVALID_FILE_ATTRIBUTES) return false; // 不存在/出错 → 非 symlink
        return (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    }
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const flags: u32 = std.os.linux.AT.SYMLINK_NOFOLLOW;
        const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, @ptrCast(&buf), flags, .{ .TYPE = true }, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return false;
        return (stx.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFLNK;
    }
    var st: std.c.Stat = undefined;
    if (lstat(@ptrCast(&buf), &st) != 0) return false;
    return (st.mode & std.c.S.IFMT) == std.c.S.IFLNK;
}

fn path_exists(path: []const u8) bool {
    if (path.len + 1 > std.fs.max_path_bytes) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), std.c.F_OK) == 0;
}

/// 读 MEMORY.md 索引并按 cc 上限截断。返回 owned(caller free)。不存在/空 → null。
/// 截断:先按字节裁到 ≤MAX_ENTRYPOINT_BYTES,再按行裁到 ≤MAX_ENTRYPOINT_LINES,
/// 末尾加截断提示(对齐 cc truncateEntrypointContent 语义)。
pub fn readIndexTruncated(allocator: std.mem.Allocator, home: []const u8, cwd: []const u8) !?[]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = memoryIndexPath(home, cwd, &pbuf);
    if (path.len == 0) return null;

    const raw = readFileAlloc(allocator, path) catch return null;
    defer allocator.free(raw);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;

    // 截断判定
    var content: []const u8 = raw;
    var truncated = false;

    // ① 字节上限:超限则回退到 ≤MAX_ENTRYPOINT_BYTES 的最近**行边界**(Linus #2)。
    //    裸切字节会腰斩 UTF-8(中文记忆常见)+ 切出半行。MEMORY.md 是行导向索引,退到换行最自然。
    if (content.len > MAX_ENTRYPOINT_BYTES) {
        // 主路径:退到最近行边界(行边界天然也是 UTF-8 字符边界,顺带防腰斩 codepoint)。
        var b: usize = MAX_ENTRYPOINT_BYTES;
        while (b > 0 and content[b - 1] != '\n') b -= 1;
        // 极端兜底(几乎不可达):整块 25KB 内一个换行都没有(MEMORY.md 是逐行索引,不该如此)。
        // 才退化成纯 UTF-8 字符边界,至少不腰斩 codepoint。
        if (b == 0) {
            b = MAX_ENTRYPOINT_BYTES;
            while (b > 0 and (content[b] & 0xC0) == 0x80) b -= 1; // 退到非 continuation 字节
        }
        content = content[0..b];
        truncated = true;
    }
    // ② 行上限:数到第 MAX 行的换行处截断
    var line_count: usize = 0;
    var cut: usize = content.len;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            line_count += 1;
            if (line_count >= MAX_ENTRYPOINT_LINES) {
                cut = i;
                truncated = true;
                break;
            }
        }
    }
    content = content[0..cut];

    if (!truncated) return try allocator.dupe(u8, content);

    return try std.fmt.allocPrint(
        allocator,
        "{s}\n\n[... MEMORY.md truncated at {d} lines / {d} bytes ...]",
        .{ content, MAX_ENTRYPOINT_LINES, MAX_ENTRYPOINT_BYTES },
    );
}

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
        if (total > 4 * 1024 * 1024) return error.FileTooLarge;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "memdirPath: 拼路径 + 空 home/cwd 返空" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = memdirPath("/home/u", "/repo/x", &buf);
    try testing.expect(std.mem.startsWith(u8, p, "/home/u/.metacodes/projects/"));
    try testing.expect(std.mem.endsWith(u8, p, "/memory"));
    try testing.expectEqualStrings("", memdirPath("", "/x", &buf));
    try testing.expectEqualStrings("", memdirPath("/h", "", &buf));
}

test "memoryIndexPath: 末尾 MEMORY.md" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = memoryIndexPath("/home/u", "/repo/x", &buf);
    try testing.expect(std.mem.endsWith(u8, p, "/memory/MEMORY.md"));
}

test "isAutoMemPath: 真实 memdir 内放行,外部拒绝(含分隔符边界 + 穿越)" {
    const a = testing.allocator;
    // 真建一个 memdir 子树
    var home_buf: [256]u8 = undefined;
    const home = @import("../../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-memdir-test");
    const fsmod = @import("../../util/fs.zig");
    defer fsmod.testing.rmrfBestEffort(home);

    try ensureDir(home, "/fake/repo");
    var mdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const memdir = memdirPath(home, "/fake/repo", &mdbuf);
    const memdir_owned = try a.dupe(u8, memdir);
    defer a.free(memdir_owned);

    // 内部文件(新建,尚不存在)→ 放行
    const inside = try std.fmt.allocPrint(a, "{s}/MEMORY.md", .{memdir_owned});
    defer a.free(inside);
    try testing.expect(isAutoMemPath(a, memdir_owned, inside));

    const inside2 = try std.fmt.allocPrint(a, "{s}/topic-foo.md", .{memdir_owned});
    defer a.free(inside2);
    try testing.expect(isAutoMemPath(a, memdir_owned, inside2));

    // 分隔符边界:`{memdir}-evil` 的兄弟目录 → 拒绝
    const sibling = try std.fmt.allocPrint(a, "{s}-evil/x.md", .{memdir_owned});
    defer a.free(sibling);
    try testing.expect(!isAutoMemPath(a, memdir_owned, sibling));

    // `..` 穿越:写到 memdir 外 → 拒绝(canonicalForWrite realpath 父目录会归一化掉 ..)
    const escape = try std.fmt.allocPrint(a, "{s}/../escape.md", .{memdir_owned});
    defer a.free(escape);
    try testing.expect(!isAutoMemPath(a, memdir_owned, escape));

    // 完全无关路径 → 拒绝
    try testing.expect(!isAutoMemPath(a, memdir_owned, "/etc/passwd"));
    // 空 → 拒绝
    try testing.expect(!isAutoMemPath(a, "", inside));
    try testing.expect(!isAutoMemPath(a, memdir_owned, ""));
}

test "isAutoMemPath: memdir 内 symlink 末段指向外部(悬空目标)→ 拒绝(Linus #1 TOCTOU)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 用 POSIX symlink() 造真符号链接测拒绝,windows 无此 syscall
    const a = testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = @import("../../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-memdir-symlink");
    const fsmod = @import("../../util/fs.zig");
    defer fsmod.testing.rmrfBestEffort(home);

    try ensureDir(home, "/fake/repo");
    var mdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const memdir = memdirPath(home, "/fake/repo", &mdbuf);
    const memdir_owned = try a.dupe(u8, memdir);
    defer a.free(memdir_owned);

    // 在 memdir 内造一个 symlink `escape` → 指向 memdir 外的**不存在**目标(攻击场景:
    // access(F_OK) 跟随到不存在目标返 false → 旧实现走 else 分支误判 memdir 内)。
    const link_tmp = try std.fmt.allocPrint(a, "{s}/escape", .{memdir_owned});
    defer a.free(link_tmp);
    const link_path = try a.dupeZ(u8, link_tmp);
    defer a.free(link_path);
    const target = "/tmp/cc-zig-symlink-evil-target-does-not-exist";
    const rc = symlink(target, link_path.ptr);
    if (rc != 0) return error.SkipZigTest; // 无法造 symlink(罕见)→ 跳过

    // 写这个 symlink 路径 → 必须拒绝豁免(否则 Write open 跟随 symlink 写到 memdir 外)。
    try testing.expect(!isAutoMemPath(a, memdir_owned, link_path));
}

extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;

test "readIndexTruncated: 不存在返 null;短文件原样;超行截断" {
    const a = testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = @import("../../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-memidx-test");
    const fsmod = @import("../../util/fs.zig");
    defer fsmod.testing.rmrfBestEffort(home);

    // 不存在 → null
    try testing.expect((try readIndexTruncated(a, home, "/fake/repo")) == null);

    try ensureDir(home, "/fake/repo");
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_path = memoryIndexPath(home, "/fake/repo", &pbuf);

    // 短文件 → 原样
    try writeFileZ(idx_path, "# Memory Index\n- [Foo](foo.md) — bar\n");
    const short = (try readIndexTruncated(a, home, "/fake/repo")).?;
    defer a.free(short);
    try testing.expect(std.mem.indexOf(u8, short, "[Foo](foo.md)") != null);
    try testing.expect(std.mem.indexOf(u8, short, "truncated") == null);

    // 超 200 行 → 截断 + 提示
    var big = std.ArrayList(u8).empty;
    defer big.deinit(a);
    var i: usize = 0;
    while (i < 300) : (i += 1) try big.appendSlice(a, "- line\n");
    try writeFileZ(idx_path, big.items);
    const trunc = (try readIndexTruncated(a, home, "/fake/repo")).?;
    defer a.free(trunc);
    try testing.expect(std.mem.indexOf(u8, trunc, "truncated") != null);
    // 截断后行数明显少于 300
    var nl: usize = 0;
    for (trunc) |c| {
        if (c == '\n') nl += 1;
    }
    try testing.expect(nl <= MAX_ENTRYPOINT_LINES + 3);
}

test "readIndexTruncated: 字节超限退到行边界不腰斩(Linus #2)" {
    const a = testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = @import("../../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-memidx-bytes");
    const fsmod = @import("../../util/fs.zig");
    defer fsmod.testing.rmrfBestEffort(home);
    try ensureDir(home, "/fake/repo");
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_path = memoryIndexPath(home, "/fake/repo", &pbuf);

    // 造一个 >25KB 但行数 <200 的文件:少量超长行(每行含多字节 UTF-8 中文),
    // 触发字节上限而非行上限。验证截断点落在换行边界(末字符是 '\n' 或截断提示前是完整行)。
    var big = std.ArrayList(u8).empty;
    defer big.deinit(a);
    var i: usize = 0;
    // 每行 ~600 字节(200 个 "中"=3 字节),50 行 → ~30KB,行数 50 < 200。
    while (i < 50) : (i += 1) {
        try big.appendSlice(a, "- ");
        var j: usize = 0;
        while (j < 200) : (j += 1) try big.appendSlice(a, "中");
        try big.append(a, '\n');
    }
    try writeFileZ(idx_path, big.items);
    try testing.expect(big.items.len > MAX_ENTRYPOINT_BYTES); // 确实超字节上限

    const trunc = (try readIndexTruncated(a, home, "/fake/repo")).?;
    defer a.free(trunc);
    try testing.expect(std.mem.indexOf(u8, trunc, "truncated") != null);

    // 关键:截断提示之前的正文部分,最后一个字符必须是 '\n'(退到了行边界,没腰斩半行/半字符)。
    const marker = "\n\n[... MEMORY.md truncated";
    const mpos = std.mem.indexOf(u8, trunc, marker).?;
    try testing.expect(mpos > 0);
    try testing.expectEqual(@as(u8, '\n'), trunc[mpos - 1]);
    // 正文部分是合法 UTF-8(无腰斩的 continuation 字节序列残留)→ 简单验:不以 continuation 字节结尾。
    try testing.expect((trunc[mpos - 1] & 0xC0) != 0x80);
}

test "isEnabled: 默认 ON;env=1 关;env=0 仍开" {
    // 默认(未 set)
    _ = ppaths.unsetEnv("CLAUDE_CODE_DISABLE_AUTO_MEMORY");
    try testing.expect(isEnabled());
    // set=1 → 关
    _ = ppaths.setEnv("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1");
    defer _ = ppaths.unsetEnv("CLAUDE_CODE_DISABLE_AUTO_MEMORY");
    try testing.expect(!isEnabled());
    // set=0 → 仍开(对齐 isDisabled 反语义:0/空当未禁用)
    _ = ppaths.setEnv("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "0");
    try testing.expect(isEnabled());
}

// libc env(0.16 std.c 无 setenv/unsetenv 包装;见 prompt_override.zig 范式)。

fn writeFileZ(path: []const u8, data: []const u8) !void {
    const fd = try pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = pfs.write(fd, data[written..]);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
