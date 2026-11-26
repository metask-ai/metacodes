//! 通道 A 注入:合成首条 `<system-reminder>` user message。
//!
//! 对齐 cc/src/utils/api.ts:prependUserContext。把 CLAUDE.md 链(claudemd.load)+
//! AutoMem(memdir MEMORY.md)+ currentDate 包成一条 isMeta user message,prepend 到
//! conversation 最前(agent_loop.buildApiMessages 调用)。
//!
//! 格式(本会话 system-reminder 实证,一字不差):
//!   <system-reminder>
//!   As you answer the user's questions, you can use the following context:
//!   # claudeMd
//!   <MEMORY_INSTRUCTION_PROMPT>
//!
//!   <CLAUDE.md 链 + AutoMem>
//!   # currentDate
//!   Today's date is YYYY-MM-DD (Weekday). Time zone: <zone> (UTC±hh:mm).
//!
//! The date is always there (issue #276), with or without CLAUDE.md, memory
//! or KG content; without them the reminder carries the date alone.
//!         IMPORTANT: this context may or may not be relevant to your tasks. ...
//!   </system-reminder>

const std = @import("std");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;
const claudemd = @import("claudemd.zig");
const time = @import("metacodes-base").util.time;
const time_context = @import("../time_context.zig");

// libc env(0.16 std.c 无 setenv/unsetenv 包装;项目范式见 prompt_override.zig)。

/// env 关闭开关(对齐 cc CLAUDE_CODE_DISABLE_CLAUDE_MDS / --bare)。
pub fn isDisabled() bool {
    if (std.c.getenv("CLAUDE_CODE_DISABLE_CLAUDE_MDS")) |v| {
        const s = std.mem.span(v);
        return !(std.mem.eql(u8, s, "0") or s.len == 0);
    }
    return false;
}

pub const BuildOptions = struct {
    cwd: []const u8 = "",
    home: []const u8 = "",
    /// 状态根:User 级 `<state_root>/AGENTS.md`(claudemd.LoadOptions.state_root)。
    state_root: []const u8 = "",
    /// AutoMem 段(memdir MEMORY.md 索引,已截断)。空则不加。owned-by-caller。
    auto_mem: []const u8 = "",
    /// KG 注入段(持久任务图启动快照,kg/inject.zig 构建)。空则不加(空态零输出,
    /// 设计 KG_DESIGN v3-final §5)。owned-by-caller。
    kg_summary: []const u8 = "",
    /// The instant the date is taken at (unix seconds); null = now.
    now: ?i64 = null,
    /// The zone the date is in; null = the process's zone (time_context.systemZone).
    zone: ?time_context.Zone = null,
};

/// 构建 user-context 文本(owned)。日期段总在(issue #276);CLAUDE.md 链、AutoMem、KG 段
/// 有内容才加,`CLAUDE_CODE_DISABLE_CLAUDE_MDS` 只关这三段(对齐 cc:claudeMd 可关,currentDate 恒在)。
pub fn build(allocator: std.mem.Allocator, opts: BuildOptions) ![]u8 {
    const disabled = isDisabled();
    const chain = if (disabled)
        try allocator.alloc(u8, 0)
    else
        try claudemd.load(allocator, .{ .cwd = opts.cwd, .home = opts.home, .state_root = opts.state_root });
    defer allocator.free(chain);

    const has_chain = chain.len > 0;
    const has_mem = !disabled and opts.auto_mem.len > 0;
    const has_kg = !disabled and opts.kg_summary.len > 0;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\<system-reminder>
        \\As you answer the user's questions, you can use the following context:
        \\
    );
    if (has_chain or has_mem or has_kg) {
        try out.appendSlice(allocator, "# claudeMd\n");
        try out.appendSlice(allocator, claudemd.MEMORY_INSTRUCTION_PROMPT);
        try out.appendSlice(allocator, "\n\n");
    }

    if (has_chain) {
        try out.appendSlice(allocator, chain);
        try out.appendSlice(allocator, "\n");
    }
    if (has_mem) {
        // AutoMem 索引(对齐 cc:作为 AutoMem 类型条目,带专属标签)
        if (has_chain) try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, opts.auto_mem);
        try out.appendSlice(allocator, "\n");
    }
    if (has_kg) {
        // KG 持久任务图快照(设计 v3-final §5;空态在上游即零输出,这里必非空)。
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, opts.kg_summary);
    }

    // currentDate: the date this session started on, with its zone. A later
    // date reaches the model as a notice in that turn (time_context.Announcer),
    // so this first message - and the cache behind it - never moves.
    const now = opts.now orelse time.nowUnix();
    const zone = opts.zone orelse time_context.systemZone(now);
    const today = try time_context.today(allocator, now, &zone);
    defer allocator.free(today);
    try out.appendSlice(allocator, "# " ++ time_context.label ++ "\n");
    try out.appendSlice(allocator, today);
    try out.appendSlice(allocator, "\n");

    try out.appendSlice(allocator,
        \\
        \\      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
        \\</system-reminder>
    );

    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// 测试 helper:把 TmpDir 解析成绝对路径(owned)。
/// realpath 失败**不回退相对路径**:`.zig-cache/tmp/` 是所有并发测试进程共享的目录,
/// 解析失败意味着环境不对(cwd 不是 build root / 目录被并发删掉)。悄悄返回相对路径
/// 只会让下游断言以莫名其妙的方式失败,掩盖真因。报错,让环境问题自己显形。
fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(rel);
    if (rel.len + 1 > std.fs.max_path_bytes) return error.TmpDirPathTooLong;
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..rel.len], rel);
    path_z[rel.len] = 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const res = pfs.realpath(@ptrCast(&path_z), &buf) orelse return error.TmpDirPathUnresolved;
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(res))));
}

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

test "build: wraps CLAUDE.md in system-reminder with instruction prompt" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);
    try writeFileAt(dir, "CLAUDE.md", "MY-PROJECT-RULE-XYZ");

    const out = try build(a, .{ .cwd = dir, .home = "" });
    defer a.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "<system-reminder>"));
    try testing.expect(std.mem.endsWith(u8, out, "</system-reminder>"));
    try testing.expect(std.mem.indexOf(u8, out, "# claudeMd") != null);
    try testing.expect(std.mem.indexOf(u8, out, claudemd.MEMORY_INSTRUCTION_PROMPT) != null);
    try testing.expect(std.mem.indexOf(u8, out, "MY-PROJECT-RULE-XYZ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# currentDate") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Today's date is") != null);
    try testing.expect(std.mem.indexOf(u8, out, "IMPORTANT: this context may or may not be relevant") != null);
}

test "build: auto_mem appended" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);

    const out = try build(a, .{
        .cwd = dir,
        .home = "",
        .auto_mem = "# Memory Index\n- [Foo](foo.md) — bar",
    });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# Memory Index") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[Foo](foo.md)") != null);
}

test "build: kg_summary 注入(DoD:KG 段端到端进首条 user message)" {
    const a = testing.allocator;
    // 仅 kg_summary,无 CLAUDE.md 无 auto_mem:也应产出(has_kg 触发)。
    const out = try build(a, .{
        .cwd = "",
        .home = "",
        .kg_summary = "# Knowledge Graph — 持久任务图(root 7)\n开放任务:2 ready / 1 blocked(共 3)\n",
    });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Knowledge Graph — 持久任务图(root 7)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 ready / 1 blocked") != null);
    // 仍在 system-reminder 信封内(与 claudeMd 同车)。
    try testing.expect(std.mem.indexOf(u8, out, "<system-reminder>") != null);
}

test "build: with no other content the reminder still carries the date and zone (issue #276)" {
    const a = testing.allocator;
    const zone = try time_context.Zone.fromHostOffset(8 * 60);
    // 2026-10-16T16:30:00Z is already Saturday the 17th at UTC+08:00.
    const out = try build(a, .{ .cwd = "", .home = "", .kg_summary = "", .now = 1_792_168_200, .zone = zone });
    defer a.free(out);
    try testing.expectEqualStrings(
        "<system-reminder>\nAs you answer the user's questions, you can use the following context:\n" ++
            "# currentDate\nToday's date is 2026-10-17 (Saturday). Time zone: UTC+08:00.\n" ++
            "\n      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.\n</system-reminder>",
        out,
    );
}

test "build: disabled via env CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 drops CLAUDE.md and memory but keeps the date" {
    const a = testing.allocator;
    // Linus #4 修:之前此测试名说"disabled via env"却根本没 set env(测了反面)。
    // 0.16 std.c 无 setenv 包装,用 extern "c"(见文件顶 + prompt_override.zig)。真 set 验证返回 null。
    //
    // ⚠️ 隔离约束(Linus #4 复审):setenv 改的是**进程全局 env**。本测试依赖
    //   ① Zig test runner 单线程顺序执行;② defer unsetenv 在正常 return / return error
    //   路径都会跑(@panic/unreachable 命中则不跑 → 泄漏到后续测试)。
    //   下面 enabled 对偶测试开头的 unsetenv 是二次防线。
    //   **若将来 runner 转并行,setenv/getenv 非 thread-safe,此方案必须重做**
    //   (改成依赖注入 isDisabled 的 env 读取,或 per-test env 隔离)。
    //   对齐 CLAUDE.md "全局可变态串台"教训,此处留路标。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);

    _ = ppaths.setEnv("CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1");
    defer _ = ppaths.unsetEnv("CLAUDE_CODE_DISABLE_CLAUDE_MDS");
    try testing.expect(isDisabled());

    // 即便项目根有 CLAUDE.md(向上递归会命中),disabled 也不带它与记忆;日期照旧(issue #276)。
    try writeFileAt(dir, "CLAUDE.md", "DISABLED-RULE-XYZ");
    const out = try build(a, .{ .cwd = dir, .home = "", .auto_mem = "stuff" });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "DISABLED-RULE-XYZ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "stuff") == null);
    try testing.expect(std.mem.indexOf(u8, out, "# claudeMd") == null);
    try testing.expect(std.mem.indexOf(u8, out, "# currentDate\nToday's date is ") != null);
}

test "build: enabled (env unset) with content returns non-null" {
    const a = testing.allocator;
    // disabled 测试的对偶:确保未 set env 时正常构建(防 isDisabled 误判恒真)。
    _ = ppaths.unsetEnv("CLAUDE_CODE_DISABLE_CLAUDE_MDS");
    try testing.expect(!isDisabled());
    const out = try build(a, .{ .cwd = "", .home = "", .auto_mem = "MEMINDEX" });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "MEMINDEX") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# claudeMd") != null);
}
