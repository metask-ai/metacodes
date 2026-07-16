//! Task 工具(Agent 兼容别名):父 agent spawn 子 agent。
//!
//! 完整规范见 doc/SUBAGENT_DESIGN.md(第 5 节)。
//!
//! Schema(已实现):
//! - subagent_type:str (必需) — Explore / Plan / general-purpose / <custom name>
//! - description:str  (必需) — 3-5 词 UI 标签
//! - prompt:str       (必需) — 委托消息
//! - max_turns:int    (可选) — 单次 spawn 覆盖子 agent 最大轮数
//! - model:str        (可选) — 单次 spawn 覆盖 model(haiku/sonnet/opus/全名/inherit)
//! - run_in_background:bool (可选) — true 则不阻塞,spawn 后台线程(agent_job_registry)
//!   立即返回 {agent_job_id, status:running};用 TaskOutput 轮询增量输出 / TaskStop 终止。
//!
//! 未实现:
//! - isolation:"worktree"   — 需要真 git worktree spawn + 清理。P3。当前**不解析**,传了无效果。
//!   不要在 schema required 里声明它。
//!
//! 兼容:不带 subagent_type 但带 prompt 时,等同 subagent_type="general-purpose"(旧 Agent 工具语义)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const subagent = @import("../core/subagent.zig");
const util_json = @import("../util/json.zig");
const filter_mod = @import("../agents/filter.zig");

/// 最深嵌套层数。parent=0,孙=2;>= 这个值就拒绝 spawn。
/// 嵌套 subagent 是允许的(子 agent 也能调 Task),但深度有限保护栈。
/// pub:skills/tool.zig 的 context:fork 分支复用同一深度上限。
pub const MAX_AGENT_DEPTH: u8 = 3;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    // Precondition: depth guard
    if (ctx.agent_depth >= MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    const api_client = ctx.api_client orelse return error.AgentUnavailable;
    const tool_defs = ctx.tool_defs orelse return error.AgentUnavailable;
    const perm = ctx.permission_ctx orelse return error.AgentUnavailable;

    // 缺 prompt:返回**具名** error(对齐 Bash=MissingCommand / Grep=MissingPattern 约定),
    // 让 agent_loop 的 "{name} failed with MissingPrompt" 现场告诉模型缺哪个字段,
    // 而非笼统 MissingField(模型据此原地空参重试,见 e2e Task input={} 风暴)。
    const prompt_raw = util_json.extractStringField(args, "prompt") orelse return error.MissingPrompt;
    const prompt = try util_json.unescapeString(prompt_raw, ctx.allocator);
    defer ctx.allocator.free(prompt);

    // subagent_type:缺省 "general-purpose"(向后兼容旧 Agent 调用)
    const subagent_type_raw = util_json.extractStringField(args, "subagent_type") orelse "general-purpose";

    // 找 AgentDef(builtin + personal + project)
    var maybe_def: ?*const @import("../agents/def.zig").AgentDef = null;
    if (ctx.agents) |as| {
        maybe_def = as.find(subagent_type_raw);
    }

    // 没找到 — 用 general-purpose 兜底(但若 general-purpose 也没注册说明 AgentSet 未挂)
    var fallback_def: ?*const @import("../agents/def.zig").AgentDef = null;
    if (maybe_def == null and ctx.agents != null) {
        fallback_def = ctx.agents.?.find("general-purpose");
    }
    const def_opt = maybe_def orelse fallback_def;

    // 准备 effective tool_defs:若 def 存在,filter;否则用父全集
    var effective_tool_defs: []const @import("../json.zig").ToolDefinition = tool_defs;
    var filtered_owned: ?[]@import("../json.zig").ToolDefinition = null;
    defer if (filtered_owned) |f| ctx.allocator.free(f);
    if (def_opt) |d| {
        const filtered = try filter_mod.filterToolDefs(ctx.allocator, tool_defs, d);
        filtered_owned = filtered;
        effective_tool_defs = filtered;

        // 动态耦合:用 subagent 的 PromptContext 重写有 describe_fn 工具的描述。
        // 只读 agent(Explore/Plan)的 Bash 会去掉 Git 段 + 加只读提醒(对齐 cc Explore)。
        // 描述里引用其它工具的判断基于过滤后的工具集。
        const tools_mod = @import("../tools.zig");
        var names = try ctx.allocator.alloc([]const u8, filtered.len);
        defer ctx.allocator.free(names);
        for (filtered, 0..) |fd, i| names[i] = fd.name;
        const sub_prompt_ctx = tools_mod.PromptContext{
            .permission_mode = if (d.permission_mode) |m| mapPermissionMode(m) else .default,
            .enabled_tool_names = names,
            .agent_type = d.name,
            .include_git = true,
        };
        try tools_mod.redescribeForContext(ctx.allocator, filtered, &sub_prompt_ctx);
    }

    // per-spawn overrides
    const max_turns_input = parseUintField(args, "max_turns") orelse 0;
    const max_turns: u32 = blk: {
        if (max_turns_input > 0) break :blk @intCast(max_turns_input);
        if (def_opt) |d| break :blk d.max_turns;
        break :blk 20;
    };

    // permission mode override
    var perm_override: ?@import("../types.zig").PermissionMode = null;
    if (def_opt) |d| {
        if (d.permission_mode) |m| perm_override = mapPermissionMode(m);
    }

    // model override:Task 工具参数 > AgentDef.model > null(继承父)
    // "inherit" / 空 / 缺失 → null;其它视作 model 名(short alias 或全名)。
    const model_arg = util_json.extractStringField(args, "model");
    const model_override: ?[]const u8 = blk: {
        if (model_arg) |m| if (m.len > 0 and !std.mem.eql(u8, m, "inherit")) break :blk resolveModelAlias(m);
        if (def_opt) |d| if (d.model.len > 0 and !std.mem.eql(u8, d.model, "inherit")) break :blk resolveModelAlias(d.model);
        break :blk null;
    };

    // subagent system prompt:def + 环境 + CLAUDE.md/git(Explore/Plan 跳过) + skills preload
    const preload_mod = @import("../agents/preload.zig");
    var sys_prompt: []const u8 = "";
    var sys_prompt_owned: ?[]u8 = null;
    defer if (sys_prompt_owned) |p| ctx.allocator.free(p);
    if (def_opt) |d| {
        const sp = try preload_mod.buildSubagentContext(ctx.allocator, d, .{
            .project_dir = ctx.project_dir,
            .parent_model = ctx.parent_model,
            .session_id = ctx.session_id,
            .skills = ctx.skills,
            .skip_codebase_context = preload_mod.shouldSkipCodebaseContext(d.name),
            .abort = ctx.abort,
            // task#25:preload skill 注入 shell 走沙箱
            .sandbox = ctx.sandbox,
            .cwd_abs = ctx.cwd_abs,
            .home_dir = ctx.home_dir,
            .additional_dirs = ctx.additional_dirs,
        });
        sys_prompt_owned = sp;
        sys_prompt = sp;
    } else {
        sys_prompt = "You are a subagent. Complete the task and return a concise summary.\n";
    }

    // Swarm 分支:给了 `name` → spawn 一个持久 teammate(而非一次性 subagent)。
    // 对齐 cc AgentTool 的 name+team_name 分支,但 metacodes 一 lead 一队(team 隐含在
    // SwarmContext),故只需 name 触发。
    if (util_json.extractStringField(args, "name")) |name_raw| {
        const sw = ctx.swarm orelse return error.SwarmUnavailable;
        if (!sw.is_lead) return error.NotTeamLead; // teammate 不 spawn teammate(扁平 roster)
        if (!sw.hasTeam()) return error.NoActiveTeam;
        if (sw.teammates == null) return error.NoActiveTeam; // lead 无 registry(不该发生)
        const name = try util_json.unescapeString(name_raw, ctx.allocator);
        defer ctx.allocator.free(name);

        // SW6:进程外 backend(--teammate-mode process)→ fork+exec + worktree 隔离。
        if (sw.out_of_process) {
            const tp = @import("../swarm/teammate_process.zig");
            // worktree 路径 = {home}/.metacodes/worktrees/{team}-{name};repo = project_dir(git 根)。
            var name_buf: [64]u8 = undefined;
            const name_s = @import("../swarm/team.zig").sanitizeAgentName(name, &name_buf);
            var wt_buf: [std.fs.max_path_bytes]u8 = undefined;
            const wt: []const u8 = if (ctx.home_dir.len > 0 and ctx.project_dir.len > 0)
                (std.fmt.bufPrint(&wt_buf, "{s}/.metacodes/worktrees/{s}-{s}", .{ ctx.home_dir, sw.team_sanitized, name_s }) catch "")
            else
                "";
            const pid = tp.spawnTeammateProcess(sw, name, wt, if (wt.len > 0) "HEAD" else "", ctx.project_dir, ctx.abort, &tp.forkExecTeammate) catch |err| return err;
            return std.fmt.allocPrint(ctx.allocator, "{{\"teammate\":\"{s}\",\"pid\":{d},\"backend\":\"process\",\"status\":\"spawned\"}}", .{ name_s, pid });
        }

        const reg = &sw.teammates.?; // ctx *const 浅层,pointee 可变,无需 @constCast
        const entry = reg.spawnTeammate(.{
            .name = name,
            .team = sw.team_sanitized,
            .prompt = prompt,
            .system_prompt = sys_prompt,
            .tool_defs = effective_tool_defs,
            .permission_ctx = perm.scopedDerive(null), // U4:单 seam
            .agent_type = subagent_type_raw,
            .model_override = model_override,
            .perm_override = perm_override,
            .project_dir = ctx.project_dir,
            .cwd = ctx.cwd_abs,
            // task#12(Linus review):teammate 也透传父 sandbox(cwd 已传,补 sandbox/home/dirs)。
            .sandbox = ctx.sandbox,
            .home_dir = ctx.home_dir,
            .additional_dirs = ctx.additional_dirs,
            .dyn_registry = ctx.dyn_registry,
            .host_services = if (ctx.host_services) |hs| hs.skillOnly() else null,
            .kg = ctx.kg,
            .kg_projects_dir = ctx.kg_projects_dir,
        }) catch |err| return err;
        return std.fmt.allocPrint(
            ctx.allocator,
            "{{\"teammate\":\"{s}\",\"agent_id\":\"{s}\",\"status\":\"spawned\"}}",
            .{ entry.name, entry.agent_id },
        );
    }

    // run_in_background:true → 不阻塞,spawn 后台线程,立即返回 agent-job-id。
    // 后续用 TaskOutput(agent_job_id) 轮询增量输出 / TaskStop(agent_job_id) 终止。
    const bg = util_json.extractBoolField(args, "run_in_background") orelse false;
    if (bg) {
        const reg = ctx.agent_jobs orelse return error.AgentJobsUnavailable;
        const job_id = try reg.spawnBackground(.{
            .prompt = prompt,
            .system_prompt = sys_prompt,
            .tool_defs = effective_tool_defs,
            .permission_ctx = perm.scopedDerive(null), // U4:单 seam
            .agents = ctx.agents,
            .dyn_registry = ctx.dyn_registry,
            .skills = ctx.skills,
            .agent_depth = ctx.agent_depth + 1,
            .max_turns = max_turns,
            .model_override = model_override,
            .perm_override = perm_override,
            .project_dir = ctx.project_dir,
            .parent_model = ctx.parent_model,
            // desc = 纯描述(进度树行 `├ <desc>`);agent_type 单独传(标题按 type 分组)。
            // 无 description 时退回纯 type 作描述。
            .desc = util_json.extractStringField(args, "description") orelse subagent_type_raw,
            .agent_type = subagent_type_raw,
            // subagent 只接 skill 激活(skillOnly 投影:不碰父 worktree 栈/ToolSearch 集)。
            .host_services = if (ctx.host_services) |hs| hs.skillOnly() else null,
            // KG 透传:后台 subagent 参与任务 DAG(claim/闭合)。缺席=KgUnavailable
            // (真模型 e2e 实锤:同步路径修了、后台路径漏了——两条 SpawnOptions 构造)。
            .kg = ctx.kg,
            .kg_projects_dir = ctx.kg_projects_dir,
            // task#12(Linus review):后台 subagent 也透传父 sandbox(此前只同步路径修了,后台漏了)。
            .sandbox = ctx.sandbox,
            .cwd_abs = ctx.cwd_abs,
            .home_dir = ctx.home_dir,
            .additional_dirs = ctx.additional_dirs,
        });
        // U6 A2:父 session 广播"后台 agent 起了"(spawned)。后台 done 在 job 线程晚发,
        // 不在此站点(存量债 task#18:cross-thread done → 走 snapshotJobs 轮询或 web journal)。
        if (ctx.event_reporter) |r| r.agentLifecycle(.{ .spawned = .{
            .id = job_id,
            .agent_type = subagent_type_raw,
            .desc = util_json.extractStringField(args, "description") orelse subagent_type_raw,
            .foreground = false,
        } });
        return std.fmt.allocPrint(
            ctx.allocator,
            "{{\"agent_job_id\":\"{s}\",\"status\":\"running\",\"subagent_type\":\"{s}\"}}",
            .{ job_id, subagent_type_raw },
        );
    }

    // 同步路径:注册前台进度 entry(供进度树实时显示),并发安全靠 per-call client。
    // desc(纯描述,不带 "type: " 前缀)给进度树行;agent_type 给标题分组。
    const fg_desc = util_json.extractStringField(args, "description") orelse subagent_type_raw;
    var fg_entry: ?*@import("../core/agent_job_registry.zig").JobEntry = null;
    if (ctx.agent_jobs) |reg| {
        fg_entry = reg.registerForeground(subagent_type_raw, fg_desc, prompt);
    }
    // U6 A2:父 session 广播"前台 agent 起了"(spawned)。同步路径 → done 在本函数末发。
    if (ctx.event_reporter) |r| r.agentLifecycle(.{ .spawned = .{
        .id = if (fg_entry) |e| e.idSlice() else "",
        .agent_type = subagent_type_raw,
        .desc = fg_desc,
        .foreground = true,
    } });
    // **U6 F1(review MINOR)**:前台 spawn/run **失败**也必须发 done——否则 spawned 已发但
    // execute 提前 error 返回,SSE 客户端永久卡"running"(entry 又被下方 defer 移除,/state 也
    // 对不上)。errdefer 只在 error 路径 fire;成功路径由 done_emitted 抑制(防与正常 done 双发)。
    var done_emitted = false;
    errdefer if (!done_emitted) {
        if (ctx.event_reporter) |r| r.agentLifecycle(.{ .done = .{
            .id = if (fg_entry) |e| e.idSlice() else "",
            .state = "failed",
            .turns = 0,
            .tool_calls = 0,
            .tokens = 0,
        } });
    };
    // 父轮把 Region 1 进度树视为 transient:tool_result 返回后移除该前台 entry。
    defer if (fg_entry) |e| {
        if (ctx.agent_jobs) |reg| reg.removeForeground(e);
    };

    // per-call client:并发同步 Task(executeSlots 把多个 Task 放 worker 线程)各用独立
    // Client,绝不跨线程共享 ctx.api_client 的 http.Client。无 registry(headless)则退回
    // ctx.api_client(headless 无 TUI,串行可接受)。
    // P0.5:per-call **OwnedProvider**(据 parent provider_kind 造对应具体 client)→ 子 agent 继承
    // 父 provider(不再一律 Anthropic)。无 registry(headless)退回 ctx 的 Anthropic client。
    const pf = @import("../api/provider_factory.zig");
    var owned_prov: ?pf.OwnedProvider = null;
    defer if (owned_prov) |*o| o.deinit();
    if (ctx.agent_jobs) |reg| {
        // best-effort:makeProvider 仅在 OOM 时失败。失败 → 回退共享 ctx.provider(provider 语义
        // 仍正确,不会退回 Anthropic),但**丢掉 per-call 独立 client** → 并发 worker 会共享同一
        // http.Client(可接受的串行降级,非硬保证)。故 OOM 时 warn,别静默掩盖并发退化。
        owned_prov = reg.makeProvider() catch |err| blk: {
            @import("../util/log.zig").warn("agent", "makeProvider failed ({s}) — 退回共享 client(并发降级)", .{@errorName(err)});
            break :blk null;
        };
    }
    const call_prov: @import("../api/provider.zig").Provider =
        if (owned_prov) |*o| o.provider() else (ctx.provider orelse api_client.provider());
    const call_anthropic: ?*@import("../client.zig").Client =
        if (owned_prov) |*o| o.anthropicClient() else api_client;

    // L1:前台进度/token/流式 text 走 JobEntry backend(取代旧 progress_reporter/usage_sink
    // 两通道)。无 fg_entry(无 registry/headless)→ null-writer backend(丢弃流式输出)。
    // 单一 spawnAgentSink 调用 + 单一 SpawnOptions(避免两份字段漂移)。
    var null_wb = @import("../core/writer_backend.zig").WriterBackend.initNull();
    const be: @import("../core/protocol/ui_backend.zig").UiBackend =
        if (fg_entry) |e| e.backend() else null_wb.backend();
    // **allocator 一致铁律**:spawnAgentSink 的 allocator 必须与 call_prov 的 allocator 一致 ——
    // provider 的流式事件(tool_use/text)所有权转移进 subagent 的 agent_loop,不一致 → Invalid free
    // (后台路径已用 GPA panic 实测过同款机制)。owned_prov 用 c_allocator(见 registry.makeProvider),
    // 故这里也用 c_allocator;它还顺带线程安全(并发前台 Task 在 worker 线程跑)。final_text 后面
    // serializeString 拷进 ctx.allocator 的输出 JSON(拷贝非转移),result.deinit 用 c_allocator 释放,一致。
    const call_allocator: std.mem.Allocator = if (owned_prov != null) std.heap.c_allocator else ctx.allocator;
    const result = try subagent.spawnAgentSink(
        call_allocator,
        call_prov,
        call_anthropic,
        tool_defs, // 父 tool_defs (override 通过 SpawnOptions 传)
        perm,
        ctx.abort,
        prompt,
        .{
            .max_turns = max_turns,
            .system_prompt = sys_prompt,
            .agent_depth = ctx.agent_depth + 1,
            .dyn_registry = ctx.dyn_registry,
            .tool_defs_override = if (filtered_owned != null) effective_tool_defs else null,
            .permission_mode_override = perm_override,
            .model_override = model_override,
            .host_services = if (ctx.host_services) |hs| hs.skillOnly() else null,
            .project_dir = ctx.project_dir,
            .kg = ctx.kg,
            .kg_projects_dir = ctx.kg_projects_dir,
            // task#12:透传父 sandbox 到 subagent(Bash 继承,不给绕过后门)。
            .sandbox = ctx.sandbox,
            .cwd_abs = ctx.cwd_abs,
            .home_dir = ctx.home_dir,
            .additional_dirs = ctx.additional_dirs,
        },
        &be,
    );
    defer result.deinit();

    // 标记前台 entry 完成(终值),removeForeground 由上面的 defer 兜底。
    var fg_tokens: u64 = 0;
    var fg_elapsed_ms: u64 = 0;
    if (fg_entry) |e| {
        if (ctx.agent_jobs) |reg| reg.finishForeground(e, result.turns, result.tool_calls, result.stop_reason);
        // 读 tokens + 算耗时(entry 仍有效,removeForeground 在函数返回时才跑)。
        e.lockPublic();
        fg_tokens = e.tokens;
        const start = e.started_ms;
        e.unlockPublic();
        const now = @import("../util/time.zig").nowMs();
        fg_elapsed_ms = @intCast(@max(now - start, 0));
    }

    // U6 A2:前台 agent 结束 → done(同步路径,本站点即终态,threading 与 spawned 同)。
    if (ctx.event_reporter) |r| r.agentLifecycle(.{ .done = .{
        .id = if (fg_entry) |e| e.idSlice() else "",
        .state = @tagName(result.stop_reason),
        .turns = result.turns,
        .tool_calls = result.tool_calls,
        .tokens = fg_tokens,
    } });
    done_emitted = true; // U6 F1:正常 done 已发 → 抑制 errdefer 的失败兜底 done(防双发)

    // 输出 JSON
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"subagent_type\":");
    try util_json.serializeString(if (def_opt) |d| d.name else "general-purpose", &out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"final_text\":");
    try util_json.serializeString(result.final_text, &out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"stop_reason\":\"");
    try out.appendSlice(ctx.allocator, @tagName(result.stop_reason));
    // tokens + elapsed_ms:完成态塌缩卡 `Done (N tool uses · X tokens · Ns)` 渲染用。
    const tail = try std.fmt.allocPrint(
        ctx.allocator,
        "\",\"turns\":{d},\"tool_calls\":{d},\"tokens\":{d},\"elapsed_ms\":{d}}}",
        .{ result.turns, result.tool_calls, fg_tokens, fg_elapsed_ms },
    );
    defer ctx.allocator.free(tail);
    try out.appendSlice(ctx.allocator, tail);
    return try out.toOwnedSlice(ctx.allocator);
}

fn mapPermissionMode(mode: @import("../agents/def.zig").PermissionMode) @import("../types.zig").PermissionMode {
    return switch (mode) {
        .default => .default,
        .acceptEdits => .accept_edits,
        .auto => .auto,
        .dontAsk => .dont_ask,
        .bypassPermissions => .bypass_permissions,
        .plan => .plan,
    };
}

/// 短名 → 具体 model ID。"haiku" → "claude-3-5-haiku-20241022",
/// "sonnet"/"opus" 同理映射到当前主力版本。已是全名(含 "claude-")则原样返回。
/// 留 borrowed 引用,不分配(借 def.model 或 args 的字符串内存)。
/// pub:skills/tool.zig 的 context:fork 分支解析 skill.model 字段时复用。
pub fn resolveModelAlias(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "claude-")) return name; // 已是全名
    if (std.mem.eql(u8, name, "haiku")) return "claude-3-5-haiku-20241022";
    if (std.mem.eql(u8, name, "sonnet")) return "claude-sonnet-4-20250514";
    if (std.mem.eql(u8, name, "opus")) return "claude-opus-4-1-20250805";
    return name; // 未知短名:原样传给 API(由 API 判错)
}

fn parseUintField(data: []const u8, field: []const u8) ?u64 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var p = idx + pat.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    var e = p;
    while (e < data.len and data[e] >= '0' and data[e] <= '9') : (e += 1) {}
    if (e == p) return null;
    return std.fmt.parseInt(u64, data[p..e], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Task without deps returns AgentUnavailable" {
    const ctx = ToolContext{ .allocator = testing.allocator };
    try testing.expectError(error.AgentUnavailable, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "Task depth guard rejects at MAX" {
    const ctx = ToolContext{
        .allocator = testing.allocator,
        .agent_depth = MAX_AGENT_DEPTH,
    };
    try testing.expectError(error.AgentDepthExceeded, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "parseUintField extracts max_turns" {
    try testing.expect(parseUintField("{\"max_turns\":42}", "max_turns").? == 42);
    try testing.expect(parseUintField("{\"max_turns\": 7 }", "max_turns").? == 7);
    try testing.expect(parseUintField("{}", "max_turns") == null);
}
