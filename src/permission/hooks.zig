//! Tool hook 系统:PreToolUse + PostToolUse + 生命周期 Stop/PreCompact/PostCompact(对齐 Claude Code hooks)。
//!
//! settings.json:
//!   "hooks": {
//!     "PreToolUse":  [ { "matcher": "Bash",       "hooks": [ {"type":"command","command":"./check.sh"} ] } ],
//!     "PostToolUse": [ { "matcher": "Write|Edit", "hooks": [ {"type":"command","command":"./lint.sh"}  ] } ],
//!     "Stop":        [ { "hooks": [ {"type":"command","command":"./extract_memory.sh"} ] } ],
//!     "PreCompact":  [ { "hooks": [ {"type":"command","command":"./snapshot.sh"} ] } ],
//!     "PostCompact": [ { "hooks": [ {"type":"command","command":"./reinject.sh"} ] } ]
//!   }
//!
//! **生命周期 hook**(无 tool matcher,全触发,非阻塞——block 仅 advisory):
//!   - **Stop**(顶层 agent 自然 end_turn 结束):stdin `{hook_event_name,stop_reason,last_message,num_messages}`——
//!     记忆提取挂载点(hook 自行读 last_message/transcript 写 KG)。subagent(depth!=0)不触发。
//!   - **PreCompact**(自动压缩前):stdin `{hook_event_name,trigger,active_messages,tokens}`——side-effect(存盘/快照)。
//!   - **PostCompact**(压缩成功后):stdin `{hook_event_name,trigger,summary}`;stdout `additionalContext` 拼进
//!     投影摘要 → 模型下轮读得到(条目 I 挂载点:重注入 active skill/plan/MCP)。
//!
//! **PreToolUse**(工具执行前,匹配 matcher 的 hook 被 spawn):
//!   - stdin 喂 `{"hook_event_name":"PreToolUse","tool_name","tool_input"}`(一行 JSON)
//!   - 决策:exit 2 → block;stdout `{"decision":"block"|"deny"}` 或 `{"permissionDecision":"deny"}` → block
//!     (按字段值精确判,不扫全文子串);其它/exit≠0,2 → proceed(非阻塞,进后续权限链)
//!   - 改写:stdout `{"updatedInput":{...}}` → 用它替换工具输入(链式,多 hook 后者覆盖前者)
//!
//! **PostToolUse**(工具执行后,仅真跑过的工具):
//!   - stdin 增加 `"tool_response":<结果>`;stdout `{"additionalContext":"..."}` → 拼进本轮 user 消息注入下轮
//!   - block 决策在此仅 advisory(工具已执行完,不回滚)
//!
//! matcher 语法:工具名精确,或 `A|B|C` 多选,或 `*`/空 = 所有工具。
//! 决策接入:PreToolUse block 走 agent_loop 6a(权限链最前,deny-first)。
//!
//! 安全:hook 是用户配置的本地命令,运行时信任(同 settings)。
//! **超时**:每个 hook stdout 读 poll 有界 HOOK_TIMEOUT_MS(5s),超时 killpg 整组 + 当非阻塞错误放行。
//!
//! **诚实登记——未做**:①PreToolUse 不支持 `permissionDecision:"allow"` 覆盖放行(只能 block 或落后续链);
//! ②PostToolUse block 不回喂模型 blocking error(只 advisory additionalContext);③`continue:false` 停整轮未建模;
//! ④Stop hook 不支持 `decision:"block"` 阻止停止/续跑(仅 side-effect,不 gate 控制流);UserPromptSubmit/
//!   SessionStart/SubagentStop/Notification 等事件仍未做(cc 有 ~30);⑤配置加载见 app.loadHooks。

const std = @import("std");
const process = @import("platform").process;
const log = @import("../util/log.zig");
const util_json = @import("../util/json.zig");
const util_time = @import("../util/time.zig");

/// hook 子进程超时(ms)。超时 → killpg + 当作非阻塞错误(proceed)。防挂死 agent loop。
const HOOK_TIMEOUT_MS: i64 = 5000;

pub const HookDecision = enum {
    /// hook 放行(exit 0 且无 block 决策)— 继续后续权限链
    proceed,
    /// hook 阻止(exit 2 或 stdout decision=block)— 直接 deny
    block,
};

pub const HookEntry = struct {
    /// matcher 字符串:"Bash" / "Write|Edit" / "*" / ""(后两者 = 所有)
    matcher: []const u8,
    /// 该 matcher 下的 command 列表
    commands: []const []const u8,
};

pub const HookSet = struct {
    pre_tool_use: []const HookEntry,
    post_tool_use: []const HookEntry = &.{},
    /// 生命周期 hook(无 tool matcher):Stop(turn 结束)/PreCompact(压缩前)/PostCompact(压缩后)。
    /// 配置结构同 Pre/PostToolUse(`[{hooks:[{command}]}]`),matcher 缺省即"*"(全触发)。
    stop: []const HookEntry = &.{},
    pre_compact: []const HookEntry = &.{},
    post_compact: []const HookEntry = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HookSet) void {
        freeEntries(self.allocator, self.pre_tool_use);
        freeEntries(self.allocator, self.post_tool_use);
        freeEntries(self.allocator, self.stop);
        freeEntries(self.allocator, self.pre_compact);
        freeEntries(self.allocator, self.post_compact);
    }

    pub fn isEmpty(self: *const HookSet) bool {
        return self.pre_tool_use.len == 0 and self.post_tool_use.len == 0 and
            self.stop.len == 0 and self.pre_compact.len == 0 and self.post_compact.len == 0;
    }
    pub fn hasPre(self: *const HookSet) bool {
        return self.pre_tool_use.len != 0;
    }
    pub fn hasPost(self: *const HookSet) bool {
        return self.post_tool_use.len != 0;
    }
    pub fn hasStop(self: *const HookSet) bool {
        return self.stop.len != 0;
    }
    pub fn hasPreCompact(self: *const HookSet) bool {
        return self.pre_compact.len != 0;
    }
    pub fn hasPostCompact(self: *const HookSet) bool {
        return self.post_compact.len != 0;
    }
};

fn freeEntries(alloc: std.mem.Allocator, entries: []const HookEntry) void {
    for (entries) |e| {
        alloc.free(e.matcher);
        for (e.commands) |c| alloc.free(c);
        alloc.free(e.commands);
    }
    alloc.free(entries);
}

/// 从 settings JSON root 解析 hooks.PreToolUse + hooks.PostToolUse。无则返回空 set。
pub fn parse(alloc: std.mem.Allocator, root: std.json.Value) !HookSet {
    var pre: []const HookEntry = &.{};
    errdefer freeEntries(alloc, pre);
    var post: []const HookEntry = &.{};
    errdefer freeEntries(alloc, post);

    var stop: []const HookEntry = &.{};
    errdefer freeEntries(alloc, stop);
    var pre_compact: []const HookEntry = &.{};
    errdefer freeEntries(alloc, pre_compact);
    var post_compact: []const HookEntry = &.{};
    errdefer freeEntries(alloc, post_compact);

    if (root == .object) {
        if (root.object.get("hooks")) |hooks_v| {
            if (hooks_v == .object) {
                pre = try parseEventArray(alloc, hooks_v.object.get("PreToolUse"));
                post = try parseEventArray(alloc, hooks_v.object.get("PostToolUse"));
                stop = try parseEventArray(alloc, hooks_v.object.get("Stop"));
                pre_compact = try parseEventArray(alloc, hooks_v.object.get("PreCompact"));
                post_compact = try parseEventArray(alloc, hooks_v.object.get("PostCompact"));
            }
        }
    }

    return HookSet{
        .pre_tool_use = pre,
        .post_tool_use = post,
        .stop = stop,
        .pre_compact = pre_compact,
        .post_compact = post_compact,
        .allocator = alloc,
    };
}

/// 跨层合并:把多层 settings JSON 文本各自 parse 后,5 类事件的 entry 全部并入一个 HookSet
/// (project 与 user 的 hook 并存,不互相覆盖)。解析失败的层跳过。owned,调用方 deinit。
/// 这是 app.loadHooks 的可测 seam——避免"parse 支持但 loadHooks 漏合并某类事件"静默失效。
pub fn parseAndMerge(alloc: std.mem.Allocator, layer_contents: []const []const u8) !HookSet {
    var pre: std.ArrayList(HookEntry) = .empty;
    var post: std.ArrayList(HookEntry) = .empty;
    var stop_l: std.ArrayList(HookEntry) = .empty;
    var pre_c: std.ArrayList(HookEntry) = .empty;
    var post_c: std.ArrayList(HookEntry) = .empty;
    errdefer {
        for (pre.items) |e| freeOneEntry(alloc, e);
        pre.deinit(alloc);
        for (post.items) |e| freeOneEntry(alloc, e);
        post.deinit(alloc);
        for (stop_l.items) |e| freeOneEntry(alloc, e);
        stop_l.deinit(alloc);
        for (pre_c.items) |e| freeOneEntry(alloc, e);
        pre_c.deinit(alloc);
        for (post_c.items) |e| freeOneEntry(alloc, e);
        post_c.deinit(alloc);
    }
    for (layer_contents) |content| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch continue;
        defer parsed.deinit();
        var hs = parse(alloc, parsed.value) catch continue;
        // **先预留容量(唯一可失败步),在任何 move 之前**——若 OOM,此时 hs 仍完整未移动,整份 deinit
        // 干净返回(不留"半移动"态致泄漏)。之后 appendSliceAssumeCapacity 不会失败。
        pre.ensureUnusedCapacity(alloc, hs.pre_tool_use.len) catch {
            hs.deinit();
            return error.OutOfMemory;
        };
        post.ensureUnusedCapacity(alloc, hs.post_tool_use.len) catch {
            hs.deinit();
            return error.OutOfMemory;
        };
        stop_l.ensureUnusedCapacity(alloc, hs.stop.len) catch {
            hs.deinit();
            return error.OutOfMemory;
        };
        pre_c.ensureUnusedCapacity(alloc, hs.pre_compact.len) catch {
            hs.deinit();
            return error.OutOfMemory;
        };
        post_c.ensureUnusedCapacity(alloc, hs.post_compact.len) catch {
            hs.deinit();
            return error.OutOfMemory;
        };
        // move 各类 entry 进合并列表(内层 matcher/commands 指针转移);只 free 外层数组,不 hs.deinit()。
        pre.appendSliceAssumeCapacity(hs.pre_tool_use);
        post.appendSliceAssumeCapacity(hs.post_tool_use);
        stop_l.appendSliceAssumeCapacity(hs.stop);
        pre_c.appendSliceAssumeCapacity(hs.pre_compact);
        post_c.appendSliceAssumeCapacity(hs.post_compact);
        alloc.free(hs.pre_tool_use);
        alloc.free(hs.post_tool_use);
        alloc.free(hs.stop);
        alloc.free(hs.pre_compact);
        alloc.free(hs.post_compact);
    }
    return HookSet{
        .pre_tool_use = try pre.toOwnedSlice(alloc),
        .post_tool_use = try post.toOwnedSlice(alloc),
        .stop = try stop_l.toOwnedSlice(alloc),
        .pre_compact = try pre_c.toOwnedSlice(alloc),
        .post_compact = try post_c.toOwnedSlice(alloc),
        .allocator = alloc,
    };
}

fn freeOneEntry(alloc: std.mem.Allocator, e: HookEntry) void {
    alloc.free(e.matcher);
    for (e.commands) |c| alloc.free(c);
    alloc.free(e.commands);
}

/// 解析一个 hook 事件数组([{matcher, hooks:[{command}]}])为 HookEntry 切片。null/非数组 → 空。
fn parseEventArray(alloc: std.mem.Allocator, arr_v: ?std.json.Value) ![]const HookEntry {
    var entries: std.ArrayList(HookEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.matcher);
            for (e.commands) |c| alloc.free(c);
            alloc.free(e.commands);
        }
        entries.deinit(alloc);
    }
    const arr = arr_v orelse return entries.toOwnedSlice(alloc);
    if (arr != .array) return entries.toOwnedSlice(alloc);
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const matcher_v = item.object.get("matcher");
        const matcher = if (matcher_v) |m|
            (if (m == .string) try alloc.dupe(u8, m.string) else try alloc.dupe(u8, "*"))
        else
            try alloc.dupe(u8, "*");
        errdefer alloc.free(matcher);

        var cmds: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cmds.items) |c| alloc.free(c);
            cmds.deinit(alloc);
        }
        if (item.object.get("hooks")) |hk| {
            if (hk == .array) {
                for (hk.array.items) |h| {
                    if (h != .object) continue;
                    const cmd_v = h.object.get("command") orelse continue;
                    if (cmd_v != .string) continue;
                    try cmds.append(alloc, try alloc.dupe(u8, cmd_v.string));
                }
            }
        }
        try entries.append(alloc, .{ .matcher = matcher, .commands = try cmds.toOwnedSlice(alloc) });
    }
    return entries.toOwnedSlice(alloc);
}

/// matcher 是否匹配 tool_name。"" / "*" = 所有;"A|B" = A 或 B;否则精确。
pub fn matcherMatches(matcher: []const u8, tool_name: []const u8) bool {
    const m = std.mem.trim(u8, matcher, " \t");
    if (m.len == 0 or std.mem.eql(u8, m, "*")) return true;
    var it = std.mem.splitScalar(u8, m, '|');
    while (it.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), tool_name)) return true;
    }
    return false;
}

/// PreToolUse 完整结果:block 决策 + 可选改写后的工具输入(hook stdout 的 updatedInput,owned)。
pub const PreHookResult = struct {
    decision: HookDecision = .proceed,
    /// hook 改写后的 tool_input(owned by caller allocator)。null=不改写,沿用原 input。
    modified_input: ?[]u8 = null,
};

/// 跑所有匹配 tool_name 的 PreToolUse hook,返回 block 决策 + 最后一个 updatedInput 改写(P0.2)。
/// 任一 block → decision=.block(立即停,已 owned 的 modified_input 一并返回由调用方释放/忽略)。
/// 多个 hook 都给 updatedInput → 后者覆盖前者(串行链式改写)。
pub fn runPreToolUseFull(
    set: *const HookSet,
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) PreHookResult {
    var out = PreHookResult{};
    if (!set.hasPre()) return out;

    const stdin_json = std.fmt.allocPrint(
        alloc,
        "{{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"{s}\",\"tool_input\":{s}}}",
        .{ tool_name, args },
    ) catch return out;
    defer alloc.free(stdin_json);

    for (set.pre_tool_use) |entry| {
        if (!matcherMatches(entry.matcher, tool_name)) continue;
        for (entry.commands) |cmd| {
            var r = runOneHookFull(alloc, cmd, stdin_json);
            // 链式改写:新 updatedInput 覆盖旧的(释放旧)。
            if (r.updated_input) |ui| {
                if (out.modified_input) |old| alloc.free(old);
                out.modified_input = ui;
                r.updated_input = null; // 所有权已转给 out
            }
            if (r.additional_context) |ac| alloc.free(ac); // PreToolUse 不消费 additionalContext
            if (r.decision == .block) {
                log.warn("hook", "PreToolUse blocked tool={s} by hook: {s}", .{ tool_name, cmd });
                out.decision = .block;
                return out;
            }
        }
    }
    return out;
}

/// 兼容旧接口(decision.zig 用):只要 block 决策,丢弃改写。
pub fn runPreToolUse(
    set: *const HookSet,
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) HookDecision {
    const r = runPreToolUseFull(set, alloc, tool_name, args);
    if (r.modified_input) |mi| alloc.free(mi);
    return r.decision;
}

/// 跑所有匹配 tool_name 的 PostToolUse hook(工具执行后,P0.2)。喂 {tool_name, tool_input, tool_response}。
/// 收集各 hook stdout 的 additionalContext,拼成一段注入下一轮模型的补充上下文(owned,调用方 free)。
/// 无匹配 / 无 additionalContext → null。block 决策在此仅记 warn(PostToolUse 不拦执行,已执行完)。
pub fn runPostToolUse(
    set: *const HookSet,
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
    tool_response: []const u8,
) ?[]u8 {
    if (!set.hasPost()) return null;

    const stdin_json = std.fmt.allocPrint(
        alloc,
        "{{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"{s}\",\"tool_input\":{s},\"tool_response\":{s}}}",
        .{ tool_name, args, tool_response },
    ) catch return null;
    defer alloc.free(stdin_json);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    for (set.post_tool_use) |entry| {
        if (!matcherMatches(entry.matcher, tool_name)) continue;
        for (entry.commands) |cmd| {
            const r = runOneHookFull(alloc, cmd, stdin_json);
            defer if (r.updated_input) |ui| alloc.free(ui); // PostToolUse 不消费 updatedInput
            if (r.additional_context) |ac| {
                defer alloc.free(ac);
                if (acc.items.len > 0) acc.append(alloc, '\n') catch {};
                acc.appendSlice(alloc, ac) catch {};
            }
            if (r.decision == .block) {
                log.warn("hook", "PostToolUse hook requested block (post-exec, advisory) tool={s}", .{tool_name});
            }
        }
    }
    if (acc.items.len == 0) return null;
    return acc.toOwnedSlice(alloc) catch null;
}

/// 生命周期 hook 通用 runner(Stop / PreCompact / PostCompact —— 无 tool matcher,全触发)。
/// `stdin_json` 由调用方按事件构造(含 hook_event_name)。所有 entry 的所有 command 都 spawn,
/// 收集各自 stdout 的 additionalContext 拼接返回(owned,调用方 free;无则 null)。
/// **非阻塞**:block 决策仅记 warn(生命周期 hook 不拦控制流,side-effect 为主)。
/// Stop 通常忽略返回值(纯 side-effect 如记忆提取);PostCompact 消费返回值(注入下轮上下文)。
pub fn runLifecycleHooks(
    entries: []const HookEntry,
    alloc: std.mem.Allocator,
    event_name: []const u8,
    stdin_json: []const u8,
) ?[]u8 {
    if (entries.len == 0) return null;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    for (entries) |entry| {
        for (entry.commands) |cmd| {
            const r = runOneHookFull(alloc, cmd, stdin_json);
            defer if (r.updated_input) |ui| alloc.free(ui); // 生命周期 hook 不消费 updatedInput
            if (r.additional_context) |ac| {
                defer alloc.free(ac);
                if (acc.items.len > 0) acc.append(alloc, '\n') catch {};
                acc.appendSlice(alloc, ac) catch {};
            }
            if (r.decision == .block) {
                log.warn("hook", "{s} hook requested block (advisory, lifecycle hook does not gate)", .{event_name});
            }
        }
    }
    if (acc.items.len == 0) return null;
    return acc.toOwnedSlice(alloc) catch null;
}

/// 单 hook 的完整结果:block 决策 + updatedInput(owned)+ additionalContext(owned)。
const OneHookResult = struct {
    decision: HookDecision = .proceed,
    updated_input: ?[]u8 = null,
    additional_context: ?[]u8 = null,
};

/// 跑单个 hook:`/bin/sh -c <cmd>`,把 stdin_json 写进它 stdin,读 exit code + stdout。
/// exit 2 → block;exit 0 → 看 stdout decision;其它 → proceed(非阻塞错误)。
/// stdout JSON 可含 updatedInput(改写工具输入)/ additionalContext(注入模型的补充上下文)。
fn runOneHookFull(alloc: std.mem.Allocator, cmd: []const u8, stdin_json: []const u8) OneHookResult {
    const cmd_z = alloc.dupeZ(u8, cmd) catch return .{};
    defer alloc.free(cmd_z);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr };
    // 走可移植 platform/process.capture(POSIX fork / Windows CreateProcessW+git-bash):喂 stdin
    // JSON、捕 stdout(≤4KB)、继承 env(hook 需 $HOME/$PATH)。**timeout_partial 安全语义**:慢但已
    // 产 block 决策的 hook 超时也保留其部分输出判决,避免 fail-open 漏判(Linus/PM 红线)。cap 命中同理
    // 返部分。spawn/pipe/fork 失败 → fail-open(proceed)但记 warn(坏 hook 与"没 hook"须可区分)。
    const r = process.capture(argv[0..], alloc, .{
        .stdin_data = stdin_json,
        .want_stderr = false,
        .inherit_env = true,
        .timeout_ms = @intCast(HOOK_TIMEOUT_MS),
        .max_bytes = 4096,
        .timeout_partial = true,
    }) catch {
        log.warn("hook", "spawn failed, skipping hook: {s}", .{cmd});
        return .{};
    };
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (r.timed_out) log.warn("hook", "hook 超时 {d}ms 被杀(保留部分输出判决): {s}", .{ HOOK_TIMEOUT_MS, cmd });
    const stdout = r.stdout;
    // 超时/被 kill(exit_code 负)→ 非 exit-2,走 stdout 决策;正常退出取实 exit code(exit 2 = block)。
    const exit_code: u8 = if (r.timed_out) 1 else if (r.exit_code >= 0 and r.exit_code <= 255) @intCast(r.exit_code) else 1;

    var result = OneHookResult{};

    // 决策:exit 2 → block;或 stdout 的 decision **字段值**=block/deny(或 permissionDecision=deny)。
    // **按字段值精确判**(不是子串扫全文)——否则 {"decision":"approve","reason":"do not block"} 会因
    // 正文含 "block" 被误判 block(PM/Linus 抓到的假阳性)。
    if (exit_code == 2) {
        result.decision = .block;
    } else {
        if (util_json.extractStringField(stdout, "decision")) |dec| {
            if (std.mem.eql(u8, dec, "block") or std.mem.eql(u8, dec, "deny")) result.decision = .block;
        }
        if (result.decision == .proceed) {
            if (util_json.extractStringField(stdout, "permissionDecision")) |pd| {
                if (std.mem.eql(u8, pd, "deny")) result.decision = .block;
            }
        }
    }

    // updatedInput:改写工具输入(对象值)。dupe 到父 allocator 逃逸 out_buf。
    if (extractObjectField(stdout, "updatedInput")) |obj| {
        result.updated_input = alloc.dupe(u8, obj) catch null;
    }
    // additionalContext:注入模型的补充文本(字符串值,反转义)。
    if (util_json.extractStringField(stdout, "additionalContext")) |raw| {
        result.additional_context = util_json.unescapeString(raw, alloc) catch null;
    }
    return result;
}

/// 提取 `"key":{...}` 的对象值文本(括号配平,跳字符串+转义)。null=无/非对象。
fn extractObjectField(data: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, data, pat) orelse return null;
    var i = at + pat.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

fn closeAll(a: *[2]std.c.fd_t, b: *[2]std.c.fd_t) void {
    _ = std.c.close(a[0]);
    _ = std.c.close(a[1]);
    _ = std.c.close(b[0]);
    _ = std.c.close(b[1]);
}

// POSIX wait 宏(Zig std.c 不暴露,手写)
fn wifexited(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn wexitstatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "matcherMatches: exact / pipe / wildcard" {
    try testing.expect(matcherMatches("Bash", "Bash"));
    try testing.expect(!matcherMatches("Bash", "Write"));
    try testing.expect(matcherMatches("Write|Edit", "Edit"));
    try testing.expect(matcherMatches("Write|Edit", "Write"));
    try testing.expect(!matcherMatches("Write|Edit", "Bash"));
    try testing.expect(matcherMatches("*", "AnyTool"));
    try testing.expect(matcherMatches("", "AnyTool"));
}

test "parse: PreToolUse hooks" {
    const src =
        \\{"hooks":{"PreToolUse":[
        \\  {"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]},
        \\  {"matcher":"Write|Edit","hooks":[{"type":"command","command":"./guard.sh"},{"type":"command","command":"./log.sh"}]}
        \\]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 2), set.pre_tool_use.len);
    try testing.expectEqualStrings("Bash", set.pre_tool_use[0].matcher);
    try testing.expectEqual(@as(usize, 1), set.pre_tool_use[0].commands.len);
    try testing.expectEqualStrings("echo hi", set.pre_tool_use[0].commands[0]);
    try testing.expectEqual(@as(usize, 2), set.pre_tool_use[1].commands.len);
}

test "parse: no hooks → empty set" {
    const src = "{\"permissions\":{}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();
    try testing.expect(set.isEmpty());
}

test "runPreToolUse: exit 2 blocks" {
    const alloc = testing.allocator;
    // 一个 matcher=Bash 的 hook,命令 exit 2 → block
    const cmds = [_][]const u8{"exit 2"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"ls\"}") == .block);
    // 不匹配的工具 → proceed
    try testing.expect(runPreToolUse(&set, alloc, "Write", "{}") == .proceed);
}

test "runPreToolUse: exit 0 proceeds" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .proceed);
}

test "runPreToolUse: stdout decision=block blocks even on exit 0" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"decision\":\"block\"}'; exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .block);
}

test "runPreToolUse: hook receives tool info on stdin" {
    const alloc = testing.allocator;
    // hook 读 stdin,若含 "rm -rf" 就 block(exit 2),否则 proceed
    const cmds = [_][]const u8{"grep -q 'rm -rf' && exit 2 || exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    // 含 rm -rf → block
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"rm -rf /\"}") == .block);
    // 不含 → proceed
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"ls\"}") == .proceed);
}

// ── P0.2:PreToolUse ModifyInput + PostToolUse ─────────────────────────────

test "parse: PostToolUse hooks 与 PreToolUse 并存" {
    const src =
        \\{"hooks":{
        \\  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pre.sh"}]}],
        \\  "PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"lint.sh"}]}]
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 1), set.pre_tool_use.len);
    try testing.expectEqual(@as(usize, 1), set.post_tool_use.len);
    try testing.expect(set.hasPre() and set.hasPost());
    try testing.expectEqualStrings("Write|Edit", set.post_tool_use[0].matcher);
}

test "extractObjectField: 嵌套对象 + 字符串内含括号/转义引号" {
    const data = "{\"updatedInput\":{\"a\":{\"b\":1},\"s\":\"x}y\\\"z\"},\"other\":2}";
    const obj = extractObjectField(data, "updatedInput").?;
    try testing.expectEqualStrings("{\"a\":{\"b\":1},\"s\":\"x}y\\\"z\"}", obj);
    try testing.expect(extractObjectField(data, "missing") == null);
}

test "runPreToolUseFull: updatedInput 改写工具输入" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"updatedInput\":{\"command\":\"ls -la\"}}'"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    const r = runPreToolUseFull(&set, alloc, "Bash", "{\"command\":\"ls\"}");
    defer if (r.modified_input) |mi| alloc.free(mi);
    try testing.expect(r.decision == .proceed);
    try testing.expect(r.modified_input != null);
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", r.modified_input.?);
}

test "runPostToolUse: 收集 additionalContext" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"additionalContext\":\"lint passed\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &.{}, .post_tool_use = &entries, .allocator = alloc };
    const ctx = runPostToolUse(&set, alloc, "Write", "{\"file\":\"a\"}", "{\"ok\":true}");
    defer if (ctx) |c| alloc.free(c);
    try testing.expect(ctx != null);
    try testing.expectEqualStrings("lint passed", ctx.?);
}

test "decision=approve 含 block 字样不误判 block(字段值精确,非子串扫全文)" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"decision\":\"approve\",\"reason\":\"do not block this\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .proceed);
}

test "大 stdout 不死锁(截断+killpg,poll 有界)" {
    const alloc = testing.allocator;
    // hook 吐 100KB(超 4KB buf + 64KB pipe 缓冲):旧版读满退出后 waitpid 与"子进程阻塞 write"死锁;
    // 新版截断→killpg→waitpid 有界。只要能返回(不 hang)即证无死锁。
    const cmds = [_][]const u8{"yes X | head -c 100000; exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .proceed);
}

test "runPostToolUse: 无 post hook / 不匹配 → null" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"additionalContext\":\"x\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &.{}, .post_tool_use = &entries, .allocator = alloc };
    // matcher=Bash 不匹配 Write → null
    try testing.expect(runPostToolUse(&set, alloc, "Write", "{}", "{}") == null);
    // 完全无 post hook → null
    const empty = HookSet{ .pre_tool_use = &.{}, .allocator = alloc };
    try testing.expect(runPostToolUse(&empty, alloc, "Write", "{}", "{}") == null);
}

// ── G-rest:生命周期 hook(Stop / PreCompact / PostCompact) ─────────────────

test "parse: 生命周期 hook Stop/PreCompact/PostCompact" {
    const src =
        \\{"hooks":{
        \\  "Stop":[{"hooks":[{"type":"command","command":"mem.sh"}]}],
        \\  "PreCompact":[{"hooks":[{"type":"command","command":"snap.sh"}]}],
        \\  "PostCompact":[{"hooks":[{"type":"command","command":"reinject.sh"}]}]
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();
    try testing.expect(set.hasStop());
    try testing.expect(set.hasPreCompact());
    try testing.expect(set.hasPostCompact());
    try testing.expect(!set.isEmpty());
    try testing.expectEqualStrings("mem.sh", set.stop[0].commands[0]);
    try testing.expectEqualStrings("snap.sh", set.pre_compact[0].commands[0]);
    try testing.expectEqualStrings("reinject.sh", set.post_compact[0].commands[0]);
}

test "runLifecycleHooks: 收集 additionalContext + hook 真收到 stdin(含事件名/trigger)" {
    const alloc = testing.allocator;
    // hook 读 stdin(单次 grep,双 grep 会因 stdin 被第一个吃光而误判):同行含 PostCompact...test_cause
    // → 回 GOT,否则 MISS。证明 stdin 真传入 + 返回收集。
    const cmd = "grep -qE 'PostCompact.*test_cause' && echo '{\"additionalContext\":\"GOT\"}' || echo '{\"additionalContext\":\"MISS\"}'";
    const cmds = [_][]const u8{cmd};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const ac = runLifecycleHooks(&entries, alloc, "PostCompact", "{\"hook_event_name\":\"PostCompact\",\"trigger\":\"test_cause\"}");
    try testing.expect(ac != null);
    defer if (ac) |a| alloc.free(a);
    try testing.expectEqualStrings("GOT", ac.?);
}

test "runLifecycleHooks: 空 entries → null(无 hook 不 spawn)" {
    try testing.expect(runLifecycleHooks(&.{}, testing.allocator, "Stop", "{}") == null);
}

test "parseAndMerge: 跨层合并 5 类事件不丢生命周期 hook(loadHooks 接线回归)" {
    const alloc = testing.allocator;
    // project 层:PreToolUse + Stop;user 层:PreCompact + PostCompact。合并后各类都要在(不丢/不覆盖)。
    const layer_project =
        \\{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pre.sh"}]}],
        \\          "Stop":[{"hooks":[{"type":"command","command":"mem.sh"}]}]}}
    ;
    const layer_user =
        \\{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"snap.sh"}]}],
        \\          "PostCompact":[{"hooks":[{"type":"command","command":"reinject.sh"}]}]}}
    ;
    const layers = [_][]const u8{ layer_project, layer_user };
    var set = try parseAndMerge(alloc, &layers);
    defer set.deinit();
    try testing.expect(set.hasPre());
    try testing.expect(set.hasStop());
    try testing.expect(set.hasPreCompact());
    try testing.expect(set.hasPostCompact());
    try testing.expectEqualStrings("pre.sh", set.pre_tool_use[0].commands[0]);
    try testing.expectEqualStrings("mem.sh", set.stop[0].commands[0]);
    try testing.expectEqualStrings("snap.sh", set.pre_compact[0].commands[0]);
    try testing.expectEqualStrings("reinject.sh", set.post_compact[0].commands[0]);
}
