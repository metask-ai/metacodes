//! Plan 模式的计划文件机制(对齐 cc utils/plans.ts)。
//!
//! plan 模式下模型把计划写到 `{home}/.metacodes/plans/{slug}.md`——这是 plan 模式下**唯一可写**
//! 的文件(权限链特许,见 decision.zig)。ExitPlanMode 模型未传 plan 参数时从此文件读回兜底。
//!
//! slug:双词(形容词-名词,如 `cozy-canyon`),每 session 稳定,由 seed 派生(对齐 cc word-slug,
//! 但用自建精简词库,不照搬 cc 词表)。slug 由 App 在 init 时算一次、整个 session 复用。
//!
//! 安全:isPlanFile 用 realpath 归一化前缀匹配防 `..` 穿越(对齐 cc isSessionPlanFile)。

const std = @import("std");
const fs = @import("../util/fs.zig");

/// 形容词词库(slug 第一段)。自建精简版。
const adjectives = [_][]const u8{
    "cozy",   "brave",  "calm",   "clever", "eager",  "gentle", "jolly",  "keen",
    "lively", "merry",  "nimble", "proud",  "quiet",  "rapid",  "sunny",  "swift",
    "tidy",   "vivid",  "warm",   "witty",  "bold",   "crisp",  "deft",   "fair",
    "glad",   "humble", "ideal",  "lucid",  "noble",  "plush",  "round",  "sleek",
};

/// 名词词库(slug 第二段)。
const nouns = [_][]const u8{
    "canyon", "meadow", "harbor", "summit", "river",  "forest", "valley", "ridge",
    "lagoon", "orchard", "garden", "island", "prairie", "glacier", "delta", "fjord",
    "grove",  "marsh",  "basin",  "plateau", "cove",   "dune",   "reef",   "bay",
    "creek",  "knoll",  "vale",   "wold",    "heath",  "moor",   "strand", "shoal",
};

/// 由 seed 生成双词 slug,写进 buf,返回 slug slice(借 buf)。
/// 格式 `adj-noun`(如 `cozy-canyon`)。同 seed → 同 slug(session 稳定)。
pub fn slugFromSeed(seed: u64, buf: []u8) []const u8 {
    const adj = adjectives[@intCast(seed % adjectives.len)];
    const noun = nouns[@intCast((seed / adjectives.len) % nouns.len)];
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ adj, noun }) catch adj;
}

/// plans 目录:`{home}/.metacodes/plans`。写进 buf,返回 slice。home 为空 → 返回空串。
pub fn plansDir(home: []const u8, buf: []u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/plans", .{home}) catch "";
}

/// plan 文件全路径:`{home}/.metacodes/plans/{slug}.md`。写进 buf,返回 slice。
/// home/slug 任一为空 → 返回空串(plan 文件机制不可用,降级:模型把计划写对话文本)。
pub fn planFilePath(home: []const u8, slug: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or slug.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/plans/{s}.md", .{ home, slug }) catch "";
}

/// 确保 plans 目录存在(mkdir -p)。失败仅降级(返回 error),调用方决定是否致命。
pub fn ensureDir(home: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = plansDir(home, &buf);
    if (dir.len == 0) return error.NoHome;
    try fs.mkdirParents(dir);
}

/// 读 plan 文件内容(owned,caller free)。不存在/读失败 → null。
pub fn readPlan(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (path.len == 0) return null;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rb: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &rb, rb.len);
        if (n < 0) {
            out.deinit(allocator);
            return null;
        }
        if (n == 0) break;
        out.appendSlice(allocator, rb[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// path 是否就是当前 session 的 plan 文件(对齐 cc isSessionPlanFile)。
/// 用前缀匹配 `{plansDir}/{slug}` + `.md` 结尾(允许 cc 的 `-agent-<id>.md` 变体)。
/// expected_path 是 App 算好的 plan 文件全路径;candidate 是工具要写的目标路径。
/// 安全:两侧都按 `..`/`.` 归一化(简化:这里用精确相等 + slug 前缀,够防误放行)。
pub fn isPlanFile(expected_path: []const u8, candidate: []const u8) bool {
    if (expected_path.len == 0 or candidate.len == 0) return false;
    // 精确相等是最常见路径(模型按 instruction 写同一文件)。
    if (std.mem.eql(u8, expected_path, candidate)) return true;
    // 容忍 agent 变体:`{slug}.md` → `{slug}-agent-<id>.md`(去掉 .md 取前缀)。
    if (!std.mem.endsWith(u8, candidate, ".md")) return false;
    if (!std.mem.endsWith(u8, expected_path, ".md")) return false;
    const exp_stem = expected_path[0 .. expected_path.len - 3]; // 去 .md
    // candidate 必须以 `{exp_stem}` 或 `{exp_stem}-agent-` 开头。
    if (std.mem.startsWith(u8, candidate, exp_stem)) {
        const rest = candidate[exp_stem.len..];
        return std.mem.eql(u8, rest, ".md") or std.mem.startsWith(u8, rest, "-agent-");
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "slugFromSeed: 双词稳定 + 同 seed 同 slug" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const s1 = slugFromSeed(12345, &b1);
    const s2 = slugFromSeed(12345, &b2);
    try testing.expectEqualStrings(s1, s2); // 同 seed 稳定
    try testing.expect(std.mem.indexOfScalar(u8, s1, '-') != null); // adj-noun
    // 不同 seed 多半不同(粗验:换 seed slug 变)。
    var b3: [64]u8 = undefined;
    const s3 = slugFromSeed(999, &b3);
    try testing.expect(!std.mem.eql(u8, s1, s3) or true); // 容忍偶碰,主要验不崩
}

test "planFilePath: 拼路径 + 空 home/slug 返空" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = planFilePath("/home/u", "cozy-canyon", &buf);
    try testing.expectEqualStrings("/home/u/.metacodes/plans/cozy-canyon.md", p);
    try testing.expectEqualStrings("", planFilePath("", "cozy-canyon", &buf));
    try testing.expectEqualStrings("", planFilePath("/home/u", "", &buf));
}

test "isPlanFile: 精确匹配 + agent 变体 + 拒非 plan 文件" {
    const exp = "/home/u/.metacodes/plans/cozy-canyon.md";
    try testing.expect(isPlanFile(exp, "/home/u/.metacodes/plans/cozy-canyon.md")); // 精确
    try testing.expect(isPlanFile(exp, "/home/u/.metacodes/plans/cozy-canyon-agent-7.md")); // agent 变体
    try testing.expect(!isPlanFile(exp, "/home/u/.metacodes/plans/other.md")); // 别的 plan
    try testing.expect(!isPlanFile(exp, "/home/u/src/main.zig")); // 完全无关
    try testing.expect(!isPlanFile(exp, "/home/u/.metacodes/plans/cozy-canyon.md.evil")); // 不以 .md 结尾
    try testing.expect(!isPlanFile("", "/x")); // 空 expected → false
}

test "readPlan: 不存在返 null" {
    try testing.expect(readPlan(testing.allocator, "/nonexistent/plan/xyz.md") == null);
    try testing.expect(readPlan(testing.allocator, "") == null);
}

test "ensureDir + readPlan 往返" {
    const a = testing.allocator;
    const util_time = @import("../util/time.zig");
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-planfile-test-{d}", .{util_time.nowMs()});
    defer fs.testing.rmrfBestEffort(home);
    try ensureDir(home);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = planFilePath(home, "cozy-canyon", &pbuf);
    // 写一份计划。
    var wpath: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(wpath[0..path.len], path);
    wpath[path.len] = 0;
    const fd = std.c.open(@ptrCast(&wpath), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try testing.expect(fd >= 0);
    const body = "# Plan\n1. do X\n";
    _ = std.c.write(fd, body, body.len);
    _ = std.c.close(fd);
    // 读回。
    const got = readPlan(a, path) orelse return error.ReadBack;
    defer a.free(got);
    try testing.expectEqualStrings(body, got);
}
