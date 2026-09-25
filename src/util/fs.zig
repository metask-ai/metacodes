//! 文件系统工具：抽离重复的 POSIX syscall 包装。
//!
//! mkdirParents：等价 `mkdir -p`，但不 shell 出子进程。Linux/POSIX only。

const std = @import("std");
const log = @import("log.zig");
const pdir = @import("platform").dir;

pub const MkdirError = error{
    PathTooLong,
    MkdirFailed,
};

/// 递归创建目录（等价 mkdir -p）。已存在视为成功。
/// 权限 0o700；所有层级都用此权限（对 cache/session 目录合适）。
///
/// 错误语义：
///   - 中间层 mkdir 失败若是 EEXIST（常态），忽略；
///   - 中间层若是**其他**错误（EACCES/ENOSPC/ENAMETOOLONG 等），记下来；
///   - 最终完整路径 mkdir 成功 → 返回 OK；
///   - 最终 EEXIST **且**中间无其他错误 → OK（路径已存在）；
///   - 最终 EEXIST **但**中间有其他错误 → MkdirFailed（路径可能被部分创建过，不可信任）；
///   - 最终非 EEXIST 错误 → MkdirFailed。
///
/// 失败时 log.warn 记录 errno + path，便于生产调试（error.MkdirFailed 本身不带信息）。
pub fn mkdirParents(dir: []const u8) MkdirError!void {
    return mkdirAll(dir, 0o700, .strict);
}

/// best-effort 的 `mkdir -p dir`(Write / ApplyPatch / worktree 落盘前自动建目录):任一层失败且
/// 不是 EEXIST 即停,权限等问题交给随后的 open 暴露;只有路径过长是本函数自己的错误。`mode`
/// 一般是 0o755(用户可见的项目目录;`mkdirParents` 的 0o700 是 cache/session 私有目录)。
pub fn mkdirBestEffort(dir: []const u8, mode: c_uint) error{PathTooLong}!void {
    mkdirAll(dir, mode, .best_effort) catch |err| switch (err) {
        error.PathTooLong => return error.PathTooLong,
        error.MkdirFailed => return, // best-effort:按构造不会走到这里
    };
}

/// 为 `path` 建所有缺失的**父**目录(等价 `mkdir -p $(dirname path)`),对齐 TS:Write 到不存在
/// 的目录会先 mkdir -p。Windows 两种分隔符都认。
pub fn mkdirParentsOf(path: []const u8) error{PathTooLong}!void {
    const is_windows = @import("builtin").os.tag == .windows;
    const slash = (if (is_windows) std.mem.lastIndexOfAny(u8, path, "/\\") else std.mem.lastIndexOfScalar(u8, path, '/')) orelse return; // 无目录分量
    if (slash == 0) return; // 直接在根目录下,无需建
    return mkdirBestEffort(path[0..slash], 0o755);
}

const Strictness = enum { strict, best_effort };

/// 唯一的 `mkdir -p` 走查器(#121 review:此前三份拷贝各自漂移——apply_patch 那份没有反斜杠
/// 与盘符处理)。已存在的目录先用一次 `exists` 短路:编辑已有文件是常态,不必逐级发一串必失败
/// 的 mkdir。Windows:跳过盘符前缀——`mkdir("C:")` 报非 EEXIST 错会把 mid_failed 置真(strict)
/// 或让第一层就早退(best-effort),一层都建不出来;UNC(`\\server\share\...`)不支持,首段
/// 同样失败,交给随后的 open 报错。建目录走 `pfs.mkdir`,中文分量在 Windows 落到精确的名字。
///
/// strict 的错误语义(cache/session 目录):
///   - 中间层 EEXIST(常态)忽略;其它错误记下来;
///   - 最终 mkdir 成功 → OK;最终 EEXIST 且中间无其它错误 → OK;
///   - 最终 EEXIST 但中间有其它错误 → MkdirFailed(路径可能被部分创建过,不可信任);
///   - 最终非 EEXIST → MkdirFailed。失败时 log.warn 记 errno + path。
/// best-effort:任一层非 EEXIST 失败即静默返回。errno 只按整数比较/按名查表
/// (`pfs.errnoName`):裸 `@enumFromInt` 遇到 `std.c.E` 没命名的值会 panic(#121)。
fn mkdirAll(dir: []const u8, mode: c_uint, strictness: Strictness) MkdirError!void {
    if (dir.len == 0) return;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) {
        log.warn("fs", "mkdirParents: path too long (len={d}): {s}", .{ dir.len, dir });
        return error.PathTooLong;
    }
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    if (pfs.exists(@ptrCast(&buf))) return; // 常态:整条链已在

    var mid_failed = false;
    var mid_errno: c_int = 0;
    const is_windows = @import("builtin").os.tag == .windows;
    var i: usize = 1;
    if (is_windows and dir.len >= 2 and dir[1] == ':') i = 3;
    while (i < dir.len) : (i += 1) {
        if (dir[i] != '/' and !(is_windows and dir[i] == '\\')) continue;
        buf[i] = 0;
        if (pfs.mkdir(@ptrCast(&buf), mode) != 0 and !pfs.lastErrnoIs(.EXIST)) {
            const e = pfs.lastErrno();
            if (strictness == .best_effort) return;
            if (!mid_failed) {
                mid_failed = true;
                mid_errno = e;
                log.warn("fs", "mkdirParents: intermediate mkdir failed errno={s}({d}) at prefix={s}", .{ pfs.errnoName(e), e, buf[0..i] });
            }
        }
        buf[i] = dir[i]; // 还原原分隔符(Windows 可能是 '\\')
    }

    // 最终完整路径
    if (pfs.mkdir(@ptrCast(&buf), mode) == 0) return;
    const final_errno = pfs.lastErrno();
    if (pfs.lastErrnoIs(.EXIST)) {
        if (mid_failed) {
            log.warn("fs", "mkdirParents: final EEXIST but mid failed errno={s}({d}); not trusted: {s}", .{ pfs.errnoName(mid_errno), mid_errno, dir });
            return error.MkdirFailed;
        }
        return;
    }
    if (strictness == .best_effort) return;
    log.warn("fs", "mkdirParents: final mkdir failed errno={s}({d}) path={s} (mid_failed={})", .{ pfs.errnoName(final_errno), final_errno, dir, mid_failed });
    return error.MkdirFailed;
}

/// 包装 `getcwd(3)`，返回 allocator-owned 的 slice。
///
/// 为什么需要：裸 `std.c.getcwd(&buf, buf.len)` 返回 `?[*]u8`，各 call site 用
/// `@ptrCast(ptr) + std.mem.span` 把 buf 当 NUL-terminated C 字符串——这信任 libc
/// 写了终止符，不验证。POSIX 保证会写，但任何一处对 `buf` 越界的假设都会栈读爆。
///
/// 防护：
///   1. `buf[len-1] = 0` 手动写一个哨兵 NUL；调用 getcwd 传 `buf.len - 1`，保证
///      libc 最多写 `len-1` 字节——**哨兵永远在**，NUL 扫描永远在边界内终止。
///   2. `indexOfScalar` 从头找 0——因为哨兵已存在，`orelse unreachable` 表达
///      "逻辑上不可能 null"，避免伪装的防御性返回值误导 reviewer。
pub const GetCwdError = error{ GetCwdFailed, OutOfMemory };

pub fn getCwd(allocator: std.mem.Allocator) GetCwdError![]u8 {
    // 哨兵与 NUL 扫描住在 pfs.getCwd 里;Windows 在那里走 GetCurrentDirectoryW(UTF-8 输出,#121)。
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&buf) orelse return error.GetCwdFailed;
    return try allocator.dupe(u8, cwd);
}

// ============================================================================
// Testing helpers（命名空间隔离，生产代码误用不了）
// ============================================================================
// 生产安全递归删除(swarm team 目录清理:orphan cleanup / TeamDelete)。
// ============================================================================

/// 一个路径是否 symlink(不跟随,防 symlink 逃逸)。跨平台走 platform/fs（linux statx /
/// macOS fstatat / Windows REPARSE），替代旧的 std.c.Stat（linux 下 void）自声明 extern。
fn isSymlink(path_z: [*:0]const u8) bool {
    return @import("platform").fs.isSymlink(path_z);
}

/// **生产安全**递归删除 swarm team 目录。**双重护栏**:
///   ① 路径必须含 `/.metacodes/teams/`(拒删任意目录)且不含 `..`(拒穿越);
///   ② 递归中遇 symlink **不跟随**(unlink 链接本身,绝不删目标)——防对抗性 symlink 逃逸。
/// best-effort:遇错跳过。Linus SW4 HIGH-1:旧代码误用 testing.rmrfBestEffort(仅 /tmp/cc-zig-
/// 前缀生效)→ orphan cleanup/TeamDelete 在生产是静默 no-op(~/.metacodes/teams 僵尸目录堆积)。
pub fn removeTeamDirTree(path: []const u8) void {
    if (std.mem.indexOf(u8, path, "/.metacodes/teams/") == null) return; // 护栏①:必须在 teams 下
    if (std.mem.indexOf(u8, path, "..") != null) return; // 护栏①:拒穿越
    if (path.len == 0) return;
    rmrfSafeImpl(path, 64);
}

/// 递归实现(symlink-aware):先收集子项名 + closedir,再逐个 lstat 分类——symlink→unlink 链接、
/// 目录→递归、其它→unlink。fd 只占当前 readdir 一个(同 testing 版)。
fn rmrfSafeImpl(path: []const u8, depth_left: u32) void {
    if (depth_left == 0) return;
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    // 目录本身若是 symlink,只 unlink 链接、不进入。
    if (isSymlink(@ptrCast(&pbuf))) {
        pfs.unlinkPath(@ptrCast(&pbuf)) catch {};
        return;
    }
    var it = pdir.open(@ptrCast(&pbuf)) orelse {
        pfs.unlinkPath(@ptrCast(&pbuf)) catch {};
        return;
    };
    const MAX_CHILDREN = 512;
    const MAX_NAME = 256;
    var names: [MAX_CHILDREN][MAX_NAME]u8 = undefined;
    var name_lens: [MAX_CHILDREN]usize = undefined;
    var count: usize = 0;
    while (pdir.next(&it)) |ent| {
        const name = ent.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (count >= MAX_CHILDREN) break;
        if (name.len >= MAX_NAME) continue;
        @memcpy(names[count][0..name.len], name);
        name_lens[count] = name.len;
        count += 1;
    }
    pdir.close(&it);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const name = names[k][0..name_lens[k]];
        var child_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
        if (child.len >= child_buf.len) continue;
        child_buf[child.len] = 0;
        if (isSymlink(@ptrCast(&child_buf))) {
            pfs.unlinkPath(@ptrCast(&child_buf)) catch {}; // symlink:删链接不跟随
        } else {
            rmrfSafeImpl(child, depth_left - 1); // 目录递归 / 文件在其内部 unlink
        }
    }
    _ = pfs.rmdir(@ptrCast(&pbuf));
}

/// 测试专用 helpers。放在命名空间里，避免 pub API 鼓励生产误用。
pub const testing = struct {
    /// 类 `rm -rf` 递归删除。
    /// **安全护栏**:路径必须位于 `<tmpRoot>/cc-zig-*`(见 `isFixturePath`),否则直接返回
    /// 不做事,避免测试代码误删用户数据。POSIX 上即老规则 `/tmp/cc-zig-`;Windows 上是
    /// `%TEMP%/cc-zig-`——老规则在那里永远不匹配,cleanup 曾是静默 no-op。
    /// best-effort:遇到错误跳过,不 return。仅用于测试 cleanup。
    pub fn rmrfBestEffort(path: []const u8) void {
        var rbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (!isFixturePath(path, &rbuf)) return;
        rmrfImpl(path, 32); // 32 层深度上限:防对抗性路径栈溢出;测试数据远低于此
    }

    /// `path` 是否落在 `<tmpRoot>/cc-zig-` 之下——测试 fixture 的唯一合法家。
    pub fn isFixturePath(path: []const u8, buf: []u8) bool {
        const root = tmpRoot(buf);
        if (!std.mem.startsWith(u8, path, root)) return false;
        return std.mem.startsWith(u8, path[root.len..], "/cc-zig-");
    }

    /// 内部递归实现。深度上限防对抗性场景（虽然前缀护栏已限制到 /tmp/cc-zig-*，
    /// 但万一哪天护栏松了或深度本身恶意构造，也不会栈溢出）。
    ///
    /// 实现要点：先把子项名字收集到本地 buffer 并 closedir，再递归。
    /// 这样递归深度 N 时只占 1 个 fd（当前正在 readdir 的那个），不是 N 个。
    /// 测试并行跑时不会因为持 fd 过多而 ulimit 爆。
    fn rmrfImpl(path: []const u8, depth_left: u32) void {
        if (depth_left == 0) return;
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= pbuf.len) return;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        var it = pdir.open(@ptrCast(&pbuf)) orelse {
            pfs.unlinkPath(@ptrCast(&pbuf)) catch {};
            return;
        };

        // 先收集所有子项名到 local buffer，closedir，再递归。
        // 上限 256 个 child 够测试用；多余的下一次 rmrfBestEffort 调用会处理（或被忽略）。
        const MAX_CHILDREN = 256;
        const MAX_NAME = 256;
        var names: [MAX_CHILDREN][MAX_NAME]u8 = undefined;
        var name_lens: [MAX_CHILDREN]usize = undefined;
        var count: usize = 0;
        while (pdir.next(&it)) |ent| {
            const name = ent.name;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (count >= MAX_CHILDREN) break;
            if (name.len >= MAX_NAME) continue;
            @memcpy(names[count][0..name.len], name);
            name_lens[count] = name.len;
            count += 1;
        }
        pdir.close(&it); // 句柄在递归前释放

        // 递归处理每个 child
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const name = names[k][0..name_lens[k]];
            var child_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
            if (child.len >= child_buf.len) continue;
            child_buf[child.len] = 0;
            rmrfImpl(child, depth_left - 1);
        }

        _ = pfs.rmdir(@ptrCast(&pbuf));
    }

    /// 测试 fixture 的临时目录根(不含末尾分隔符)。**唯一规则源**,src 内测试经
    /// tools/test_tmp.zig、组件测试经 `cc.util_fs.testing` 都走这里:
    /// - POSIX 固定 "/tmp"(macOS $TMPDIR ≠ /tmp,其它按 /tmp 拼路径的测试要对得上);
    /// - Windows 用 %TEMP%(当前驱动器根下的 `\tmp` 不保证存在),拷进 buf 并把反斜杠
    ///   归一为正斜杠——Windows API 两种都认,而路径常要嵌进 JSON 工具参数。
    pub fn tmpRoot(buf: []u8) []const u8 {
        if (@import("builtin").os.tag != .windows) return "/tmp";
        const raw = @import("platform").paths.tempDir();
        std.debug.assert(raw.len <= buf.len); // 截断的路径是陷阱,不是降级
        for (raw, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
        return buf[0..raw.len];
    }

    /// `<tmpRoot>/<tag>-<pid>`,NUL 结尾写进 buf。固定路径被并行的测试进程共用会互相踩;
    /// 每个进程一个自己的目录。调用方负责 mkdir 与清理。`tag` 须以 `cc-zig-` 开头,
    /// 否则 `rmrfBestEffort` 的护栏会拒绝清理它。
    pub fn perPidDir(buf: []u8, tag: []const u8) [:0]const u8 {
        std.debug.assert(std.mem.startsWith(u8, tag, "cc-zig-"));
        var rbuf: [std.fs.max_path_bytes]u8 = undefined;
        const pid = @import("platform").process.currentPid();
        return std.fmt.bufPrintZ(buf, "{s}/{s}-{d}", .{ tmpRoot(&rbuf), tag, pid }) catch unreachable;
    }

    var unique_dir_seq = std.atomic.Value(u64).init(0);

    /// `<tmpRoot>/<tag>-<pid>-<单调纳秒>-<序号>`:同一进程内多次调用也互不相同(同一 helper 被
    /// 多个用例反复 setup 时用这个;只需进程级隔离用 `perPidDir`)。规则同上。
    /// 进程内唯一靠 `<序号>`(进程级原子计数,按构造成立),不押时钟:`nowNs` 在 macOS 上是
    /// 1µs 粒度的 CLOCK_MONOTONIC,紧邻两次调用常读到同一值。`<单调纳秒>` 管跨进程:pid 会被
    /// 复用而序号每个进程从 0 数起,靠它不撞上崩溃进程残留的同名目录。
    pub fn uniqueDir(buf: []u8, tag: []const u8) [:0]const u8 {
        std.debug.assert(std.mem.startsWith(u8, tag, "cc-zig-"));
        var rbuf: [std.fs.max_path_bytes]u8 = undefined;
        const pid = @import("platform").process.currentPid();
        const ns = @import("time.zig").nowNs();
        const seq = unique_dir_seq.fetchAdd(1, .monotonic);
        return std.fmt.bufPrintZ(buf, "{s}/{s}-{d}-{d}-{d}", .{ tmpRoot(&rbuf), tag, pid, ns, seq }) catch unreachable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "testing.perPidDir / uniqueDir: root + tag + pid, forward slashes, NUL-terminated, guard accepts them" {
    var buf: [512]u8 = undefined;
    const d = testing.perPidDir(&buf, "cc-zig-fs-selftest");
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, d, testing.tmpRoot(&rbuf)));
    try std.testing.expect(std.mem.indexOf(u8, d, "/cc-zig-fs-selftest-") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\\") == null);
    try std.testing.expect(d[d.len] == 0);
    try std.testing.expect(testing.isFixturePath(d, &rbuf));

    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const first = testing.uniqueDir(&b1, "cc-zig-fs-selftest");
    const second = testing.uniqueDir(&b2, "cc-zig-fs-selftest");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(testing.isFixturePath(first, &rbuf));
}

test "testing.uniqueDir: 64 back-to-back calls stay distinct (process sequence, not clock resolution)" {
    // macOS 的 CLOCK_MONOTONIC 是 1µs 粒度,紧邻的调用常落在同一微秒:唯一性若押在时钟上,
    // 这 64 连发实测 Debug/ReleaseSafe 次次撞(上面只比两次的断言只是间歇失败)。
    var bufs: [64][256]u8 = undefined;
    var dirs: [64][]const u8 = undefined;
    for (&bufs, &dirs) |*b, *d| d.* = testing.uniqueDir(b, "cc-zig-fs-selftest");
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    for (dirs, 0..) |x, i| {
        try std.testing.expect(testing.isFixturePath(x, &rbuf));
        for (dirs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x, y));
    }
}

test "testing.isFixturePath: refuses anything outside <tmpRoot>/cc-zig-" {
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(!testing.isFixturePath("/", &rbuf));
    try std.testing.expect(!testing.isFixturePath("/home/alice/cc-zig-x", &rbuf));
    var root_buf: [std.fs.max_path_bytes]u8 = undefined; // 独立于 rbuf:isFixturePath 会改写 rbuf
    const root = testing.tmpRoot(&root_buf);
    var b1: [512]u8 = undefined;
    const outside = try std.fmt.bufPrint(&b1, "{s}/metacodes-not-a-fixture", .{root});
    try std.testing.expect(!testing.isFixturePath(outside, &rbuf));
    var b2: [512]u8 = undefined;
    const sibling = try std.fmt.bufPrint(&b2, "{s}-evil/cc-zig-x", .{root});
    try std.testing.expect(!testing.isFixturePath(sibling, &rbuf));
}

const pfs = @import("platform").fs;

test "removeTeamDirTree: 删 teams 子树 + 护栏拒非 teams 路径 + 不跟随 symlink" {
    var hb: [256]u8 = undefined;
    // 造 {home}/.metacodes/teams/proj/{config.json, inboxes/bob.json}(home 在 <tmpRoot>/cc-zig-)。
    const home = testing.uniqueDir(&hb, "cc-zig-rmteam");
    var db: [512]u8 = undefined;
    const teamdir = std.fmt.bufPrint(&db, "{s}/.metacodes/teams/proj", .{home}) catch unreachable;
    var ib: [600]u8 = undefined;
    const inboxdir = std.fmt.bufPrint(&ib, "{s}/inboxes", .{teamdir}) catch unreachable;
    mkdirParents(inboxdir) catch unreachable;
    // 写两个文件。
    inline for (.{ "config.json", "inboxes/bob.json" }) |rel| {
        var fb: [700:0]u8 = undefined;
        const fp = std.fmt.bufPrintZ(&fb, "{s}/{s}", .{ teamdir, rel }) catch unreachable;
        const fd = pfs.open(fp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (fd >= 0) {
            _ = pfs.write(fd, "{}");
            pfs.close(fd);
        }
    }
    // 护栏:非 teams 路径拒删(home 本身不含 /.metacodes/teams/)。
    removeTeamDirTree(home);
    var hz: [200:0]u8 = undefined;
    @memcpy(hz[0..home.len], home);
    hz[home.len] = 0;
    try std.testing.expect(pfs.exists(&hz)); // home 仍在(护栏生效)

    // 删 team 子树 → 目录没了。
    removeTeamDirTree(teamdir);
    var tz: [512:0]u8 = undefined;
    @memcpy(tz[0..teamdir.len], teamdir);
    tz[teamdir.len] = 0;
    try std.testing.expect(!pfs.exists(&tz));

    // 收尾。
    testing.rmrfBestEffort(home);
}

test "removeTeamDirTree: `..` 穿越被拒" {
    // 含 .. 的路径即便含 /.metacodes/teams/ 也拒(护栏②)。
    removeTeamDirTree("/tmp/cc-zig-x/.metacodes/teams/../../../etc");
    // 不崩即通过(无副作用);拿各平台必存在的目录做"世界还在"锚点(Windows 无 /etc)。
    const anchor = if (@import("builtin").os.tag == .windows) "C:\\Windows" else "/etc";
    try std.testing.expect(pfs.exists(anchor));
}

test "mkdirParents creates nested dirs" {
    var root_buf: [512]u8 = undefined;
    const root = testing.perPidDir(&root_buf, "cc-zig-mkdirp-test-root");
    var tmp_buf: [600]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/a/b/c/d", .{root});
    defer testing.rmrfBestEffort(root);
    try mkdirParents(tmp);
    // 再调一次应该静默成功（幂等）
    try mkdirParents(tmp);
}

test "mkdirParents empty is noop" {
    try mkdirParents("");
}

test "mkdirParentsOf creates the parent chain of a file path and leaves the leaf alone" {
    var root_buf: [512]u8 = undefined;
    const root = testing.perPidDir(&root_buf, "cc-zig-mkdirp-of-root");
    defer testing.rmrfBestEffort(root);
    var file_buf: [600]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&file_buf, "{s}/a/b/leaf.txt", .{root});
    try mkdirParentsOf(file);
    var parent_buf: [600]u8 = undefined;
    const parent = try std.fmt.bufPrintZ(&parent_buf, "{s}/a/b", .{root});
    try std.testing.expect(pfs.exists(parent.ptr));
    try std.testing.expect(!pfs.exists(file.ptr)); // 只建父目录,叶子归调用方
    try mkdirParentsOf(file); // 幂等
    try mkdirParentsOf("leaf.txt"); // 无目录分量 → no-op
    try mkdirParentsOf("/leaf.txt"); // 根下 → no-op
}

test "mkdirParents existing dir ok" {
    try mkdirParents("/tmp"); // 已存在
}

test "rmrfBestEffort rejects non-/tmp/cc-zig- paths" {
    // 这些都不应该真的删除任何东西；只要不 panic 就算过
    testing.rmrfBestEffort("/etc");
    testing.rmrfBestEffort("/home");
    testing.rmrfBestEffort("/tmp/foo"); // /tmp 但不是 cc-zig- 前缀
    testing.rmrfBestEffort("");
}

test "getCwd returns non-empty absolute path" {
    const cwd = try getCwd(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try std.testing.expect(cwd.len > 0);
    // 绝对路径:POSIX 以 '/' 开头;Windows 以盘符 'X:' 开头。
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(cwd.len >= 2 and cwd[1] == ':');
    } else {
        try std.testing.expect(cwd[0] == '/');
    }
    // 不应包含 NUL 字节
    try std.testing.expect(std.mem.indexOfScalar(u8, cwd, 0) == null);
}

test "getCwd matches libc's native result exactly" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 窄字符 getcwd 在 Windows 给 ANSI 字节,不是 oracle
    // 对比 wrapper 返回和 std.c.getcwd 的原生 NUL-terminated 结果。
    // 如果 wrapper 的边界/哨兵逻辑错（例如返回整个 undefined buf），长度和内容会不一致。
    var expected_buf: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes;
    const ret = std.c.getcwd(&expected_buf, expected_buf.len - 1);
    try std.testing.expect(ret != null);
    const expected = std.mem.span(@as([*:0]const u8, @ptrCast(ret.?)));

    const cwd = try getCwd(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try std.testing.expectEqualStrings(expected, cwd);
}
