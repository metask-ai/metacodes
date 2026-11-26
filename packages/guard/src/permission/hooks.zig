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
//!   - **Stop**(顶层 agent 自然 end_turn 结束):stdin `{hook_event_name,stop_reason,last_message,num_messages,
//!     stop_hook_active}`——记忆提取挂载点(hook 自行读 last_message/transcript 写 KG)。subagent(depth!=0)不触发。
//!     **唯一能 gate 控制流的生命周期 hook**(对齐 Claude Code):exit 2 或 stdout `{"decision":"block","reason":…}`
//!     → 不停,把 `Stop hook feedback:\n<reason>`(reason 缺省取 exit 2 的 stderr)追加为 user 消息续跑;
//!     `stop_hook_active=true` 告诉脚本"这次停止是被你拦回来后的"。Claude Code 宿主侧不设上限,metacodes
//!     每 run 至多 `check_gate.MAX_STOP_HOOK_BLOCKS` 次(CheckGate.lean stop_blocks_bounded)。
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
//! 单条命令可写 `"timeout": <秒>`(对齐 Claude Code,上限 MAX_HOOK_TIMEOUT_S)覆盖 5s;事件总预算随之放宽为
//! max(HOOK_TOTAL_BUDGET_MS, Σ 本事件各命令超时)——跑测试套件的 Stop hook 才跑得完。
//!
//! **诚实登记——未做**:①PreToolUse 不支持 `permissionDecision:"allow"` 覆盖放行(只能 block 或落后续链);
//! ②PostToolUse block 不回喂模型 blocking error(只 advisory additionalContext);③`continue:false` 停整轮未建模;
//! ④UserPromptSubmit/SessionStart/SubagentStop/Notification 等事件仍未做(cc 有 ~30);⑤配置加载见 app.loadHooks。
//!
//! **坏配置可见**:解析仍跳过坏掉的部分(加载语义不变),但每一处跳过都记一条 `Problem`
//! (非法 JSON、`hooks` 非对象、未分发/拼错的事件名、entry/hook 形状、非 command 的 `type`、
//! 缺 `command`、越界 `timeout`、写在 metacodes 不读 hook 的 settings 文件里)——格式错的 hook
//! 不会报错,只会永不触发,所以要在作者看得见的地方说出来:`/hooks` 列出,启动横幅与 `/doctor` 计数。

const std = @import("std");
const process = @import("platform").process;
const shell_mod = @import("../core/shell.zig");
const log = @import("metacodes-base").util.log;
const util_json = @import("metacodes-base").util.json;
const util_time = @import("metacodes-base").util.time;

/// hook 子进程超时(ms)。超时 → killpg + 当作非阻塞错误(proceed)。防挂死 agent loop。
const HOOK_TIMEOUT_MS: i64 = 5000;

/// 单次 hook 事件(一条工具/一个生命周期点)的**总预算**:N 个匹配 hook 串行跑,无总预算时
/// 最坏 5N 秒钉死 agent_loop 主线程。预算耗尽 → 剩余 hook 跳过 + warn(与单 hook 超时同款
/// fail-open 语义;已产出的 block/updatedInput 保留)。
const HOOK_TOTAL_BUDGET_MS: i64 = 15_000;

/// 单条命令 `"timeout"`(秒)的上限:再长的 hook 应改成异步/后台,而不是钉住 agent loop。
pub const MAX_HOOK_TIMEOUT_S: u32 = 600;

/// Stop hook block 理由的字节上限(拼进模型可见的 feedback 消息)。
const MAX_REASON_BYTES: usize = 4096;

const AbortSignal = @import("metacodes-base").util.abort.AbortSignal;

/// 把 AbortSignal 包成 platform/process 的 opaque 回调(同 tools/common.zig AbortBridge)。
const AbortBridge = struct {
    fn poll(ctx: ?*const anyopaque) bool {
        const a: *const AbortSignal = @ptrCast(@alignCast(ctx.?));
        return a.isAborted();
    }
};

/// 事件级预算:deadline 制。remaining()<=0 时调用方跳过剩余 hook。
const Budget = struct {
    deadline_ms: i64,
    fn start() Budget {
        return .{ .deadline_ms = util_time.nowMs() + HOOK_TOTAL_BUDGET_MS };
    }
    /// 显式 `timeout` 放宽总预算:max(默认总预算, Σ 将要运行的命令各自超时)。
    /// `tool_name` = null 表示生命周期事件(全部 entry 都跑)。
    fn startFor(entries: []const HookEntry, tool_name: ?[]const u8) Budget {
        var total: i64 = 0;
        for (entries) |entry| {
            if (tool_name) |name| if (!matcherMatches(entry.matcher, name)) continue;
            for (0..entry.commands.len) |i| total += entry.timeoutMs(i);
        }
        return .{ .deadline_ms = util_time.nowMs() + @max(HOOK_TOTAL_BUDGET_MS, total) };
    }
    /// 单 hook 可用超时 = min(该命令上限, 预算余量)。<=0 = 预算耗尽。
    fn perHookTimeoutMs(self: *const Budget, command_timeout_ms: i64) i64 {
        const remaining = self.deadline_ms - util_time.nowMs();
        return @min(command_timeout_ms, remaining);
    }
};

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
    /// 与 `commands` 平行:每条命令的显式超时(ms),0 = 默认 HOOK_TIMEOUT_MS。可短于 commands
    /// (缺的按默认),手写字面量可省略。
    timeouts_ms: []const u32 = &.{},

    pub fn timeoutMs(self: HookEntry, index: usize) i64 {
        if (index < self.timeouts_ms.len and self.timeouts_ms[index] > 0) return self.timeouts_ms[index];
        return HOOK_TIMEOUT_MS;
    }
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
    pub fn entries(self: *const HookSet, event: Event) []const HookEntry {
        return switch (event) {
            .PreToolUse => self.pre_tool_use,
            .PostToolUse => self.post_tool_use,
            .Stop => self.stop,
            .PreCompact => self.pre_compact,
            .PostCompact => self.post_compact,
        };
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
    for (entries) |e| freeOneEntry(alloc, e);
    alloc.free(entries);
}

/// The hook events metacodes dispatches. `parse` reads exactly these keys, so
/// the dispatch list and the "not a hook event" diagnostic cannot drift apart.
pub const Event = enum {
    PreToolUse,
    PostToolUse,
    Stop,
    PreCompact,
    PostCompact,

    /// Tool events filter entries by `matcher`; lifecycle events run them all.
    fn filtersByMatcher(self: Event) bool {
        return self == .PreToolUse or self == .PostToolUse;
    }
};

const EVENT_COUNT = @typeInfo(Event).@"enum".fields.len;

/// "PreToolUse, PostToolUse, Stop, PreCompact, PostCompact".
pub const EVENT_LIST = blk: {
    var list: []const u8 = "";
    for (std.meta.fieldNames(Event), 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
    break :blk list;
};

/// Claude Code hook events (cc `HOOK_EVENTS`) metacodes does not dispatch. A
/// settings file written for Claude Code, or migrated from Codex or Harness²
/// (`SessionStart`, `UserPromptSubmit`), parses cleanly and then never fires;
/// knowing these names lets the diagnostic say "not run by metacodes" rather
/// than "not a hook event".
const UNDISPATCHED_EVENTS = [_][]const u8{
    "PostToolUseFailure", "Notification",     "UserPromptSubmit", "SessionStart",
    "SessionEnd",         "StopFailure",      "SubagentStart",    "SubagentStop",
    "PermissionRequest",  "PermissionDenied", "Setup",            "TeammateIdle",
    "TaskCreated",        "TaskCompleted",    "Elicitation",      "ElicitationResult",
    "ConfigChange",       "WorktreeCreate",   "WorktreeRemove",   "InstructionsLoaded",
    "CwdChanged",         "FileChanged",
};

/// What is wrong with a piece of hook configuration. Loading does not change
/// because of a problem - the broken piece is skipped as it always was - but
/// each skip is reported: a malformed hook never fails, it just never fires.
pub const ProblemKind = enum {
    /// The settings file is not valid JSON; none of its hooks load.
    invalid_json,
    /// `hooks` is not an object; none of the file's hooks load.
    hooks_not_object,
    /// A Claude Code event metacodes does not dispatch (`SessionStart`, ...).
    unsupported_event,
    /// A key that names no hook event at all (`PostToolUSE`).
    unknown_event,
    /// An event's value is not an array of entries; none of them load.
    event_not_array,
    /// An entry is not an object; skipped.
    entry_not_object,
    /// A tool event's `matcher` is not a string; the entry matches every tool.
    matcher_not_string,
    /// An entry's `hooks` is missing or not an array; the entry runs nothing.
    entry_hooks_not_array,
    /// An element of an entry's `hooks` is not an object; skipped.
    hook_not_object,
    /// `type` is not "command" (prompt, http and agent hooks are Claude Code's).
    unsupported_type,
    /// `command` is missing or not a string; the hook is skipped.
    missing_command,
    /// `timeout` is not a positive number of seconds, or exceeds the cap.
    invalid_timeout,
    /// A settings file metacodes reads, but not for hooks
    /// (`.claude/settings.local.json`, `--settings`), declares `hooks`.
    unread_settings_file,
};

pub const Problem = struct {
    kind: ProblemKind,
    /// The settings file.
    source: []const u8,
    /// JSON path of the offending value (`hooks.PreToolUse[0].hooks[1]`);
    /// "" when the problem concerns the whole file.
    location: []const u8,
    /// What is wrong and what happens because of it.
    message: []const u8,
};

/// Problems found while loading hooks: files in layer order; within a file,
/// undispatched event keys first, then each event in dispatch order. Owns every
/// string; the App keeps the latest load's report for `/hooks`.
pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    problems: std.ArrayList(Problem) = .empty,

    pub fn init(child: std.mem.Allocator) Diagnostics {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn items(self: *const Diagnostics) []const Problem {
        return self.problems.items;
    }

    /// The first problem of `kind`, if any.
    pub fn find(self: *const Diagnostics, kind: ProblemKind) ?*const Problem {
        for (self.problems.items) |*problem| {
            if (problem.kind == kind) return problem;
        }
        return null;
    }
};

/// Where parsing reports: one settings file of a Diagnostics.
const Reporter = struct {
    diag: *Diagnostics,
    source: []const u8,

    fn add(
        self: Reporter,
        kind: ProblemKind,
        comptime location_fmt: []const u8,
        location_args: anytype,
        comptime fmt: []const u8,
        args: anytype,
    ) error{OutOfMemory}!void {
        const a = self.diag.arena.allocator();
        try self.diag.problems.append(a, .{
            .kind = kind,
            .source = try a.dupe(u8, self.source),
            .location = try std.fmt.allocPrint(a, location_fmt, location_args),
            .message = try std.fmt.allocPrint(a, fmt, args),
        });
    }
};

/// One settings file's bytes, labelled for diagnostics.
pub const Layer = struct {
    path: []const u8,
    content: []const u8,
};

/// 从 settings JSON root 解析五类 hook 事件。无则返回空 set。
pub fn parse(alloc: std.mem.Allocator, root: std.json.Value) !HookSet {
    return parseReported(alloc, root, null);
}

fn parseReported(alloc: std.mem.Allocator, root: std.json.Value, rep: ?Reporter) !HookSet {
    var lists = [_][]const HookEntry{&.{}} ** EVENT_COUNT;
    errdefer for (lists) |list| freeEntries(alloc, list);

    if (root == .object) if (root.object.get("hooks")) |hooks_v| {
        if (hooks_v != .object) {
            if (rep) |r| try r.add(.hooks_not_object, "hooks", .{}, "`hooks` is not an object keyed by event name; none of this file's hooks load", .{});
        } else {
            if (rep) |r| try reportUnreadEvents(r, hooks_v.object);
            for (std.enums.values(Event)) |event| {
                lists[@intFromEnum(event)] = try parseEventArray(alloc, hooks_v.object.get(@tagName(event)), event, rep);
            }
        }
    };

    return HookSet{
        .pre_tool_use = lists[@intFromEnum(Event.PreToolUse)],
        .post_tool_use = lists[@intFromEnum(Event.PostToolUse)],
        .stop = lists[@intFromEnum(Event.Stop)],
        .pre_compact = lists[@intFromEnum(Event.PreCompact)],
        .post_compact = lists[@intFromEnum(Event.PostCompact)],
        .allocator = alloc,
    };
}

/// Every key of `hooks` that is not a dispatched event: its entries never run.
fn reportUnreadEvents(rep: Reporter, hooks: std.json.ObjectMap) error{OutOfMemory}!void {
    var it = hooks.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (std.meta.stringToEnum(Event, name) != null) continue;
        if (isUndispatchedEvent(name)) {
            try rep.add(.unsupported_event, "hooks.{s}", .{name}, "{s} is a Claude Code event metacodes does not run; these hooks never fire (metacodes runs {s})", .{ name, EVENT_LIST });
        } else if (eventIgnoringCase(name)) |event| {
            try rep.add(.unknown_event, "hooks.{s}", .{name}, "\"{s}\" is not a hook event (did you mean {s}?); these hooks never fire", .{ name, @tagName(event) });
        } else {
            try rep.add(.unknown_event, "hooks.{s}", .{name}, "\"{s}\" is not a hook event; these hooks never fire (metacodes runs {s})", .{ name, EVENT_LIST });
        }
    }
}

fn isUndispatchedEvent(name: []const u8) bool {
    for (UNDISPATCHED_EVENTS) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

fn eventIgnoringCase(name: []const u8) ?Event {
    for (std.enums.values(Event)) |event| {
        if (std.ascii.eqlIgnoreCase(@tagName(event), name)) return event;
    }
    return null;
}

/// metacodes loads hooks from `<project>/.claude/settings.json` and
/// `~/.claude/settings.json` only. A settings file it reads for permissions but
/// not for hooks (`.claude/settings.local.json`, `--settings`) that declares
/// `hooks` is reported instead of ignored silently. A file that is not valid
/// JSON is the settings loader's to report.
pub fn reportUnreadFile(
    alloc: std.mem.Allocator,
    diag: *Diagnostics,
    path: []const u8,
    content: []const u8,
) error{OutOfMemory}!void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.get("hooks") == null) return;
    const rep = Reporter{ .diag = diag, .source = path };
    try rep.add(.unread_settings_file, "hooks", .{}, "metacodes loads hooks only from <project>/.claude/settings.json and ~/.claude/settings.json; these hooks never run", .{});
}

/// 跨层合并:把多层 settings JSON 文本各自 parse 后,5 类事件的 entry 全部并入一个 HookSet
/// (project 与 user 的 hook 并存,不互相覆盖)。解析失败的层跳过。owned,调用方 deinit。
/// 这是 app.loadHooks 的可测 seam——避免"parse 支持但 loadHooks 漏合并某类事件"静默失效。
/// `diag` 非 null 时,每个被跳过的层/事件/entry/hook 都记一条 Problem(加载语义不变)。
pub fn parseAndMerge(alloc: std.mem.Allocator, layers: []const Layer, diag: ?*Diagnostics) !HookSet {
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
    for (layers) |layer| {
        const rep: ?Reporter = if (diag) |d| .{ .diag = d, .source = layer.path } else null;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, layer.content, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (rep) |r| try r.add(.invalid_json, "", .{}, "not valid JSON ({s}); none of this file's hooks load", .{@errorName(err)});
            continue;
        };
        defer parsed.deinit();
        var hs = try parseReported(alloc, parsed.value, rep);
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
    alloc.free(e.timeouts_ms);
}

/// 解析一个 hook 事件数组([{matcher, hooks:[{command}]}])为 HookEntry 切片。null/非数组 → 空。
/// 跳过的每一处经 `rep` 报告(非数组事件、非对象 entry、缺 hooks、缺 command……)。
fn parseEventArray(alloc: std.mem.Allocator, arr_v: ?std.json.Value, event: Event, rep: ?Reporter) ![]const HookEntry {
    var entries: std.ArrayList(HookEntry) = .empty;
    errdefer {
        for (entries.items) |e| freeOneEntry(alloc, e);
        entries.deinit(alloc);
    }
    const name = @tagName(event);
    const arr = arr_v orelse return entries.toOwnedSlice(alloc);
    if (arr != .array) {
        if (rep) |r| try r.add(.event_not_array, "hooks.{s}", .{name}, "not an array of {{\"matcher\", \"hooks\"}} entries; none of these hooks load", .{});
        return entries.toOwnedSlice(alloc);
    }
    for (arr.array.items, 0..) |item, ei| {
        if (item != .object) {
            if (rep) |r| try r.add(.entry_not_object, "hooks.{s}[{d}]", .{ name, ei }, "entry is not an object; skipped", .{});
            continue;
        }
        const matcher_v = item.object.get("matcher");
        if (rep) |r| if (matcher_v) |m| if (m != .string and event.filtersByMatcher()) {
            try r.add(.matcher_not_string, "hooks.{s}[{d}].matcher", .{ name, ei }, "matcher is not a string; the entry runs for every tool", .{});
        };
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
        var timeouts: std.ArrayList(u32) = .empty;
        defer timeouts.deinit(alloc);
        const hooks_v = item.object.get("hooks");
        if (hooks_v != null and hooks_v.? == .array) {
            for (hooks_v.?.array.items, 0..) |h, hi| {
                if (h != .object) {
                    if (rep) |r| try r.add(.hook_not_object, "hooks.{s}[{d}].hooks[{d}]", .{ name, ei, hi }, "hook is not an object; skipped", .{});
                    continue;
                }
                if (rep) |r| try reportHookShape(r, h.object, name, ei, hi);
                const cmd_v = h.object.get("command") orelse continue;
                if (cmd_v != .string) continue;
                try timeouts.append(alloc, parseTimeoutMs(h.object.get("timeout")));
                const cmd = try alloc.dupe(u8, cmd_v.string);
                cmds.append(alloc, cmd) catch |err| {
                    alloc.free(cmd);
                    return err;
                };
            }
        } else if (rep) |r| {
            const what = if (hooks_v == null) "missing" else "not an array";
            try r.add(.entry_hooks_not_array, "hooks.{s}[{d}].hooks", .{ name, ei }, "`hooks` is {s}; the entry runs nothing", .{what});
        }
        const owned_timeouts = try timeouts.toOwnedSlice(alloc);
        errdefer alloc.free(owned_timeouts);
        const owned_cmds = try cmds.toOwnedSlice(alloc);
        entries.append(alloc, .{ .matcher = matcher, .commands = owned_cmds, .timeouts_ms = owned_timeouts }) catch |err| {
            for (owned_cmds) |c| alloc.free(c);
            alloc.free(owned_cmds);
            return err;
        };
    }
    return entries.toOwnedSlice(alloc);
}

/// `type`, `command` and `timeout` of one hook object. One problem per field;
/// a hook skipped for its type is not reported again for its missing command.
fn reportHookShape(rep: Reporter, hook: std.json.ObjectMap, event: []const u8, entry: usize, index: usize) error{OutOfMemory}!void {
    const command_v = hook.get("command");
    const has_command = command_v != null and command_v.? == .string;
    if (hook.get("type")) |type_v| {
        if (type_v != .string or !std.mem.eql(u8, type_v.string, "command")) {
            const shown = if (type_v == .string) type_v.string else @tagName(type_v);
            const consequence = if (has_command) "its command still runs as a command hook" else "skipped";
            try rep.add(.unsupported_type, "hooks.{s}[{d}].hooks[{d}].type", .{ event, entry, index }, "type \"{s}\" is not supported (metacodes runs only \"command\" hooks); {s}", .{ shown, consequence });
            if (!has_command) return;
        }
    }
    if (command_v) |value| {
        if (value != .string) {
            try rep.add(.missing_command, "hooks.{s}[{d}].hooks[{d}].command", .{ event, entry, index }, "command is not a string; skipped", .{});
            return;
        }
    } else {
        try rep.add(.missing_command, "hooks.{s}[{d}].hooks[{d}]", .{ event, entry, index }, "no `command`; skipped", .{});
        return;
    }
    const timeout_v = hook.get("timeout") orelse return;
    const seconds: f64 = switch (timeout_v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => {
            try rep.add(.invalid_timeout, "hooks.{s}[{d}].hooks[{d}].timeout", .{ event, entry, index }, "timeout is not a number of seconds; the default {d} s applies", .{@divExact(HOOK_TIMEOUT_MS, 1000)});
            return;
        },
    };
    if (!(seconds > 0)) {
        try rep.add(.invalid_timeout, "hooks.{s}[{d}].hooks[{d}].timeout", .{ event, entry, index }, "timeout is not positive; the default {d} s applies", .{@divExact(HOOK_TIMEOUT_MS, 1000)});
    } else if (seconds > @as(f64, @floatFromInt(MAX_HOOK_TIMEOUT_S))) {
        try rep.add(.invalid_timeout, "hooks.{s}[{d}].hooks[{d}].timeout", .{ event, entry, index }, "timeout {d} s exceeds the {d} s cap; {d} s applies", .{ seconds, MAX_HOOK_TIMEOUT_S, MAX_HOOK_TIMEOUT_S });
    }
}

/// `"timeout"`(秒,Claude Code 语义):正数 → ms,封顶 MAX_HOOK_TIMEOUT_S;缺省/非法 → 0(默认)。
fn parseTimeoutMs(value: ?std.json.Value) u32 {
    const v = value orelse return 0;
    const seconds: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return 0,
    };
    if (!(seconds > 0)) return 0;
    const capped = @min(seconds, @as(f64, @floatFromInt(MAX_HOOK_TIMEOUT_S)));
    return @intFromFloat(capped * 1000.0);
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
    abort: ?*const AbortSignal,
) PreHookResult {
    return runPreToolUseFullWithBudget(set, alloc, tool_name, args, abort, Budget.startFor(set.pre_tool_use, tool_name));
}

/// 内部实现,budget 可注入(测试用过期 deadline 断言跳过语义,免真 sleep)。
fn runPreToolUseFullWithBudget(
    set: *const HookSet,
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
    abort: ?*const AbortSignal,
    budget: Budget,
) PreHookResult {
    var out = PreHookResult{};
    if (!set.hasPre()) return out;

    var stdin_builder: std.Io.Writer.Allocating = .init(alloc);
    defer stdin_builder.deinit();
    stdin_builder.writer.writeAll("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":") catch return out;
    util_json.writeJsonString(&stdin_builder.writer, tool_name) catch return out;
    stdin_builder.writer.writeAll(",\"tool_input\":") catch return out;
    stdin_builder.writer.writeAll(args) catch return out;
    stdin_builder.writer.writeByte('}') catch return out;
    const stdin_json = stdin_builder.toOwnedSlice() catch return out;
    defer alloc.free(stdin_json);

    for (set.pre_tool_use) |entry| {
        if (!matcherMatches(entry.matcher, tool_name)) continue;
        for (entry.commands, 0..) |cmd, ci| {
            const per_timeout = budget.perHookTimeoutMs(entry.timeoutMs(ci));
            if (per_timeout <= 0) {
                log.warn("hook", "PreToolUse total budget exhausted, skipping remaining hooks (tool={s})", .{tool_name});
                return out;
            }
            var r = runOneHookFull(alloc, cmd, stdin_json, per_timeout, abort, false);
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
    const r = runPreToolUseFull(set, alloc, tool_name, args, null);
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
    abort: ?*const AbortSignal,
) ?[]u8 {
    if (!set.hasPost()) return null;

    var stdin_builder: std.Io.Writer.Allocating = .init(alloc);
    defer stdin_builder.deinit();
    stdin_builder.writer.writeAll("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":") catch return null;
    util_json.writeJsonString(&stdin_builder.writer, tool_name) catch return null;
    stdin_builder.writer.writeAll(",\"tool_input\":") catch return null;
    stdin_builder.writer.writeAll(args) catch return null;
    stdin_builder.writer.writeAll(",\"tool_response\":") catch return null;
    stdin_builder.writer.writeAll(tool_response) catch return null;
    stdin_builder.writer.writeByte('}') catch return null;
    const stdin_json = stdin_builder.toOwnedSlice() catch return null;
    defer alloc.free(stdin_json);

    const budget = Budget.startFor(set.post_tool_use, tool_name);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    outer: for (set.post_tool_use) |entry| {
        if (!matcherMatches(entry.matcher, tool_name)) continue;
        for (entry.commands, 0..) |cmd, ci| {
            const per_timeout = budget.perHookTimeoutMs(entry.timeoutMs(ci));
            if (per_timeout <= 0) {
                log.warn("hook", "PostToolUse total budget exhausted, skipping remaining hooks (tool={s})", .{tool_name});
                break :outer;
            }
            const r = runOneHookFull(alloc, cmd, stdin_json, per_timeout, abort, false);
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
    const budget = Budget.startFor(entries, null);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    outer: for (entries) |entry| {
        for (entry.commands, 0..) |cmd, ci| {
            const per_timeout = budget.perHookTimeoutMs(entry.timeoutMs(ci));
            if (per_timeout <= 0) {
                log.warn("hook", "{s} total budget exhausted, skipping remaining hooks", .{event_name});
                break :outer;
            }
            const r = runOneHookFull(alloc, cmd, stdin_json, per_timeout, null, false);
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
    /// 仅 `capture_reason` 时填:block 的理由(stdout `reason` 字段,缺省取 exit 2 的 stderr)。owned。
    reason: ?[]u8 = null,
};

/// Stop hook 的合成结果:任一 hook block → blocked;各 block 的理由按序换行拼接(owned)。
pub const StopResult = struct {
    blocked: bool = false,
    reason: ?[]u8 = null,

    pub fn deinit(self: *StopResult, alloc: std.mem.Allocator) void {
        if (self.reason) |r| alloc.free(r);
        self.* = .{};
    }
};

/// Stop 事件 runner(唯一 gate 控制流的生命周期事件,语义对齐 Claude Code):所有 entry 的所有命令都跑
/// (side-effect hook 照常生效),收集 block 决策与理由。是否据此续跑、续几次由调用方的预算决定
/// (`check_gate.stopContinues`)。abort 可中断正在跑的 hook。
pub fn runStopHooks(
    entries: []const HookEntry,
    alloc: std.mem.Allocator,
    stdin_json: []const u8,
    abort: ?*const AbortSignal,
) StopResult {
    var out = StopResult{};
    if (entries.len == 0) return out;
    const budget = Budget.startFor(entries, null);
    var reasons: std.ArrayList(u8) = .empty;
    defer reasons.deinit(alloc);
    outer: for (entries) |entry| {
        for (entry.commands, 0..) |cmd, ci| {
            const per_timeout = budget.perHookTimeoutMs(entry.timeoutMs(ci));
            if (per_timeout <= 0) {
                log.warn("hook", "Stop total budget exhausted, skipping remaining hooks", .{});
                break :outer;
            }
            const r = runOneHookFull(alloc, cmd, stdin_json, per_timeout, abort, true);
            defer if (r.updated_input) |ui| alloc.free(ui);
            defer if (r.additional_context) |ac| alloc.free(ac);
            defer if (r.reason) |reason| alloc.free(reason);
            if (r.decision != .block) continue;
            out.blocked = true;
            log.info("hook", "Stop hook blocked the stop: {s}", .{cmd});
            if (r.reason) |reason| {
                if (reasons.items.len > 0) reasons.append(alloc, '\n') catch {};
                const room = MAX_REASON_BYTES -| reasons.items.len;
                reasons.appendSlice(alloc, utf8Prefix(reason, room)) catch {};
            }
        }
    }
    if (reasons.items.len > 0) out.reason = reasons.toOwnedSlice(alloc) catch null;
    return out;
}

/// `text` 的前 `cap` 字节,截在 UTF-8 码点边界上。
fn utf8Prefix(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    var end = cap;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// 跑单个 hook:`/bin/sh -c <cmd>`,把 stdin_json 写进它 stdin,读 exit code + stdout。
/// exit 2 → block;exit 0 → 看 stdout decision;其它 → proceed(非阻塞错误)。
/// stdout JSON 可含 updatedInput(改写工具输入)/ additionalContext(注入模型的补充上下文)。
fn runOneHookFull(alloc: std.mem.Allocator, cmd: []const u8, stdin_json: []const u8, timeout_ms: i64, abort: ?*const AbortSignal, capture_reason: bool) OneHookResult {
    // 可移植 shell(与 Bash 工具同款 core/shell 检测:POSIX sh -c / Windows PowerShell/cmd)。
    // 硬编码 /bin/sh 在 Windows 无此文件 → 所有 hook 静默 fail-open(实测 openai P0.2 红)。
    const sys_shell = shell_mod.detectDefault();
    const cmd_z = shell_mod.wrapCommand(alloc, sys_shell, cmd) catch return .{};
    defer alloc.free(cmd_z);
    var argv: [6]?[*:0]const u8 = undefined;
    shell_mod.deriveExecArgs(sys_shell, cmd_z.ptr, &argv);
    // 走可移植 platform/process.capture(POSIX fork / Windows CreateProcessW+git-bash):喂 stdin
    // JSON、捕 stdout(≤4KB)、继承 env(hook 需 $HOME/$PATH)。**timeout_partial 安全语义**:慢但已
    // 产 block 决策的 hook 超时也保留其部分输出判决,避免 fail-open 漏判(Linus/PM 红线)。cap 命中同理
    // 返部分。spawn/pipe/fork 失败 → fail-open(proceed)但记 warn(坏 hook 与"没 hook"须可区分)。
    const r = process.capture(argv[0..], alloc, .{
        .stdin_data = stdin_json,
        // Stop 的 exit-2 理由走 stderr(Claude Code 语义);其它事件不需要,保持丢弃。
        .want_stderr = capture_reason,
        .inherit_env = true,
        .timeout_ms = @intCast(timeout_ms), // 事件级预算裁剪(≤ HOOK_TIMEOUT_MS)
        .max_bytes = 4096,
        .timeout_partial = true,
        // abort 接线:hook 期间 Ctrl+C 可中断(此前 5N 秒窗口打不断)。
        .abort_ctx = if (abort) |a| @ptrCast(a) else null,
        .abort_poll = if (abort != null) AbortBridge.poll else null,
    }) catch {
        log.warn("hook", "spawn failed, skipping hook: {s}", .{cmd});
        return .{};
    };
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (r.timed_out) log.warn("hook", "hook 超时 {d}ms 被杀(保留部分输出判决): {s}", .{ timeout_ms, cmd });
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
    if (capture_reason and result.decision == .block) {
        if (util_json.extractStringField(stdout, "reason")) |raw| {
            result.reason = util_json.unescapeString(raw, alloc) catch null;
        }
        if (result.reason == null and exit_code == 2) {
            const trimmed = std.mem.trim(u8, r.stderr, " \t\r\n");
            if (trimmed.len > 0) result.reason = alloc.dupe(u8, trimmed) catch null;
        }
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"decision\":\"block\"}'; exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .block);
}

test "runPreToolUse: hook receives tool info on stdin" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"updatedInput\":{\"command\":\"ls -la\"}}'"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    const r = runPreToolUseFull(&set, alloc, "Bash", "{\"command\":\"ls\"}", null);
    defer if (r.modified_input) |mi| alloc.free(mi);
    try testing.expect(r.decision == .proceed);
    try testing.expect(r.modified_input != null);
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", r.modified_input.?);
}

test "Budget: perHookTimeoutMs = min(单hook上限, 余量);过期 deadline → <=0" {
    const fresh = Budget.start();
    const t = fresh.perHookTimeoutMs(HOOK_TIMEOUT_MS);
    try testing.expect(t > 0 and t <= HOOK_TIMEOUT_MS);
    const expired = Budget{ .deadline_ms = 0 }; // 单调钟远过去
    try testing.expect(expired.perHookTimeoutMs(HOOK_TIMEOUT_MS) <= 0);
}

test "runPreToolUseFull: 总预算耗尽 → 跳过剩余 hook(fail-open,不 spawn)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架
    const alloc = testing.allocator;
    // 会 block 的 hook(exit 2);预算已耗尽 → 根本不 spawn,决策保持 proceed。
    const cmds = [_][]const u8{"exit 2"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    const r = runPreToolUseFullWithBudget(&set, alloc, "Bash", "{}", null, .{ .deadline_ms = 0 });
    try testing.expect(r.decision == .proceed);
    try testing.expect(r.modified_input == null);
    // 对照:预算充足时同一 hook 正常 block(证明上面确因预算而跳)。
    const r2 = runPreToolUseFullWithBudget(&set, alloc, "Bash", "{}", null, Budget.start());
    try testing.expect(r2.decision == .block);
}

test "runPostToolUse: 收集 additionalContext" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"additionalContext\":\"lint passed\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &.{}, .post_tool_use = &entries, .allocator = alloc };
    const ctx = runPostToolUse(&set, alloc, "Write", "{\"file\":\"a\"}", "{\"ok\":true}", null);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"additionalContext\":\"x\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &.{}, .post_tool_use = &entries, .allocator = alloc };
    // matcher=Bash 不匹配 Write → null
    try testing.expect(runPostToolUse(&set, alloc, "Write", "{}", "{}", null) == null);
    // 完全无 post hook → null
    const empty = HookSet{ .pre_tool_use = &.{}, .allocator = alloc };
    try testing.expect(runPostToolUse(&empty, alloc, "Write", "{}", "{}", null) == null);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    const layers = [_]Layer{
        .{ .path = "/p/.claude/settings.json", .content = layer_project },
        .{ .path = "/u/.claude/settings.json", .content = layer_user },
    };
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    var set = try parseAndMerge(alloc, &layers, &diag);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 0), diag.items().len);
    try testing.expect(set.hasPre());
    try testing.expect(set.hasStop());
    try testing.expect(set.hasPreCompact());
    try testing.expect(set.hasPostCompact());
    try testing.expectEqualStrings("pre.sh", set.pre_tool_use[0].commands[0]);
    try testing.expectEqualStrings("mem.sh", set.stop[0].commands[0]);
    try testing.expectEqualStrings("snap.sh", set.pre_compact[0].commands[0]);
    try testing.expectEqualStrings("reinject.sh", set.post_compact[0].commands[0]);
}

test "parse: per-command timeout (seconds, capped) widens the event budget" {
    const src =
        \\{"hooks":{"Stop":[{"hooks":[
        \\  {"type":"command","command":"./slow-check.sh","timeout":120},
        \\  {"type":"command","command":"./mem.sh"},
        \\  {"type":"command","command":"./huge.sh","timeout":99999},
        \\  {"type":"command","command":"./bad.sh","timeout":"soon"}
        \\]}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();
    const entry = set.stop[0];
    try testing.expectEqual(@as(usize, 4), entry.commands.len);
    try testing.expectEqual(@as(i64, 120_000), entry.timeoutMs(0));
    try testing.expectEqual(HOOK_TIMEOUT_MS, entry.timeoutMs(1));
    try testing.expectEqual(@as(i64, MAX_HOOK_TIMEOUT_S) * 1000, entry.timeoutMs(2));
    try testing.expectEqual(HOOK_TIMEOUT_MS, entry.timeoutMs(3));
    // Σ = 120s + 5s + 600s + 5s > the 15s default event budget.
    const budget = Budget.startFor(set.stop, null);
    try testing.expect(budget.deadline_ms - util_time.nowMs() > 700_000);
    // A literal entry without timeouts keeps the 15s default budget.
    const cmds = [_][]const u8{"true"};
    const plain = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    try testing.expect(Budget.startFor(&plain, null).deadline_ms - util_time.nowMs() <= HOOK_TOTAL_BUDGET_MS);
}

test "runStopHooks: JSON decision block carries its reason" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX shell hook
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"cat >/dev/null; printf '{\"decision\":\"block\",\"reason\":\"2 tests failing\\\\nfix them\"}'"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    var r = runStopHooks(&entries, alloc, "{\"hook_event_name\":\"Stop\"}", null);
    defer r.deinit(alloc);
    try testing.expect(r.blocked);
    try testing.expectEqualStrings("2 tests failing\nfix them", r.reason.?);
}

test "runStopHooks: exit 2 uses stderr as the reason; exit 0 does not block" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX shell hook
    const alloc = testing.allocator;
    const blocking = [_][]const u8{"cat >/dev/null; echo 'lint failed' >&2; exit 2"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &blocking }};
    var r = runStopHooks(&entries, alloc, "{}", null);
    defer r.deinit(alloc);
    try testing.expect(r.blocked);
    try testing.expectEqualStrings("lint failed", r.reason.?);

    const quiet = [_][]const u8{"cat >/dev/null; echo 'side effect only'; exit 0"};
    const quiet_entries = [_]HookEntry{.{ .matcher = "*", .commands = &quiet }};
    var q = runStopHooks(&quiet_entries, alloc, "{}", null);
    defer q.deinit(alloc);
    try testing.expect(!q.blocked);
    try testing.expect(q.reason == null);
}

test "runStopHooks: every hook runs; a block without a reason has none" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX shell hook
    const alloc = testing.allocator;
    const cmds = [_][]const u8{
        "cat >/dev/null; exit 2",
        "cat >/dev/null; printf '{\"decision\":\"approve\",\"reason\":\"do not block\"}'",
    };
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    var r = runStopHooks(&entries, alloc, "{}", null);
    defer r.deinit(alloc);
    try testing.expect(r.blocked);
    try testing.expect(r.reason == null);
}

/// parseAndMerge over one file, reporting into `diag`.
fn parseOneReported(alloc: std.mem.Allocator, content: []const u8, diag: *Diagnostics) !HookSet {
    const layers = [_]Layer{.{ .path = "/p/.claude/settings.json", .content = content }};
    return parseAndMerge(alloc, &layers, diag);
}

test "diagnostics: a well-formed file reports nothing" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    var set = try parseOneReported(alloc,
        \\{"permissions":{"allow":[]},"hooks":{
        \\  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pre.sh","timeout":30}]}],
        \\  "PostToolUse":[{"hooks":[{"command":"post.sh"}]}],
        \\  "Stop":[{"matcher":7,"hooks":[{"type":"command","command":"stop.sh","timeout":0.5}]}],
        \\  "PreCompact":[],
        \\  "PostCompact":[{"hooks":[]}]
        \\}}
    , &diag);
    defer set.deinit();
    // A lifecycle entry's matcher is never consulted, so a non-string one is harmless.
    try testing.expectEqual(@as(usize, 0), diag.items().len);
    try testing.expectEqualStrings("pre.sh", set.pre_tool_use[0].commands[0]);
    try testing.expectEqualStrings("post.sh", set.post_tool_use[0].commands[0]);
    try testing.expectEqualStrings("stop.sh", set.stop[0].commands[0]);
}

test "diagnostics: invalid JSON names the file and keeps the other layers" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    const layers = [_]Layer{
        .{ .path = "/p/.claude/settings.json", .content = "{\"hooks\":{\"PreToolUse\":[}" },
        .{ .path = "/u/.claude/settings.json", .content = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"mem.sh\"}]}]}}" },
    };
    var set = try parseAndMerge(alloc, &layers, &diag);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 1), diag.items().len);
    const problem = diag.find(.invalid_json).?;
    try testing.expectEqualStrings("/p/.claude/settings.json", problem.source);
    try testing.expectEqualStrings("", problem.location);
    try testing.expectEqualStrings("mem.sh", set.stop[0].commands[0]);
    try testing.expect(!set.hasPre());
}

test "diagnostics: hooks that is not an object" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    var set = try parseOneReported(alloc, "{\"hooks\":[{\"PreToolUse\":[]}]}", &diag);
    defer set.deinit();
    try testing.expect(set.isEmpty());
    try testing.expectEqual(@as(usize, 1), diag.items().len);
    try testing.expectEqualStrings("hooks", diag.find(.hooks_not_object).?.location);
}

test "diagnostics: undispatched, misspelt and unknown events never fire and are named" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    var set = try parseOneReported(alloc,
        \\{"hooks":{
        \\  "SessionStart":[{"hooks":[{"type":"command","command":"boot.sh"}]}],
        \\  "PostToolUSE":[{"hooks":[{"type":"command","command":"lint.sh"}]}],
        \\  "OnSave":[],
        \\  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pre.sh"}]}]
        \\}}
    , &diag);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 3), diag.items().len);
    const items = diag.items();
    try testing.expectEqual(ProblemKind.unsupported_event, items[0].kind);
    try testing.expectEqualStrings("hooks.SessionStart", items[0].location);
    try testing.expectEqual(ProblemKind.unknown_event, items[1].kind);
    try testing.expect(std.mem.indexOf(u8, items[1].message, "did you mean PostToolUse?") != null);
    try testing.expectEqual(ProblemKind.unknown_event, items[2].kind);
    try testing.expectEqualStrings("hooks.OnSave", items[2].location);
    try testing.expect(std.mem.indexOf(u8, items[2].message, "did you mean") == null);
    // The dispatched event next to them loads as before; the others load nothing.
    try testing.expectEqual(@as(usize, 1), set.pre_tool_use.len);
    try testing.expectEqualStrings("pre.sh", set.pre_tool_use[0].commands[0]);
    try testing.expect(!set.hasPost());
}

test "diagnostics: entry and hook shapes are reported with their JSON path" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    var set = try parseOneReported(alloc,
        \\{"hooks":{
        \\  "Stop":{"hooks":[{"command":"never.sh"}]},
        \\  "PreToolUse":[
        \\    "Bash",
        \\    {"matcher":["Bash"],"hooks":[{"type":"command","command":"wide.sh"}]},
        \\    {"matcher":"Edit"},
        \\    {"matcher":"Write","hooks":{"command":"x.sh"}},
        \\    {"matcher":"Read","hooks":[
        \\      "ok.sh",
        \\      {"type":"prompt","prompt":"is this safe?"},
        \\      {"type":"http","command":"curl.sh"},
        \\      {"type":"command"},
        \\      {"type":"command","command":["a","b"]},
        \\      {"type":"command","command":"slow.sh","timeout":"soon"},
        \\      {"type":"command","command":"huge.sh","timeout":3600},
        \\      {"type":"command","command":"neg.sh","timeout":-1},
        \\      {"type":"command","command":"good.sh"}
        \\    ]}
        \\  ]
        \\}}
    , &diag);
    defer set.deinit();

    const Expect = struct { kind: ProblemKind, location: []const u8 };
    // Files in layer order; within a file, undispatched keys first, then the
    // events in dispatch order (PreToolUse before Stop), each in JSON order.
    const expected = [_]Expect{
        .{ .kind = .entry_not_object, .location = "hooks.PreToolUse[0]" },
        .{ .kind = .matcher_not_string, .location = "hooks.PreToolUse[1].matcher" },
        .{ .kind = .entry_hooks_not_array, .location = "hooks.PreToolUse[2].hooks" },
        .{ .kind = .entry_hooks_not_array, .location = "hooks.PreToolUse[3].hooks" },
        .{ .kind = .hook_not_object, .location = "hooks.PreToolUse[4].hooks[0]" },
        .{ .kind = .unsupported_type, .location = "hooks.PreToolUse[4].hooks[1].type" },
        .{ .kind = .unsupported_type, .location = "hooks.PreToolUse[4].hooks[2].type" },
        .{ .kind = .missing_command, .location = "hooks.PreToolUse[4].hooks[3]" },
        .{ .kind = .missing_command, .location = "hooks.PreToolUse[4].hooks[4].command" },
        .{ .kind = .invalid_timeout, .location = "hooks.PreToolUse[4].hooks[5].timeout" },
        .{ .kind = .invalid_timeout, .location = "hooks.PreToolUse[4].hooks[6].timeout" },
        .{ .kind = .invalid_timeout, .location = "hooks.PreToolUse[4].hooks[7].timeout" },
        .{ .kind = .event_not_array, .location = "hooks.Stop" },
    };
    const items = diag.items();
    try testing.expectEqual(expected.len, items.len);
    for (expected, items) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqualStrings(want.location, got.location);
        try testing.expectEqualStrings("/p/.claude/settings.json", got.source);
    }
    // The prompt hook (no command) is skipped; the http one still runs its command.
    try testing.expect(std.mem.endsWith(u8, items[5].message, "skipped"));
    try testing.expect(std.mem.endsWith(u8, items[6].message, "its command still runs as a command hook"));
    try testing.expect(std.mem.indexOf(u8, items[10].message, "600 s cap") != null);

    // Loading is what it always was: the reports change nothing.
    try testing.expect(!set.hasStop());
    try testing.expectEqual(@as(usize, 4), set.pre_tool_use.len);
    try testing.expectEqualStrings("*", set.pre_tool_use[0].matcher);
    try testing.expectEqualStrings("wide.sh", set.pre_tool_use[0].commands[0]);
    try testing.expectEqual(@as(usize, 0), set.pre_tool_use[1].commands.len);
    try testing.expectEqual(@as(usize, 0), set.pre_tool_use[2].commands.len);
    const read = set.pre_tool_use[3];
    try testing.expectEqualStrings("Read", read.matcher);
    const commands = [_][]const u8{ "curl.sh", "slow.sh", "huge.sh", "neg.sh", "good.sh" };
    try testing.expectEqual(commands.len, read.commands.len);
    for (commands, read.commands) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(HOOK_TIMEOUT_MS, read.timeoutMs(1));
    try testing.expectEqual(@as(i64, MAX_HOOK_TIMEOUT_S) * 1000, read.timeoutMs(2));
}

test "diagnostics: parse without a report and parseAndMerge without one agree" {
    const alloc = testing.allocator;
    const src = "{\"hooks\":{\"PreToolUse\":[\"x\",{\"matcher\":\"Bash\",\"hooks\":[{\"command\":\"pre.sh\"},{}]}],\"SessionStart\":[]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    var plain = try parse(alloc, parsed.value);
    defer plain.deinit();
    const layers = [_]Layer{.{ .path = "p", .content = src }};
    var merged = try parseAndMerge(alloc, &layers, null);
    defer merged.deinit();
    try testing.expectEqual(plain.pre_tool_use.len, merged.pre_tool_use.len);
    try testing.expectEqualStrings(plain.pre_tool_use[0].commands[0], merged.pre_tool_use[0].commands[0]);
    try testing.expectEqual(@as(usize, 1), merged.pre_tool_use[0].commands.len);
}

test "diagnostics: hooks in a file metacodes does not read for hooks" {
    const alloc = testing.allocator;
    var diag = Diagnostics.init(alloc);
    defer diag.deinit();
    try reportUnreadFile(alloc, &diag, "/p/.claude/settings.local.json", "{\"permissions\":{}}");
    try reportUnreadFile(alloc, &diag, "/p/.claude/settings.local.json", "not json");
    try testing.expectEqual(@as(usize, 0), diag.items().len);
    try reportUnreadFile(alloc, &diag, "/p/.claude/settings.local.json", "{\"hooks\":{\"Stop\":[]}}");
    try testing.expectEqual(@as(usize, 1), diag.items().len);
    try testing.expectEqual(ProblemKind.unread_settings_file, diag.items()[0].kind);
    try testing.expectEqualStrings("/p/.claude/settings.local.json", diag.items()[0].source);
}

test "diagnostics: OOM while reporting leaks nothing" {
    const src =
        \\{"hooks":{"SessionStart":[],"PreToolUse":["x",{"matcher":"Bash","hooks":[{"type":"prompt"},{"command":"a.sh","timeout":-1}]}]}}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, content: []const u8) !void {
            var diag = Diagnostics.init(alloc);
            defer diag.deinit();
            var set = try parseOneReported(alloc, content, &diag);
            set.deinit();
        }
    }.run, .{src});
}
