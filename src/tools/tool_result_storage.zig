//! 大工具结果落盘(批1C,对齐 cc toolResultStorage.ts)。
//!
//! 工具结果超过阈值 → 落盘 $HOME/.metacodes/tool-results/<hash>.txt,返回 preview+路径
//! 替代 inline,防大结果(DB dump / 大文件)撑爆 context。FileRead 等已自限的工具不落盘。
//! 失败降级:写盘失败 → 返回截断的 inline preview(不崩)。

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;

/// 默认单结果落盘阈值(对齐 cc DEFAULT_MAX_RESULT_SIZE_CHARS)。
pub const DEFAULT_MAX_RESULT_CHARS: usize = 50_000;
/// preview 长度。
const PREVIEW_CHARS: usize = 2000;

/// 按工具名返回落盘阈值。FileRead/Read 已自限(MAX_FILE_BYTES)→ 不落盘(返很大值)。
pub fn maxResultChars(name: []const u8) usize {
    // Read 自己已有 256KB 文件守卫 + 行截断,不再二次落盘(避免 Read→file→Read 环)。
    if (std.mem.eql(u8, name, "Read")) return std.math.maxInt(usize);
    // Write/Edit/NotebookEdit 结果是**结构化展示数据**(structuredPatch + gitDiff),不是
    // 批量文本 dump。落盘会用 `{"persisted":...}` 信封替换掉 gitDiff,工具卡拿不到 diff →
    // 退回通用折叠裸吐信封 JSON(对齐 cc:编辑结果从不落盘,模型侧只回短文本,diff 仅供展示)。
    if (std.mem.eql(u8, name, "Write") or std.mem.eql(u8, name, "Edit") or std.mem.eql(u8, name, "NotebookEdit"))
        return std.math.maxInt(usize);
    return DEFAULT_MAX_RESULT_CHARS;
}

/// 若 content 超阈值则落盘并返回新 preview 内容(owned,caller free);否则返 null(不改)。
/// session_id 用于命名隔离;home_dir 决定落盘根。任一缺失或写盘失败 → 返回截断 preview。
pub fn maybePersist(
    allocator: std.mem.Allocator,
    name: []const u8,
    content: []const u8,
    home_dir: []const u8,
) !?[]u8 {
    if (content.len <= maxResultChars(name)) return null;
    return try persistForced(allocator, name, content, home_dir);
}

/// 无视阈值,强制落盘并返回 preview(owned)。供 per-message 聚合预算挑大结果落盘用。
/// 写盘失败 → 返回截断 preview(降级)。
pub fn persistForced(
    allocator: std.mem.Allocator,
    name: []const u8,
    content: []const u8,
    home_dir: []const u8,
) !?[]u8 {
    _ = name;
    const hash = std.hash.Wyhash.hash(0, content);

    // 落盘路径:$HOME/.metacodes/tool-results/<hash>.txt
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const persisted: ?[]const u8 = blk: {
        if (home_dir.len == 0) break :blk null;
        const dir = std.fmt.allocPrint(allocator, "{s}/.metacodes/tool-results", .{home_dir}) catch break :blk null;
        defer allocator.free(dir);
        @import("../util/fs.zig").mkdirParents(dir) catch break :blk null;
        const fpath = std.fmt.bufPrintZ(&pathbuf, "{s}/{x}.txt", .{ dir, hash }) catch break :blk null;
        const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) break :blk null;
        defer _ = pfs.close(fd);
        var pos: usize = 0;
        while (pos < content.len) {
            const n = pfs.write(fd, content[pos..][0..content.len - pos]);
            if (n <= 0) break :blk null;
            pos += @intCast(n);
        }
        break :blk allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(fpath.ptr)))) catch null;
    };

    const preview = content[0..@min(content.len, PREVIEW_CHARS)];
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (persisted) |fp| {
        defer allocator.free(fp);
        try w.print("{{\"persisted\":true,\"original_bytes\":{d},\"path\":", .{content.len});
        try std.json.Stringify.encodeJsonString(fp, .{}, w);
        try w.writeAll(",\"preview\":");
        try std.json.Stringify.encodeJsonString(preview, .{}, w);
        // 显式分页导引(三件套的第③件):告诉模型全文已落盘、怎么取剩余(PM 点的隐式约定变显式)。
        try w.writeAll(",\"hint\":\"Output too large; full content saved to the path above (only a preview is shown here). Read that path with offset+limit to page through the rest.\"}");
    } else {
        // 降级:inline 截断 preview(不落盘)。
        try w.print("{{\"truncated\":true,\"original_bytes\":{d},\"preview\":", .{content.len});
        try std.json.Stringify.encodeJsonString(preview, .{}, w);
        try w.writeAll("}");
    }
    return try aw.toOwnedSlice();
}

// ── 缓存失效策略(P0.5)────────────────────────────────────────────────────
/// 缓存文件存活上限:超此 TTL(mtime 判)启动时清理。
const CACHE_TTL_SEC: i64 = 7 * 24 * 3600; // 7 天
/// 缓存目录总量上限:TTL 清理后仍超 → 按 mtime LRU 淘汰最旧的到达标。
const CACHE_MAX_BYTES: u64 = 500 * 1024 * 1024; // 500MB
/// GC 节流:.last-gc 标记 <此间隔 则跳过本次清理(避免每次启动都扫盘)。
const GC_THROTTLE_SEC: i64 = 6 * 3600; // 6 小时

fn nowSec() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}

/// stat 一个路径(裁剪 std 无 std.c.stat 路径版 → open+fstat+close,复用 read_state.statFd 跨平台)。
/// 返回 {mtime 秒, size 字节};打不开/stat 失败 → null。
fn statPathZ(path_z: [*:0]const u8) ?struct { mtime: i64, size: u64 } {
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    const info = @import("../core/read_state.zig").statFd(fd) catch return null;
    return .{ .mtime = @intCast(@divFloor(info.mtime_ns, std.time.ns_per_s)), .size = info.size };
}

/// 清理 tool-results 缓存(失效策略):① 删超 TTL 的文件;② 若总量仍超 CACHE_MAX_BYTES,按 mtime
/// LRU 淘汰最旧的直到达标。节流:.last-gc <6h 则跳过。**best-effort,失败静默**——缓存清理绝不阻断
/// 启动。App init 调一次。补上"落盘缓存只增不删 → 磁盘无界"的洞(把无界摄取从内存位移到磁盘)。
pub fn cleanupCache(allocator: std.mem.Allocator, home_dir: []const u8) void {
    cleanupCacheImpl(allocator, home_dir, CACHE_TTL_SEC, CACHE_MAX_BYTES, GC_THROTTLE_SEC);
}

/// cleanupCache 的核心,cap 参数化(供测试注入小 cap 覆盖 LRU 分支;500MB 真跑不现实)。
fn cleanupCacheImpl(allocator: std.mem.Allocator, home_dir: []const u8, ttl_sec: i64, max_bytes: u64, throttle_sec: i64) void {
    if (home_dir.len == 0) return;
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dirbuf, "{s}/.metacodes/tool-results", .{home_dir}) catch return;
    const now = nowSec();

    // 节流:.last-gc 太近 → 跳过。
    var markbuf: [std.fs.max_path_bytes]u8 = undefined;
    const mark = std.fmt.bufPrintZ(&markbuf, "{s}/.last-gc", .{dir}) catch return;
    if (statPathZ(mark.ptr)) |ms| {
        if (now - ms.mtime < throttle_sec) return; // 太近,跳过
    }

    var dz: [std.fs.max_path_bytes]u8 = undefined;
    const dirz = std.fmt.bufPrintZ(&dz, "{s}", .{dir}) catch return;
    var it = pdir.open(dirz.ptr) orelse return; // 目录不存在(还没落过盘)→ 无事
    defer pdir.close(&it);

    const Ent = struct { name: [128]u8, name_len: usize, mtime: i64, size: u64 };
    var ents = std.ArrayList(Ent).empty;
    defer ents.deinit(allocator);
    var total: u64 = 0;

    while (pdir.next(&it)) |ent| {
        const name = ent.name;
        if (name.len == 0 or name[0] == '.') continue; // . / .. / .last-gc
        if (!std.mem.endsWith(u8, name, ".txt")) continue; // 只碰 <hash>.txt
        if (name.len >= 128) continue;
        var fpbuf: [std.fs.max_path_bytes]u8 = undefined;
        const fp = std.fmt.bufPrintZ(&fpbuf, "{s}/{s}", .{ dir, name }) catch continue;
        const ms = statPathZ(fp.ptr) orelse continue;
        const mt: i64 = ms.mtime;
        const sz: u64 = ms.size;
        // ① TTL:超 7 天直接删。
        if (now - mt > ttl_sec) {
            _ = std.c.unlink(fp.ptr);
            continue;
        }
        var e: Ent = .{ .name = undefined, .name_len = name.len, .mtime = mt, .size = sz };
        @memcpy(e.name[0..name.len], name);
        ents.append(allocator, e) catch {};
        total += sz;
    }

    // ② size-cap:总量超上限 → 按 mtime 升序(最旧先)LRU 淘汰到达标。
    if (total > max_bytes) {
        std.mem.sort(Ent, ents.items, {}, struct {
            fn lt(_: void, a: Ent, b: Ent) bool {
                return a.mtime < b.mtime;
            }
        }.lt);
        for (ents.items) |e| {
            if (total <= max_bytes) break;
            var fpbuf: [std.fs.max_path_bytes]u8 = undefined;
            const fp = std.fmt.bufPrintZ(&fpbuf, "{s}/{s}", .{ dir, e.name[0..e.name_len] }) catch continue;
            if (std.c.unlink(fp.ptr) == 0) total -= e.size;
        }
    }

    // 更新 .last-gc 节流标记(touch)。
    const mfd = pfs.open(mark.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (mfd >= 0) _ = pfs.close(mfd);
}

test "cleanupCache:TTL 删旧留新 + 节流 + 无目录不崩(P0.5)" {
    const a = std.testing.allocator;
    // 隔离 fake home:/tmp/cc-cache-<pid>。
    const home = std.fmt.allocPrint(a, "/tmp/cc-cache-{d}", .{std.c.getpid()}) catch return;
    defer a.free(home);
    const dir = std.fmt.allocPrint(a, "{s}/.metacodes/tool-results", .{home}) catch return;
    defer a.free(dir);

    // ① 无目录 → 不崩(直接返回)。
    cleanupCache(a, home);

    @import("../util/fs.zig").mkdirParents(dir) catch return;
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);

    // 写两个缓存文件:old.txt(backdate 8 天前)+ new.txt(现在)。
    const writeF = struct {
        fn go(d: []const u8, name: []const u8) void {
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ d, name }) catch return;
            const fd = pfs.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
            if (fd < 0) return;
            _ = pfs.write(fd, "x");
            _ = pfs.close(fd);
        }
    }.go;
    writeF(dir, "old.txt");
    writeF(dir, "new.txt");

    // backdate old.txt 的 mtime 到 8 天前(> TTL 7 天)。utimes(atime, mtime)。
    var opb: [std.fs.max_path_bytes]u8 = undefined;
    const oldp = std.fmt.bufPrintZ(&opb, "{s}/old.txt", .{dir}) catch return;
    const eight_days_ago: std.c.timeval = .{ .sec = @intCast(nowSec() - 8 * 24 * 3600), .usec = 0 };
    var times = [2]std.c.timeval{ eight_days_ago, eight_days_ago };
    if (std.c.utimes(oldp.ptr, &times) != 0) return; // 环境不支持 utimes → 跳过

    // 清理:old.txt(超 TTL)应删,new.txt 应留。
    cleanupCache(a, home);
    var pb2: [std.fs.max_path_bytes]u8 = undefined;
    const newp = std.fmt.bufPrintZ(&pb2, "{s}/new.txt", .{dir}) catch return;
    try std.testing.expect(statPathZ(oldp.ptr) == null); // 旧的被删
    try std.testing.expect(statPathZ(newp.ptr) != null); // 新的还在

    // ② 节流:刚写了 .last-gc,立刻再写一个 backdated 文件 + 再清理 → 应被节流跳过,文件仍在。
    writeF(dir, "old2.txt");
    var pb3: [std.fs.max_path_bytes]u8 = undefined;
    const old2p = std.fmt.bufPrintZ(&pb3, "{s}/old2.txt", .{dir}) catch return;
    times = [2]std.c.timeval{ eight_days_ago, eight_days_ago };
    _ = std.c.utimes(old2p.ptr, &times);
    cleanupCache(a, home); // .last-gc 刚 touch → 节流跳过
    try std.testing.expect(statPathZ(old2p.ptr) != null); // 节流生效:虽超 TTL 但没跑清理
}

test "cleanupCacheImpl:size-cap LRU 淘汰最旧到达标(P0.5 覆盖 LRU 分支)" {
    const a = std.testing.allocator;
    const home = std.fmt.allocPrint(a, "/tmp/cc-cache-lru-{d}", .{std.c.getpid()}) catch return;
    defer a.free(home);
    const dir = std.fmt.allocPrint(a, "{s}/.metacodes/tool-results", .{home}) catch return;
    defer a.free(dir);
    @import("../util/fs.zig").mkdirParents(dir) catch return;
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);

    // 写 3 个文件,每个 100 字节,mtime 递增(a 最旧 < b < c)。
    const now = nowSec();
    const names = [_][]const u8{ "aaa.txt", "bbb.txt", "ccc.txt" };
    for (names, 0..) |nm, i| {
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, nm }) catch return;
        const fd = pfs.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        var payload: [100]u8 = undefined;
        @memset(&payload, 'x');
        _ = pfs.write(fd, &payload);
        _ = pfs.close(fd);
        // backdate mtime:a=100s前, b=50s前, c=现在(a 最旧)。
        const t: std.c.timeval = .{ .sec = @intCast(now - @as(i64, @intCast((names.len - i) * 50))), .usec = 0 };
        var times = [2]std.c.timeval{ t, t };
        if (std.c.utimes(p.ptr, &times) != 0) return; // 无 utimes → 跳过
    }

    // 总量 300 字节,max_bytes=150 → LRU 应删最旧(aaa 100→200,仍>150 删 bbb 200... 等)。
    // 删到 ≤150:删 aaa(300→200)、删 bbb(200→100≤150)→ 留 ccc。ttl 给足(不因 TTL 删)。
    cleanupCacheImpl(a, home, 999_999, 150, 0); // throttle=0 保证跑

    const exists = struct {
        fn f(d: []const u8, nm: []const u8) bool {
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ d, nm }) catch return false;
            return statPathZ(p.ptr) != null;
        }
    }.f;
    try std.testing.expect(!exists(dir, "aaa.txt")); // 最旧被 LRU 删
    try std.testing.expect(!exists(dir, "bbb.txt")); // 次旧被删(仍超标)
    try std.testing.expect(exists(dir, "ccc.txt")); // 最新保留(已达标)
}

test "maybePersist: Write/Edit/NotebookEdit 永不落盘(diff 须供工具卡展示)" {
    const a = std.testing.allocator;
    // 构造一个超阈值的 Edit 结果(含 gitDiff)。
    const big = try a.alloc(u8, DEFAULT_MAX_RESULT_CHARS + 100);
    defer a.free(big);
    @memset(big, 'x');
    // home_dir 非空,正常本可落盘;但 Write/Edit/NotebookEdit 被豁免 → 返 null(不改)。
    for ([_][]const u8{ "Write", "Edit", "NotebookEdit" }) |name| {
        const r = try maybePersist(a, name, big, "/tmp");
        try std.testing.expect(r == null); // null = 不落盘
    }
}

test "maybePersist: 非编辑类大结果仍落盘(回归保护)" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, DEFAULT_MAX_RESULT_CHARS + 100);
    defer a.free(big);
    @memset(big, 'x');
    const r = try maybePersist(a, "Bash", big, "/tmp");
    defer if (r) |p| a.free(p);
    try std.testing.expect(r != null); // 仍落盘
    // 信封含 persisted 标记(不再裸吐原文)。
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"persisted\":true") != null);
}
