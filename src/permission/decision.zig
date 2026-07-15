//! 权限决策（M0 骨架实现）。
//!
//! 本期仅支持 4 种模式的粗粒度决策。完整的决策树（deny/ask rules → tool.checkPermissions → hooks）
//! 留给沙箱版本，由 rule.zig / prompt.zig / tool context 一起协作。
//!
//! 注意：本模块的 `Decision` 是不带 reason 字符串的简单枚举——为了避免在 M0 引入 allocator 关注点。
//! 扩展到携带 reason 留给 M2/沙箱阶段。

const std = @import("std");
const Mode = @import("mode.zig").Mode;
const category = @import("category.zig");
const rule_matcher = @import("rule_matcher.zig");
const settings_mod = @import("settings.zig");
const rule_spec = @import("rule_spec.zig");
const hooks_mod = @import("hooks.zig");
const log = @import("../util/log.zig");

pub const Decision = enum { allow, deny, ask };

pub const Context = struct {
    mode: Mode,
    /// 旧 schema rule_set(保留兼容,新代码用 settings)。
    rules: ?*const rule_matcher.RuleSet = null,
    /// 当前激活 skill 的临时白/黑名单(若有)。优先级:active_skill > settings > rules > mode。
    active_skill: ?*const @import("../skills/active.zig").ActiveSkillState = null,
    /// 5 层 settings 聚合(管理 + cli + project local/shared + user)。
    settings: ?*const settings_mod.MergedSettings = null,
    /// rule_spec 匹配上下文(cwd / project_root / home),用于 path / bash compound 等。
    match_ctx: rule_spec.MatchContext = .{},
    /// 沙箱启用?(用于 autoAllowBashIfSandboxed)。
    sandbox_enabled: bool = false,
    /// autoAllowBashIfSandboxed:沙箱内 bash 自动放行(绕过 ask: Bash(*),deny 仍优先)。
    auto_allow_bash_if_sandboxed: bool = false,
    /// PreToolUse hook 集合(最高优先,deny-first)。
    hooks: ?*const hooks_mod.HookSet = null,
    /// hook spawn 需要 allocator(构造 stdin JSON);未提供 → 跳过 hook。
    hook_allocator: ?std.mem.Allocator = null,
    /// 当前 session 的 plan 文件全路径(plan 模式下特许写此文件;空串 = 无)。
    /// 对齐 cc isSessionPlanFile:plan 模式下模型把计划写到此文件,是唯一可写文件。
    plan_file_path: []const u8 = "",
    /// memdir 绝对路径(通道 B 自动记忆目录;空串 = 禁用)。模型用 Write/Edit 自管记忆,
    /// 写此子树内的文件**任何模式都豁免**(对齐 cc isAutoMemPath)。
    /// 安全:豁免严格限于 memdir 子树(realpath + 分隔符边界,见 memdir.isAutoMemPath);
    /// deny 规则 / protected paths 仍优先(memdir 在 ~/.metacodes 下不与之重叠,原则上仍受约束)。
    memdir_abs: []const u8 = "",
    /// memdir 豁免判定需要 allocator(realpath 归一化);null → 跳过豁免(降级:按常规决策)。
    memdir_allocator: ?std.mem.Allocator = null,
    /// **安全关键**:路径判定(protected / accept_edits scope / memdir 豁免)前把 JSON
    /// 转义原文 unescape,与工具层(write.zig/edit.zig 落盘前 unescapeString)逐字节等价。
    /// null → 降级为原始转义字节(仅单测/库最小上下文,那里路径不含转义,无绕过面)。
    /// 见 extractCheckedPath 注释与 B1 绕过。shim 填 ctx.allocator。
    path_check_allocator: ?std.mem.Allocator = null,
};

/// 提取路径参数(file_path/notebook_path/path)并 **unescape**——与工具层落盘前的
/// `util_json.unescapeString` 逐字节等价。owned,caller free;alloc=null / 无路径 / unescape
/// 失败 → null。
///
/// **为何必须 unescape(B1 绕过)**:rule_spec.extractPath 返回 JSON 字符串里的转义原文
/// (`\uXXXX`/`\"`/`\/` 未还原)。工具层(write.zig:21)先 `unescapeString` 再归一化落盘。
/// 若权限层直接拿转义原文判 scope/protected,`{"file_path":"/proj/../etc/x"}`
/// 里的 `..` 不等于字面 `..` → 骗过 isInWorkingDirs/isProtectedPath 判 allow,
/// 而工具还原成真 `..` 折叠后逃出工作目录集。unescape 消除这条分歧。
fn extractCheckedPath(alloc: ?std.mem.Allocator, args: []const u8) ?[]u8 {
    const a = alloc orelse return null;
    const raw = rule_spec.extractPath(args);
    if (raw.len == 0) return null;
    return util_json_mod.unescapeString(raw, a) catch null;
}

const util_json_mod = @import("../util/json.zig");

/// 根据模式 + 工具名决定:允许 / 拒绝 / 询问。
pub fn check(ctx: *const Context, tool_name: []const u8, args: []const u8) Decision {
    // -1. 最高优先:PreToolUse hook(deny-first)。任一 hook block → deny,
    //     hook 看不到的工具(matcher 不匹配)直接 proceed 到下层。
    if (ctx.hooks) |h| {
        if (ctx.hook_allocator) |ha| {
            const dec = hooks_mod.runPreToolUse(h, ha, tool_name, args);
            if (dec == .block) {
                log.warn("permission", "PreToolUse hook blocked tool={s}", .{tool_name});
                return .deny;
            }
        }
    }

    // 0. 最高优先:active skill 白/黑名单
    if (ctx.active_skill) |as| {
        if (as.isDisallowed(tool_name, args)) {
            log.debug("permission", "active skill '{s}' disallowed tool={s}", .{ as.skill_name, tool_name });
            return .deny;
        }
        if (as.isAllowed(tool_name, args)) {
            log.debug("permission", "active skill '{s}' allowed tool={s}", .{ as.skill_name, tool_name });
            return .allow;
        }
    }

    // 1. settings(deny → allow → ask;deny 永远优先)
    if (ctx.settings) |s| {
        const d = settings_mod.evaluate(s, &ctx.match_ctx, tool_name, args);
        switch (d) {
            .deny => {
                log.debug("permission", "settings deny tool={s}", .{tool_name});
                return .deny;
            },
            .allow => {
                // 但 protected paths 始终需要 ask(即便 allow 规则命中也不豁免)
                if (isProtectedTarget(ctx, tool_name, args)) {
                    log.debug("permission", "settings allow OVERRIDDEN by protected path tool={s}", .{tool_name});
                    return .ask;
                }
                log.debug("permission", "settings allow tool={s}", .{tool_name});
                return .allow;
            },
            .ask => {
                log.debug("permission", "settings ask tool={s}", .{tool_name});
                return .ask;
            },
            .undecided => {}, // 落到下层
        }
    }

    // 2. Protected paths:Edit/Write/NotebookEdit 到 .git/.env/.ssh/* 永远 ask
    if (isProtectedTarget(ctx, tool_name, args)) {
        log.debug("permission", "protected path tool={s} -> ask", .{tool_name});
        return .ask;
    }

    // 2.5 memdir 写豁免(通道 B):模型用 Write/Edit 自管自动记忆目录。目标落在 memdir
    //     子树内 → 任何模式 allow(对齐 cc isAutoMemPath)。**置于 deny/protected 之后**:
    //     那两层仍优先(deny 规则、protected paths 不被记忆豁免绕过)。
    //     安全:isAutoMemPath 用 realpath + 分隔符边界,严格限 memdir 子树。
    if (ctx.memdir_abs.len > 0) {
        if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit")) {
            if (ctx.memdir_allocator) |ma| {
                const memdir = @import("../core/memory/memdir.zig");
                // unescape 与工具层等价(见 extractCheckedPath):否则转义路径既进不了豁免
                // 又可能借分歧绕过——统一 unescape 后再判 memdir 子树。
                if (extractCheckedPath(ctx.path_check_allocator orelse ma, args)) |target| {
                    defer (ctx.path_check_allocator orelse ma).free(target);
                    if (memdir.isAutoMemPath(ma, ctx.memdir_abs, target)) {
                        log.debug("permission", "memdir auto-mem write allow: {s}", .{target});
                        return .allow;
                    }
                }
            }
        }
    }

    // 3. 旧细粒度规则(向后兼容)
    if (ctx.rules) |rs| {
        if (rs.match(tool_name, args)) |d| {
            log.debug("permission", "legacy rule tool={s} -> {s}", .{ tool_name, @tagName(d) });
            return d;
        }
    }

    // 4. Bash 专属免询问(plan/dont_ask 除外,它们语义就是限制):
    //    a. readonly 内置命令(ls/cat/grep/git status/...)→ ALLOW
    //    b. autoAllowBashIfSandboxed + 沙箱启用 → ALLOW(物理边界已足够)
    if (std.mem.eql(u8, tool_name, "Bash")) {
        const m4 = @import("mode.zig").canonical(ctx.mode);
        if (m4 != .plan and m4 != .dont_ask) {
            const cmd = rule_spec.extractCommand(args);
            const bp = @import("bash_parser.zig");
            const real = bp.stripWrappers(cmd);
            if (bp.isReadonlyCommand(real)) {
                log.debug("permission", "bash readonly auto-allow: {s}", .{real});
                return .allow;
            }
            if (ctx.sandbox_enabled and ctx.auto_allow_bash_if_sandboxed) {
                log.debug("permission", "autoAllowBashIfSandboxed -> allow", .{});
                return .allow;
            }
        }
    }

    const cat = category.getToolCategory(tool_name);
    const risk = category.getRiskLevel(tool_name);

    const mode_mod = @import("mode.zig");
    const m = mode_mod.canonical(ctx.mode);
    const decision: Decision = blk: {
        if (m == .bypass_permissions) break :blk .allow;
        if (m == .plan) {
            if (cat == .read) break :blk .allow;
            // plan 文件特许:plan 模式下 Write/Edit 目标==当前 session plan 文件 → allow
            // (对齐 cc isSessionPlanFile:plan 文件是 plan 模式下唯一可写文件)。
            if (ctx.plan_file_path.len > 0 and
                (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit")))
            {
                const util_json = @import("../util/json.zig");
                const plan_file = @import("../core/plan_file.zig");
                if (util_json.extractStringField(args, "file_path")) |target| {
                    if (plan_file.isPlanFile(ctx.plan_file_path, target)) {
                        log.debug("permission", "plan mode: allow write to plan file {s}", .{target});
                        break :blk .allow;
                    }
                }
            }
            break :blk .deny;
        }
        if (m == .auto) break :blk if (risk == .low) .allow else .ask;
        if (m == .dont_ask) break :blk .deny;
        if (m == .accept_edits) {
            if (cat == .read) break :blk .allow;
            if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "NotebookEdit")) {
                // 对齐 cc:acceptEdits 只自动接受**工作目录集**(cwd + additionalDirectories)
                // 内的编辑;集外 → ask。/add-dir 由此获得真实语义(扩集)。
                // 无 cwd 信息(单测/库最小上下文)或无路径参数(malformed,execute 会报
                // MissingRequiredField)→ 保持旧 allow,不为无意义调用打扰用户。
                if (ctx.match_ctx.cwd.len > 0) {
                    // **B1 修复**:必须 unescape 后再判(与工具层落盘等价),否则
                    // `/proj/../etc/x` 骗过 scope 门却被工具还原成真 `..` 逃逸。
                    // 有 allocator → unescape 判定;无(单测)→ 降级用原始字节(那里无转义)。
                    if (extractCheckedPath(ctx.path_check_allocator, args)) |target| {
                        defer (ctx.path_check_allocator.?).free(target);
                        if (!rule_spec.isInWorkingDirs(&ctx.match_ctx, target)) {
                            log.debug("permission", "accept_edits: {s} outside working dirs -> ask", .{target});
                            break :blk .ask;
                        }
                    } else {
                        const target = rule_spec.extractPath(args);
                        if (target.len > 0 and !rule_spec.isInWorkingDirs(&ctx.match_ctx, target)) {
                            log.debug("permission", "accept_edits: {s} outside working dirs -> ask", .{target});
                            break :blk .ask;
                        }
                    }
                }
                break :blk .allow;
            }
            break :blk .ask;
        }
        break :blk if (cat == .read) .allow else .ask;
    };

    log.debug("permission", "decide tool={s} mode={s} category={s} risk={s} -> {s}", .{
        tool_name,
        @tagName(ctx.mode),
        @tagName(cat),
        @tagName(risk),
        @tagName(decision),
    });
    return decision;
}

/// 工具是否在写一个 protected path?仅 Edit/Write/NotebookEdit 关心。
/// **B1 修复**:路径先 unescape(与工具层落盘等价),否则 `..`/`\/` 等转义
/// 骗过 basename/段匹配却被工具还原后写进 .ssh/.git 等——该绕过跨所有模式,故此处统一修。
fn isProtectedTarget(ctx: *const Context, tool_name: []const u8, args: []const u8) bool {
    if (!(std.mem.eql(u8, tool_name, "Write") or
        std.mem.eql(u8, tool_name, "Edit") or
        std.mem.eql(u8, tool_name, "NotebookEdit"))) return false;
    if (extractCheckedPath(ctx.path_check_allocator, args)) |path| {
        defer (ctx.path_check_allocator.?).free(path);
        return settings_mod.isProtectedPath(path);
    }
    // 降级(无 allocator:单测/最小上下文,路径无转义):原始字节判定
    const path = rule_spec.extractPath(args);
    if (path.len == 0) return false;
    return settings_mod.isProtectedPath(path);
}

test "bypass_permissions allows everything including dangerous" {
    const ctx = Context{ .mode = .bypass_permissions };
    try std.testing.expect(check(&ctx, "Bash", "rm -rf /") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
}

test "legacy bypass alias still works" {
    const ctx = Context{ .mode = .bypass };
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
}

test "plan mode: read allowed, write/exec denied" {
    const ctx = Context{ .mode = .plan };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Grep", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .deny);
    try std.testing.expect(check(&ctx, "Edit", "") == .deny);
    try std.testing.expect(check(&ctx, "Bash", "") == .deny);
}

test "plan mode: 特许写 plan 文件,其它 Write 仍 deny(对齐 cc isSessionPlanFile)" {
    const plan_path = "/home/u/.metacodes/plans/cozy-canyon.md";
    const ctx = Context{ .mode = .plan, .plan_file_path = plan_path };
    // 写 plan 文件 → allow。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/home/u/.metacodes/plans/cozy-canyon.md\",\"content\":\"x\"}") == .allow);
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/home/u/.metacodes/plans/cozy-canyon.md\"}") == .allow);
    // 写别的文件 → 仍 deny(plan 文件是唯一例外)。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/home/u/src/main.zig\",\"content\":\"x\"}") == .deny);
    // 无 plan_file_path 配置时,连 plan 路径也 deny(机制未启用)。
    const ctx_noplan = Context{ .mode = .plan };
    try std.testing.expect(check(&ctx_noplan, "Write", "{\"file_path\":\"/home/u/.metacodes/plans/cozy-canyon.md\"}") == .deny);
}

test "memdir 写豁免:子树内任何模式 allow,外部按常规;deny 仍优先(通道 B)" {
    const a = std.testing.allocator;
    // 真建一个 memdir 子树(isAutoMemPath 走 realpath,需真实路径)。
    const util_time = @import("../util/time.zig");
    const memdir = @import("../core/memory/memdir.zig");
    const fsmod = @import("../util/fs.zig");
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-decision-memdir-{d}", .{util_time.nowMs()});
    defer fsmod.testing.rmrfBestEffort(home);
    try memdir.ensureDir(home, "/fake/repo");
    var mdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const md = memdir.memdirPath(home, "/fake/repo", &mdbuf);

    // plan 模式(最严):写 memdir 内文件仍 allow(记忆与 plan 正交)。
    const ctx = Context{ .mode = .plan, .memdir_abs = md, .memdir_allocator = a };
    var ibuf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const inside_args = try std.fmt.bufPrint(&ibuf, "{{\"file_path\":\"{s}/topic.md\",\"content\":\"x\"}}", .{md});
    try std.testing.expect(check(&ctx, "Write", inside_args) == .allow);
    try std.testing.expect(check(&ctx, "Edit", inside_args) == .allow);

    // memdir 外的文件:plan 模式照常 deny(豁免严格限子树)。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/etc/passwd\",\"content\":\"x\"}") == .deny);

    // 未配置 memdir_abs → 连 memdir 路径也不豁免(走常规 plan deny)。
    const ctx_off = Context{ .mode = .plan };
    try std.testing.expect(check(&ctx_off, "Write", inside_args) == .deny);
}

test "auto mode: low risk allow, others ask" {
    const ctx = Context{ .mode = .auto };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
    try std.testing.expect(check(&ctx, "Bash", "") == .ask);
}

test "default mode: read allow, write/exec ask" {
    const ctx = Context{ .mode = .default };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
    try std.testing.expect(check(&ctx, "Bash", "") == .ask);
}

test "prompt alias still maps to default mode" {
    const ctx = Context{ .mode = .prompt };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
}

test "accept_edits: read + Write/Edit allow, Bash ask" {
    const ctx = Context{ .mode = .accept_edits };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
    try std.testing.expect(check(&ctx, "Edit", "") == .allow);
    try std.testing.expect(check(&ctx, "NotebookEdit", "") == .allow);
    try std.testing.expect(check(&ctx, "Bash", "ls") == .ask);
}

test "dont_ask: nothing matched in rules → deny" {
    const ctx = Context{ .mode = .dont_ask };
    try std.testing.expect(check(&ctx, "Read", "") == .deny);
    try std.testing.expect(check(&ctx, "Write", "") == .deny);
    try std.testing.expect(check(&ctx, "Bash", "ls") == .deny);
}

test "settings deny takes precedence over mode bypass" {
    const alloc = std.testing.allocator;
    // Build a one-layer settings with Bash(git push) deny
    const src = "{\"permissions\":{\"deny\":[\"Bash(git push)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    const ctx = Context{ .mode = .bypass_permissions, .settings = &ms };
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git push\"}") == .deny);
    // 其它 Bash 在 bypass 下仍然 allow
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"ls\"}") == .allow);
}

test "settings allow grants Bash in default mode" {
    const alloc = std.testing.allocator;
    const src = "{\"permissions\":{\"allow\":[\"Bash(git *)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    const ctx = Context{ .mode = .default, .settings = &ms };
    // git status:settings allow → allow(不询问)
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git status\"}") == .allow);
    // npm test:未命中 settings、非 readonly → 落到 mode → ask
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"npm test\"}") == .ask);
}

test "B1 绕过修复(第4镜像点·规则匹配器): allow 规则 Write(/**) 圈 /proj 不放行 .. 逃逸" {
    const alloc = std.testing.allocator;
    // 用户最常见配置:放行整个项目源码树。
    const src = "{\"permissions\":{\"allow\":[\"Write(/**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    // match_ctx.alloc 必须填(否则规则匹配退回原始字节,不折叠 ..)
    const ctx = Context{
        .mode = .default,
        .settings = &ms,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .alloc = alloc },
        .path_check_allocator = alloc,
    };
    // sanity:圈内正常文件 allow(规则真生效)
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/src/a.zig\"}") == .allow);
    // 明文 .. 逃逸:折叠成 /etc/passwd 不在 /proj → 规则不命中 → 落 mode default → ask(修复前 allow)
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/../../etc/passwd\"}") == .ask);
    // 转义 .. 逃逸:unescape+折叠 同样 ask
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/\\u002e\\u002e/\\u002e\\u002e/etc/passwd\"}") == .ask);
}

test "B1 绕过修复(第4镜像点·deny 不被 .. 降级): deny Edit(/secrets/**) 折叠后仍 deny" {
    const alloc = std.testing.allocator;
    // project 锚 deny:禁编辑项目内 secrets/ 子树。
    const src = "{\"permissions\":{\"deny\":[\"Edit(/secrets/**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    const ctx = Context{
        .mode = .bypass_permissions, // 即便 bypass,deny 仍优先
        .settings = &ms,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .alloc = alloc },
        .path_check_allocator = alloc,
    };
    // 直接编辑 /proj/secrets/key → deny(sanity)
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/proj/secrets/key\"}") == .deny);
    // 经 /proj/src/../secrets 折回 secrets 子树 → 折叠后仍命中 → deny 不被 `..` 降级
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/proj/src/../secrets/key\"}") == .deny);
}

test "protected path forces ask even with allow rule" {
    const alloc = std.testing.allocator;
    // 用户允许 Write 整个 cwd,但 .env 仍要 ask
    const src = "{\"permissions\":{\"allow\":[\"Write(./**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    var match_ctx = rule_spec.MatchContext{ .cwd = "/proj" };
    const ctx = Context{ .mode = .default, .settings = &ms, .match_ctx = match_ctx };
    _ = &match_ctx;

    // 普通文件:allow
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/src/foo.zig\"}") == .allow);
    // .env: protected path 覆盖 → ask
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/.env\"}") == .ask);
    // .git/config: protected → ask
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/proj/.git/config\"}") == .ask);
}

test "bash readonly auto-allow in default mode" {
    const ctx = Context{ .mode = .default };
    // ls / cat / git status → allow(免询问)
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"ls -la\"}") == .allow);
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git status\"}") == .allow);
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"timeout 5 cat foo\"}") == .allow);
    // 写类命令仍 ask
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"rm foo\"}") == .ask);
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git push\"}") == .ask);
}

test "bash readonly NOT auto-allowed in plan/dont_ask" {
    // plan:即便 readonly,Bash 仍 deny(plan 不执行任何命令)
    const ctx_plan = Context{ .mode = .plan };
    try std.testing.expect(check(&ctx_plan, "Bash", "{\"command\":\"ls\"}") == .deny);
    // dont_ask:readonly 也不放行(只放 explicit allow)
    const ctx_da = Context{ .mode = .dont_ask };
    try std.testing.expect(check(&ctx_da, "Bash", "{\"command\":\"ls\"}") == .deny);
}

test "autoAllowBashIfSandboxed allows non-readonly bash" {
    const ctx = Context{
        .mode = .default,
        .sandbox_enabled = true,
        .auto_allow_bash_if_sandboxed = true,
    };
    // 沙箱内:即便是写命令也 allow(物理边界已限制)
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"npm install\"}") == .allow);
    // 没开 autoAllow 时同命令 ask
    const ctx2 = Context{ .mode = .default, .sandbox_enabled = true, .auto_allow_bash_if_sandboxed = false };
    try std.testing.expect(check(&ctx2, "Bash", "{\"command\":\"npm install\"}") == .ask);
}

test "accept_edits: 工作目录集 scope 门(cwd 内 allow / add-dir 内 allow / 集外 ask / .. 逃逸 ask)" {
    const extra = [_][]const u8{"/extra/lib"};
    const ctx = Context{
        .mode = .accept_edits,
        .match_ctx = .{ .cwd = "/proj", .additional_dirs = &extra },
    };
    // cwd 子树内 → 自动放行
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/src/a.zig\"}") == .allow);
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/proj/b.txt\"}") == .allow);
    // additional dir 内 → 自动放行(/add-dir 的真实语义)
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/extra/lib/c.md\"}") == .allow);
    // 集外 → ask(不再无条件放行)
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/etc/hosts.new\"}") == .ask);
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/other/proj/x\"}") == .ask);
    // `..` 词法逃逸 → ask
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/../etc/x\"}") == .ask);
    // NotebookEdit 走 notebook_path,同样受 scope 门
    try std.testing.expect(check(&ctx, "NotebookEdit", "{\"notebook_path\":\"/proj/n.ipynb\"}") == .allow);
    try std.testing.expect(check(&ctx, "NotebookEdit", "{\"notebook_path\":\"/tmp2/n.ipynb\"}") == .ask);
    // read 类不受影响
    try std.testing.expect(check(&ctx, "Read", "{\"file_path\":\"/etc/hosts\"}") == .allow);
}

test "B1 绕过修复: accept_edits 下 JSON 转义的 .. 逃逸被 unescape 后拦成 ask" {
    const a = std.testing.allocator;
    const extra = [_][]const u8{"/extra/lib"};
    const ctx = Context{
        .mode = .accept_edits,
        .match_ctx = .{ .cwd = "/proj", .additional_dirs = &extra },
        .path_check_allocator = a,
    };
    // `..` = ".." 的 JSON 转义;`/` = "/"。unescape 前 startsWith /proj/ 骗过 scope;
    // unescape 后折叠成 /etc/cron.d/pwn 逃出工作目录集 → 必须 ask。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/\\u002e\\u002e/\\u002e\\u002e/etc/cron.d/pwn\",\"content\":\"x\"}") == .ask);
    // 明文 .. 同样拦(normalizeLexical 兜底)。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/../../etc/x\",\"content\":\"x\"}") == .ask);
    // 转义但仍在集内 → allow(unescape 不误伤合法路径)。
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/\\u0073rc/a.zig\",\"content\":\"x\"}") == .allow);
}

test "B1 绕过修复: protected path 的转义绕过被拦(跨模式,default 模式验证)" {
    const a = std.testing.allocator;
    // `.ssh` 明文能被 protected 段匹配拦;但 `.ssh` 之类转义原文过去骗过匹配。
    // 修复后 default 模式写 ~/.ssh/id_rsa(转义写法)仍判 protected → ask(而非 allow)。
    const ctx = Context{ .mode = .default, .path_check_allocator = a };
    // 明文基线:protected → ask
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/home/u/.ssh/id_rsa\"}") == .ask);
    // 转义 `.ssh`(`.ssh`):unescape 后 = .ssh → 仍判 protected → ask(未修前会漏判)
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/home/u/\\u002essh/id_rsa\"}") == .ask);
}

test "accept_edits: 无 cwd 信息或无路径参数保持旧 allow(最小上下文兼容)" {
    // 无 cwd(单测/库消费者):行为与收窄前一致
    const ctx_nocwd = Context{ .mode = .accept_edits };
    try std.testing.expect(check(&ctx_nocwd, "Write", "{\"file_path\":\"/anywhere/x\"}") == .allow);
    try std.testing.expect(check(&ctx_nocwd, "Write", "") == .allow);
    // 有 cwd 但无路径参数(malformed,execute 层会报 MissingRequiredField)→ allow 不打扰用户
    const ctx = Context{ .mode = .accept_edits, .match_ctx = .{ .cwd = "/proj" } };
    try std.testing.expect(check(&ctx, "Write", "{\"content\":\"x\"}") == .allow);
}
