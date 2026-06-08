//! 统一路径归一化层(纯字符串变换,不碰文件系统)。
//!
//! 为什么需要:工具用 execve(不经 shell)或直接 syscall(openat/open/chdir)落地路径,
//! `~` 是 **shell** 展开语法,这两条路都不认 → `~/foo` 被当成字面名为 `~` 的目录 → 找不到。
//! 本模块在路径进 syscall/execve **之前**做归一化:展开 `~`、折叠 `//`/`.`/`..`、拦 null byte。
//!
//! 设计决策(对齐 cc/src/utils/path.ts,见 doc 计划):
//! - **默认只展开 `~` + 词法折叠,不 resolve 到绝对**:resolve 相对→绝对会改变 rg 输出的
//!   路径前缀(`src/x`→`/abs/src/x`),破坏现有输出契约。`resolve_relative` 作可选参数留接口。
//! - **不展开 `$VAR`/`%VAR%`**:`$` 在 POSIX 路径里是合法文件名字符,展开会破坏 `cost$5.txt`。
//!   需要变量的走 Bash 工具(经 shell 自己展开)。
//! - **Windows 预留**:分隔符用 `std.fs.path.sep`;HOME 由调用方传入(不在此读 getenv);
//!   盘符/UNC 处理留 `normalizeWindowsPrefix` 桩(POSIX no-op)。
//!
//! traversal 校验只匹配作为**完整路径段**的 `..`(段边界由 sep 界定),不误杀 `my..file.txt`。

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

const sep = std.fs.path.sep;

pub const PathError = error{
    EmbeddedNullByte, // 路径含 \0(C 字符串会被截断 → 静默读错文件,安全洞)
    NoHome, // 路径以 ~ 开头但 home 为空
    PathTooLong,
    OutOfMemory,
    GetCwdFailed, // resolve_relative=true 且 base_dir 空时回退 getCwd 失败
};

pub const NormalizeOptions = struct {
    /// 调用方传 ctx.home_dir(可空)。展开 `~` 用。
    home: []const u8,
    /// 调用方传 ctx.cwd_abs(可空)。resolve_relative 时用;空则回退 getCwd。
    base_dir: []const u8 = "",
    /// 当前全部调用点传 false(只展开 ~ + 词法折叠)。true → 相对路径 resolve 成绝对。
    resolve_relative: bool = false,
};

/// 归一化一个用户/模型提供的路径。返回 allocator-owned 新串。
///
/// 严格顺序:
///   ① null byte 检查 → EmbeddedNullByte
///   ② trim 后为空 → "." (resolve_relative 则为 base_dir)
///   ③ ~ / ~/x 展开(home 空 → NoHome)。**先于词法折叠与 traversal 校验**
///   ④ (Windows)盘符/UNC 前缀归一化 —— POSIX 为 no-op
///   ⑤ resolve_relative 且非绝对 → 前缀 base_dir(或 getCwd)
///   ⑥ 词法折叠:重复 sep、移除 "." 段、消解 ".." 段(保留越根的 ..,留给 traversal 校验抓)
pub fn normalize(allocator: std.mem.Allocator, path: []const u8, opts: NormalizeOptions) PathError![]u8 {
    // ① null byte:所有工具最终落 C 字符串,\0 截断是静默安全洞,最前面一次拦掉。
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNullByte;

    // ② trim 空白后为空
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) {
        const base = if (opts.resolve_relative) try resolveBase(allocator, opts) else null;
        if (base) |b| return b; // resolveBase 已 owned
        return allocator.dupe(u8, ".");
    }

    // ③ ~ 展开(先于一切)。生成中间 owned 串 expanded。
    var expanded_buf: ?[]u8 = null;
    defer if (expanded_buf) |b| allocator.free(b);
    const expanded: []const u8 = blk: {
        if (std.mem.eql(u8, trimmed, "~")) {
            if (opts.home.len == 0) return error.NoHome;
            break :blk opts.home;
        }
        if (std.mem.startsWith(u8, trimmed, "~/")) {
            if (opts.home.len == 0) return error.NoHome;
            // home + sep + rest(rest 去掉 "~/")
            const rest = trimmed[2..];
            const joined = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ opts.home, sep, rest });
            expanded_buf = joined;
            break :blk joined;
        }
        // ~user/... 不碰(需 passwd 查询;工具场景几乎不用),原样进折叠。
        break :blk trimmed;
    };

    // ④ Windows 盘符/UNC 前缀(POSIX no-op)。
    // 返回可能 owned 的串;owned 时挂 win_buf 释放。
    var win_buf: ?[]u8 = null;
    defer if (win_buf) |b| allocator.free(b);
    const after_win = try normalizeWindowsPrefix(allocator, expanded, &win_buf);

    // ⑤ resolve_relative:非绝对 → 前缀 base。
    var resolved_buf: ?[]u8 = null;
    defer if (resolved_buf) |b| allocator.free(b);
    const to_fold: []const u8 = blk: {
        if (opts.resolve_relative and !std.fs.path.isAbsolute(after_win)) {
            const base = try resolveBase(allocator, opts);
            defer allocator.free(base);
            const joined = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ base, sep, after_win });
            resolved_buf = joined;
            break :blk joined;
        }
        break :blk after_win;
    };

    // ⑥ 词法折叠。
    return foldLexical(allocator, to_fold);
}

/// 词法折叠:split on sep → 丢空段和 "." → ".." 弹栈(保留越根的 ..)→ 重组。
/// 保留绝对性(首字符是 sep)。不碰文件系统(不解析 symlink,路径不存在也能折叠)。
fn foldLexical(allocator: std.mem.Allocator, path: []const u8) PathError![]u8 {
    const is_abs = path.len > 0 and path[0] == sep;

    // 收集结果段。容量上界 = 原段数。
    var segs = std.ArrayList([]const u8).empty;
    defer segs.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, sep);
    while (it.next()) |s| {
        if (s.len == 0) continue; // 重复/前导/尾随 sep 产生的空段
        if (std.mem.eql(u8, s, ".")) continue; // "." 段移除
        if (std.mem.eql(u8, s, "..")) {
            // 弹栈,除非:① 绝对路径已到根(丢弃,根的父还是根);
            //          ② 相对路径栈顶已是 ".."(越根,继续累积,留给 traversal 抓)
            if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
                _ = segs.pop();
                continue;
            }
            if (is_abs) continue; // 绝对路径越根 → 丢弃(/.. == /)
            // 相对越根:保留 ".." 段
        }
        try segs.append(allocator, s);
    }

    // 重组。
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    if (is_abs) try out.append(allocator, sep);
    for (segs.items, 0..) |s, i| {
        if (i > 0) try out.append(allocator, sep);
        try out.appendSlice(allocator, s);
    }
    // 全部消解后:绝对 → "/",相对 → "."
    if (out.items.len == 0) {
        return allocator.dupe(u8, if (is_abs) &[_]u8{sep} else ".");
    }
    return out.toOwnedSlice(allocator);
}

/// 解析 base_dir:opts.base_dir 非空用它,否则 getCwd。返回 owned。
fn resolveBase(allocator: std.mem.Allocator, opts: NormalizeOptions) PathError![]u8 {
    if (opts.base_dir.len > 0) return allocator.dupe(u8, opts.base_dir);
    return fs.getCwd(allocator) catch return error.GetCwdFailed;
}

/// Windows 盘符 / `/c/Users`→`C:\` / UNC 前缀归一化。
/// POSIX 编译时是 no-op(返回原串借用,不分配,out_buf 保持 null)。
/// Windows 分支待实现(留接口防 NTLM 凭证泄漏等)。
fn normalizeWindowsPrefix(allocator: std.mem.Allocator, path: []const u8, out_buf: *?[]u8) PathError![]const u8 {
    _ = allocator;
    _ = out_buf;
    if (builtin.os.tag != .windows) return path; // POSIX no-op
    // TODO(windows): `/c/Users/...`→`C:\Users\...` 转换;UNC(`\\`)防 NTLM 凭证泄漏。
    // 目前 cc-zig POSIX-only(71 文件绑 execve/openat),Windows 编不过,此处仅占结构位。
    return path;
}

/// traversal 校验:只匹配作为**完整路径段**的 ".."(段首/段尾/被 sep 包裹)。
/// 对齐真 cc 的 /(?:^|[\\/])\.\.(?:[\\/]|$)/。不误杀 `my..file.txt`、`a..b`、`foo..`(单段)。
pub fn containsTraversal(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, sep);
    while (it.next()) |s| {
        if (std.mem.eql(u8, s, "..")) return true;
    }
    return false;
}

/// normalize + traversal 校验(归一化在前)。工具调用点用这个。
pub fn normalizeChecked(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: NormalizeOptions,
) (PathError || error{PathTraversal})![]u8 {
    const norm = try normalize(allocator, path, opts);
    errdefer allocator.free(norm);
    if (containsTraversal(norm)) return error.PathTraversal;
    return norm;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectNorm(expected: []const u8, path: []const u8, opts: NormalizeOptions) !void {
    const got = try normalize(testing.allocator, path, opts);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "normalize: ~ 展开" {
    const home = "/Users/x";
    try expectNorm("/Users/x/foo", "~/foo", .{ .home = home });
    try expectNorm("/Users/x", "~", .{ .home = home });
    try expectNorm("/Users/x", "~/", .{ .home = home }); // 尾 sep 折叠
    try expectNorm("/Users/x/a/b", "~/a/b", .{ .home = home });
}

test "normalize: ~user 不碰" {
    // ~user 不展开,原样进折叠(它不是 ~/ 也不是裸 ~)
    try expectNorm("~user/foo", "~user/foo", .{ .home = "/Users/x" });
}

test "normalize: ~ 但 home 空 → NoHome" {
    try testing.expectError(error.NoHome, normalize(testing.allocator, "~/foo", .{ .home = "" }));
    try testing.expectError(error.NoHome, normalize(testing.allocator, "~", .{ .home = "" }));
}

test "normalize: 重复 sep 折叠" {
    try expectNorm("a/b/c", "a//b///c", .{ .home = "" });
    try expectNorm("/a/b", "//a//b", .{ .home = "" }); // 前导多 sep → 单 sep(绝对)
}

test "normalize: . 段移除" {
    try expectNorm("a/b", "./a/./b", .{ .home = "" });
    try expectNorm("a", "a/.", .{ .home = "" });
}

test "normalize: .. 段消解" {
    try expectNorm("a/c", "a/b/../c", .{ .home = "" });
    try expectNorm("/etc", "/usr/../etc", .{ .home = "" });
    try expectNorm("/", "/..", .{ .home = "" }); // 绝对越根 → 根
    try expectNorm("/", "/a/..", .{ .home = "" });
}

test "normalize: 相对越根保留 .. (留给 traversal 抓)" {
    try expectNorm("../x", "../x", .{ .home = "" });
    try expectNorm("../../b", "a/../../../b", .{ .home = "" });
    try expectNorm("..", "..", .{ .home = "" });
}

test "normalize: null byte 拒绝" {
    try testing.expectError(error.EmbeddedNullByte, normalize(testing.allocator, "a\x00b", .{ .home = "" }));
}

test "normalize: 空/纯空白 → ." {
    try expectNorm(".", "", .{ .home = "" });
    try expectNorm(".", "   ", .{ .home = "" });
    try expectNorm(".", " \t\n", .{ .home = "" });
}

test "normalize: 绝对路径原样(已归一)" {
    try expectNorm("/etc/hostname", "/etc/hostname", .{ .home = "" });
}

test "normalize: resolve_relative 前缀 base_dir" {
    try expectNorm("/work/src/x", "src/x", .{ .home = "", .base_dir = "/work", .resolve_relative = true });
    // 绝对路径即使 resolve_relative 也不前缀
    try expectNorm("/etc/x", "/etc/x", .{ .home = "", .base_dir = "/work", .resolve_relative = true });
}

test "containsTraversal: 不误杀合法文件名" {
    try testing.expect(!containsTraversal("my..file.txt"));
    try testing.expect(!containsTraversal("a..b"));
    try testing.expect(!containsTraversal("foo.."));
    try testing.expect(!containsTraversal("...")); // 三点是单段,非 ..
    try testing.expect(!containsTraversal("a/b/c"));
    try testing.expect(!containsTraversal("/etc/hostname"));
}

test "containsTraversal: 真 traversal 命中" {
    try testing.expect(containsTraversal("../x"));
    try testing.expect(containsTraversal("a/../../b"));
    try testing.expect(containsTraversal(".."));
    try testing.expect(containsTraversal("a/.."));
    try testing.expect(containsTraversal("/a/../b"));
}

test "normalizeChecked: 归一化在前,traversal 在后" {
    // a/b/../c 折叠成 a/c,无 traversal → 通过
    const ok = try normalizeChecked(testing.allocator, "a/b/../c", .{ .home = "" });
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("a/c", ok);

    // ../x 折叠后仍含 .. → 拒
    try testing.expectError(error.PathTraversal, normalizeChecked(testing.allocator, "../x", .{ .home = "" }));
    // ~ 展开后是干净绝对路径 → 通过
    const home_ok = try normalizeChecked(testing.allocator, "~/foo", .{ .home = "/Users/x" });
    defer testing.allocator.free(home_ok);
    try testing.expectEqualStrings("/Users/x/foo", home_ok);
}
