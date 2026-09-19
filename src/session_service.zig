//! SessionService（U2 S3）— session 状态 mutation 的**唯一中立入口**。
//!
//! 设计（doc/history/U2_SESSIONSERVICE_DESIGN.md）：
//!   - **只收敛 mutation，不收敛渲染**。exec(verb,args)→CommandOutcome{kind,ok,data}；
//!     kind 供 U4 派生 config-change 事件，data 是结构化载荷，**渲染归各 UI**（render(buf)
//!     是共享格式化助手，消除 loop/web 消息重复）。
//!   - **借 *App，不持 backend**（Linus 定）。所有方法只在 driver 线程调（TUI run 循环 /
//!     web cmdbox popFront 后）；App arena 非线程安全，绝不跨线程调。
//!   - **是所有 config 轴 mutation 的唯一写侧**（choke point）。会话轴 mutation
//!     (/resume /retry /goal) 显式排除，归 U5/U8（见 doc §1.5）。
//!   - U4 在 mutation 方法里接 event_sink（本模块不含 emit，只把 kind/data 结构就位）。
//!
//! **message 所有权（Linus 定）**：不用共享 scratch buffer（U4 会跨线程 emit）。
//!   CommandOutcome 只带 kind + data（值语义或借 App 稳定串，同步渲染安全）；render(buf)
//!   写进 **caller 提供的 per-call buf**（非 SessionService 共享），各 UI 自渲染。

const std = @import("std");
const app_mod = @import("app.zig");
const types = @import("types.zig");
const model_command = @import("repl/model_command.zig");
const theme_mod = @import("repl/tui/theme.zig");
const session_intent = @import("session_intent.zig");
const agent_loop = @import("core/agent_loop.zig");
const permission_mode = @import("permission/mode.zig");

pub const CommandOutcome = struct {
    kind: Kind,
    ok: bool,
    data: Data = .none,

    /// 变更类别。config 轴 mutation → U4 据此 emit；unhandled/noop/err 是控制信号。
    pub const Kind = enum {
        model_changed,
        mode_changed,
        dirs_changed,
        theme_changed,
        vim_changed,
        reasoning_changed,
        compacted,
        /// `!cmd` 已执行且输出追加进对话上下文（U11）。
        shell_ran,
        /// 非本命令面负责（纯展示命令 / 未知动词）→ caller 自渲染/兜底。
        unhandled,
        /// 已处理但无状态变更（如缺参提示）。
        noop,
        /// 处理出错（如 model 切换失败）。ok=false。
        err,
    };

    /// 结构化载荷（值语义或借 App 稳定串——同步渲染期 App 不变，安全）。
    pub const Data = union(enum) {
        none,
        model: []const u8, // 新 model（借 app.activeModel()）
        mode: types.PermissionMode,
        compact: app_mod.App.CompactResult,
        dir: []const u8, // 新增目录
        theme: struct { variant: theme_mod.Variant, persisted: bool },
        vim: bool,
        err_name: []const u8, // 错误名（借 @errorName，静态）
        text: []const u8, // 通用静态串（提示/回显）
    };

    /// 渲染人类可读消息到 **caller 的 buf**（per-call，非共享 scratch）。返回 buf 子切片或静态串。
    /// 各 UI（loop.zig / web execCommand）都调此 → 消息不再 loop/web 各写一份。
    pub fn render(self: CommandOutcome, buf: []u8) []const u8 {
        return switch (self.data) {
            .none => switch (self.kind) {
                .compacted => "compacted", // 理论不达（compacted 带 data）
                else => "",
            },
            .model => |m| std.fmt.bufPrint(buf, "model → {s}", .{m}) catch "model changed",
            .mode => |m| std.fmt.bufPrint(buf, "permission mode → {s}", .{@tagName(m)}) catch "mode changed",
            .compact => |c| std.fmt.bufPrint(buf, "compacted {d} messages ({d} → {d} active)", .{ c.dropped, c.before, c.after }) catch "compacted",
            .dir => |d| std.fmt.bufPrint(buf, "added directory: {s}", .{d}) catch "directory added",
            .theme => |t| std.fmt.bufPrint(buf, "theme → {s}", .{theme_mod.variantName(t.variant)}) catch "theme changed",
            .vim => |on| if (on) "editor mode → vim" else "editor mode → emacs",
            .err_name => |e| std.fmt.bufPrint(buf, "error: {s}", .{e}) catch "error",
            .text => |t| t,
        };
    }
};

pub const SessionService = struct {
    app: *app_mod.App,

    pub fn init(app: *app_mod.App) SessionService {
        return .{ .app = app };
    }

    /// 分派一条命令。verb=已去 `/` 的动词，args=其余（已 trim）。alloc 供需要临时分配的命令
    /// （setModel 收集候选做 provider 守卫）;driver 线程的临时分配器。
    /// 只处理 **config 轴 mutation**；纯展示命令 / 未知动词 / 缺参的展示子形式 → .unhandled，
    /// caller 自渲染（如 /model 无参列候选、/theme 无参列变体）。
    pub fn exec(self: *SessionService, alloc: std.mem.Allocator, verb: []const u8, args: []const u8) CommandOutcome {
        const eql = std.mem.eql;
        if (eql(u8, verb, "model")) {
            if (args.len == 0) return .{ .kind = .unhandled, .ok = true }; // 无参=列候选(展示)→caller
            return self.setModel(alloc, args);
        }
        if (eql(u8, verb, "mode")) {
            if (args.len == 0) return self.cyclePermMode();
            return self.setPermModeNamed(args);
        }
        if (eql(u8, verb, "effort")) {
            if (args.len == 0) return .{ .kind = .unhandled, .ok = true }; // 无参=展示当前→caller
            const effort = types.ReasoningEffort.parse(args) orelse {
                return .{ .kind = .err, .ok = false, .data = .{ .text = "invalid effort (none|minimal|low|medium|high|xhigh)" } };
            };
            return self.setReasoningEffort(effort);
        }
        if (eql(u8, verb, "compact")) return self.compact();
        if (eql(u8, verb, "add-dir")) {
            if (args.len == 0) return .{ .kind = .noop, .ok = false, .data = .{ .text = "usage: /add-dir <path>" } };
            return self.addDirectory(args);
        }
        if (eql(u8, verb, "theme")) {
            if (args.len == 0) return .{ .kind = .unhandled, .ok = true }; // 无参=列变体(展示)→caller
            return self.setTheme(args);
        }
        if (eql(u8, verb, "vim")) return self.toggleVim();
        return .{ .kind = .unhandled, .ok = true };
    }

    // ── 直接 mutation API（exec 内部调；也供非命令触发点直调，如 Shift+Tab/model-picker 键）──

    pub fn setModel(self: *SessionService, alloc: std.mem.Allocator, model_id: []const u8) CommandOutcome {
        // U11:档位/别名解析先于守卫——对齐 loop.zig /model use 路径。档位名
        // (low/mid/high;兼容 haiku/sonnet/opus)查当前 provider 档位表;未配置时
        // 按字面交给 provider 守卫拒绝(明确报错,不静默映射硬编码 ID,不无声 no-op)。
        const trimmed = std.mem.trim(u8, model_id, " \t");
        const resolved = @import("tools/agent.zig").resolveModelSelection(
            self.app.activeModelTiers(),
            trimmed,
            null,
        ).model orelse trimmed;
        // provider 守卫(对齐 loop.zig 旧 /model；顺带修 web /model 之前漏守卫)：收集当前
        // provider 的候选，拒绝跨 provider 的 model。候选 slice owned,元素借 catalog/BUILTINS。
        const candidates = model_command.collectCandidates(alloc, self.app.config.provider_kind, self.app.api_client.catalog.entries.items) catch {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "model catalog unavailable" } };
        };
        defer alloc.free(candidates);
        if (!model_command.canUseInCurrentProvider(self.app.config.provider_kind, candidates, resolved)) {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "model not available for current provider" } };
        }
        self.app.switchModel(resolved) catch |e| {
            return .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        self.app.persistLoginSelection();
        return .{ .kind = .model_changed, .ok = true, .data = .{ .model = self.app.activeModel() } };
    }

    /// `/mode <name>`:按名设权限模式(U11 新增;TUI 此前只有 Shift+Tab 轮换,web 只有
    /// cycle——两侧都补齐命名设置)。接受官方驼峰/下划线/历史名(parseStrict)及连字符形式。
    pub fn setPermModeNamed(self: *SessionService, name: []const u8) CommandOutcome {
        const mode = permission_mode.parseStrict(name) orelse blk: {
            if (name.len > 32) break :blk null;
            var buf: [32]u8 = undefined;
            for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
            break :blk permission_mode.parseStrict(buf[0..name.len]);
        } orelse {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "unknown mode (try: default, accept-edits, plan, auto, dont-ask, bypass)" } };
        };
        return self.setPermMode(mode);
    }

    pub fn cyclePermMode(self: *SessionService) CommandOutcome {
        self.app.cyclePermMode();
        return .{ .kind = .mode_changed, .ok = true, .data = .{ .mode = self.app.permMode() } };
    }

    pub fn setPermMode(self: *SessionService, mode: types.PermissionMode) CommandOutcome {
        // 经 App.setPermModeTracked:进/出 plan 的 plan_prev_mode 簿记与 Shift+Tab 同源
        // (直写 setMode 会漏簿记 → ExitPlanMode approve 恢复到 stale 的更宽模式)。
        self.app.setPermModeTracked(mode);
        return .{ .kind = .mode_changed, .ok = true, .data = .{ .mode = self.app.permMode() } };
    }

    pub fn compact(self: *SessionService) CommandOutcome {
        const r = self.app.compactWindow();
        return .{ .kind = .compacted, .ok = true, .data = .{ .compact = r } };
    }

    pub fn addDirectory(self: *SessionService, dir: []const u8) CommandOutcome {
        self.app.addDirectory(dir) catch |e| {
            return .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .dirs_changed, .ok = true, .data = .{ .dir = dir } };
    }

    pub fn setReasoningEffort(self: *SessionService, effort: types.ReasoningEffort) CommandOutcome {
        self.app.setReasoningEffort(effort) catch |e| {
            return .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .reasoning_changed, .ok = true, .data = .{ .text = effort.name() } };
    }

    pub fn setTheme(self: *SessionService, variant_name: []const u8) CommandOutcome {
        const variant = theme_mod.parseVariant(variant_name) orelse {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "unknown theme (try: auto, dark, light, mono)" } };
        };
        const persisted = self.app.setTheme(variant) catch |e| {
            // theme 已切，仅持久化失败 → 仍算 changed，但 ok=false 带错误
            return .{ .kind = .theme_changed, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .theme_changed, .ok = true, .data = .{ .theme = .{ .variant = variant, .persisted = persisted } } };
    }

    pub fn toggleVim(self: *SessionService) CommandOutcome {
        const on = self.app.toggleVim();
        return .{ .kind = .vim_changed, .ok = true, .data = .{ .vim = on } };
    }

    // ── U11 扩展方法(实现于文件下方;同一 driver 线程契约)──
    pub const dispatch = dispatchIntent;
    pub const submitPrompt = submitPromptImpl;
    pub const submitMacro = submitMacroImpl;
    pub const prepareRetry = prepareRetryImpl;
    pub const shellExec = shellExecImpl;
    const shellDispatch = shellDispatchImpl;
};

// ============================================================================
// U11(issue #3):canonical 输入管线 —— parse → dispatch → (outcome, run 计划)
// ============================================================================

/// prompt 宏(/commit /review /init):产品命令 = 预置 user prompt + 一轮 run。
/// 从 loop.zig 迁入——宏内容是业务,不是终端表达;三前端同一份。
pub const COMMIT_PROMPT =
    \\Please help create a git commit for the current working tree.
    \\
    \\Steps you should follow:
    \\  1) Run `git status` and `git diff --stat` (via the Bash tool) to see what changed.
    \\  2) Run `git log -n 5 --oneline` to match the project's commit style.
    \\  3) Draft a concise, conventional commit message summarising the WHY of the change.
    \\  4) Stage the intended files with `git add <path> ...` (do NOT use `git add -A`; skip secrets).
    \\  5) Run `git commit -m "..."`.
    \\  6) Show `git status` at the end to confirm.
    \\
    \\Do NOT push. If the diff is empty, say so and stop.
;

pub const REVIEW_PROMPT =
    \\Please review the current change set (unstaged + staged diff against HEAD).
    \\
    \\Steps:
    \\  1) Run `git diff HEAD` (via Bash) to see all pending changes.
    \\  2) Identify bugs, edge cases, missing error handling, broken invariants, style issues.
    \\  3) Group findings by severity: blockers → warnings → nits.
    \\  4) Quote the specific lines you are commenting on.
    \\  5) End with a one-line verdict: ready to merge / needs fixes.
;

pub const INIT_PROMPT =
    \\Please analyze this codebase and create a CLAUDE.md file in the repository root, which will be
    \\provided to future Claude Code sessions as project memory.
    \\
    \\What to do:
    \\  1) Explore the codebase (use Read/Glob/Grep/CodeMap and the Bash tool for `git`/build files) to
    \\     understand: build & test & lint commands, the high-level architecture, key modules and how they
    \\     fit together, and any non-obvious conventions.
    \\  2) If a CLAUDE.md already exists, improve it rather than overwrite — preserve anything still correct.
    \\  3) Also incorporate any existing rules files if present (e.g. .cursorrules, .github/copilot-instructions.md)
    \\     and useful pointers from README.
    \\  4) Write CLAUDE.md with the Write tool. Begin the file with this exact header:
    \\
    \\     # CLAUDE.md
    \\
    \\     This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
    \\
    \\Keep it concise and high-signal: commands a developer actually runs, the architecture a newcomer needs,
    \\and conventions that are NOT obvious from reading a single file. Do not pad it with restated source code.
;

/// run 计划:dispatch 完成全部 validate/prepare/commit(含 conversation append)后,
/// 告知宿主"现在提交一轮 run"。失败的 preflight 绝不产生 RunPlan,也绝不 append——
/// 保证 "failed preflight must not mutate Conversation or consume a run id"。
pub const RunPlan = struct {
    kind: Kind,
    pub const Kind = enum { user_prompt, injected_macro, retry };
};

/// dispatch 结果:结构化 outcome(渲染归各 UI)+ 可选 run 计划(宿主用自己的
/// backend/装饰器提交,经 buildRunOptions 的 canonical Options)。
pub const Dispatched = struct {
    outcome: CommandOutcome,
    run: ?RunPlan = null,
};

pub fn dispatchIntent(svc: *SessionService, alloc: std.mem.Allocator, intent: session_intent.InputIntent) Dispatched {
    switch (intent) {
        .empty => return .{ .outcome = .{ .kind = .noop, .ok = true } },
        .prompt => |text| return svc.submitPrompt(text),
        .shell => |cmd| return svc.shellDispatch(alloc, cmd),
        .skill => return .{ .outcome = .{ .kind = .unhandled, .ok = true } },
        .command => |c| {
            if (c.class == .local) return .{ .outcome = .{ .kind = .unhandled, .ok = true } };
            const eql = std.mem.eql;
            // 无参动词带参 → 拒绝(fail-closed):web/daemon 不静默吞参执行("/compact now"
            // 不是 /compact);TUI 链对这些动词只做精确匹配(带参落 skill 兜底),两侧一致
            // 地"带参不执行"。
            const argless = eql(u8, c.verb, "compact") or eql(u8, c.verb, "vim") or
                eql(u8, c.verb, "retry") or eql(u8, c.verb, "commit") or
                eql(u8, c.verb, "review") or eql(u8, c.verb, "init");
            if (argless and c.args.len > 0) {
                return .{ .outcome = .{ .kind = .err, .ok = false, .data = .{ .text = "command takes no arguments" } } };
            }
            if (eql(u8, c.verb, "commit")) return svc.submitMacro(COMMIT_PROMPT);
            if (eql(u8, c.verb, "review")) return svc.submitMacro(REVIEW_PROMPT);
            if (eql(u8, c.verb, "init")) return svc.submitMacro(INIT_PROMPT);
            if (eql(u8, c.verb, "retry")) return svc.prepareRetry();
            return .{ .outcome = svc.exec(alloc, c.verb, c.args) };
        },
    }
}

/// canonical 单行入口(web/daemon 用):raw → parse → dispatch。
/// TUI 在 intent 层分流(终端表达命令自渲染),但凡业务路径与此完全同源。
pub fn execLine(svc: *SessionService, alloc: std.mem.Allocator, raw: []const u8) Dispatched {
    return dispatchIntent(svc, alloc, session_intent.parse(raw));
}

pub const service_intent = session_intent; // re-export:宿主取 parse/Intent 类型

// ── SessionService 的 U11 扩展方法(与上方 config-mutation API 同线程契约)──

pub fn submitPromptImpl(self: *SessionService, text: []const u8) Dispatched {
    if (text.len == 0) return .{ .outcome = .{ .kind = .noop, .ok = true } };
    self.app.clearActiveSkill();
    self.app.conversation.appendText(.user, text) catch |e| {
        return .{ .outcome = .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } } };
    };
    return .{
        .outcome = .{ .kind = .noop, .ok = true },
        .run = .{ .kind = .user_prompt },
    };
}

pub fn submitMacroImpl(self: *SessionService, macro_prompt: []const u8) Dispatched {
    self.app.conversation.appendText(.user, macro_prompt) catch |e| {
        return .{ .outcome = .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } } };
    };
    return .{
        .outcome = .{ .kind = .noop, .ok = true },
        .run = .{ .kind = .injected_macro },
    };
}

/// /retry:回卷到最后一条 user 消息(丢弃其后所有回合)→ run 计划。
/// 无 user 消息 → err outcome,零 mutation。回卷本体在 Conversation.rollbackForRetry
/// (持快照锁 + bump mutation + compact_boundary 钳制——见其 doc)。
pub fn prepareRetryImpl(self: *SessionService) Dispatched {
    var idx: ?usize = null;
    var i = self.app.conversation.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (self.app.conversation.messages.items[i].role == .user) {
            idx = i;
            break;
        }
    }
    if (idx == null) {
        return .{ .outcome = .{ .kind = .err, .ok = false, .data = .{ .text = "no user message to retry" } } };
    }
    self.app.conversation.rollbackForRetry(idx.?);
    return .{
        .outcome = .{ .kind = .noop, .ok = true },
        .run = .{ .kind = .retry },
    };
}

/// `!cmd` 业务核:执行 Bash 工具(用户显式 ! = 授权)+ 把命令与输出追加进对话
/// 上下文。返回 owned 工具结果 JSON(caller free;TUI 据此渲染 stdout/stderr)。
pub fn shellExecImpl(self: *SessionService, alloc: std.mem.Allocator, command: []const u8) ![]u8 {
    const bash = @import("tools/bash.zig");
    var tool_ctx = @import("tools.zig").ToolContext{
        .allocator = alloc,
        .abort = &self.app.abort,
        .jobs = if (self.app.jobs) |*j| j else null,
        .agent_jobs = if (self.app.agent_jobs) |*aj| aj else null,
        .artifact_root = self.app.sessionDir() orelse "",
        // `!cmd` output lands in the same Conversation as any tool result, so
        // it is bounded by the same window-derived budget. Left at the field
        // default it would be capped at the 8KiB floor on a 200K-window model.
        .result_budget = .fromModel(self.app.provider().maxInputTokens()),
        .tool_result_metrics = &self.app.tool_result_metrics,
        .file_change_journal = &self.app.file_change_journal,
    };
    var args_buf: std.Io.Writer.Allocating = .init(alloc);
    defer args_buf.deinit();
    try args_buf.writer.writeAll("{\"command\":");
    try std.json.Stringify.encodeJsonString(command, .{}, &args_buf.writer);
    try args_buf.writer.writeByte('}');
    const args_json = try args_buf.toOwnedSlice();
    defer alloc.free(args_json);

    const result = try bash.execute(&tool_ctx, args_json);
    errdefer alloc.free(result);
    const ctx_msg = try std.fmt.allocPrint(alloc, "[shell] $ {s}\n{s}", .{ command, result });
    defer alloc.free(ctx_msg);
    try self.app.conversation.appendText(.user, ctx_msg);
    return result;
}

fn shellDispatchImpl(self: *SessionService, alloc: std.mem.Allocator, command: []const u8) Dispatched {
    if (command.len == 0) return .{ .outcome = .{ .kind = .noop, .ok = true } };
    const result = self.shellExec(alloc, command) catch |e| {
        return .{ .outcome = .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } } };
    };
    alloc.free(result);
    return .{ .outcome = .{ .kind = .shell_ran, .ok = true, .data = .{ .text = "shell command executed; output appended to context" } } };
}

/// **canonical run Options(U11)**:App 可导出字段的唯一装配点。此前 5 处前端各抄
/// 一份且互有缺漏(skill 触发的 run 缺 agents/mcp/skills_set/cron/file_change_journal
/// 等 7 字段;web 缺 lsp/swarm/background_request)——漂移在此收敛。
/// 宿主专属字段(ui_requester、run_control 三件套、eval gate/policy、max_turns、
/// spawn_tick_fn)由宿主在返回值上补;emit_tool_cards 默认开,WriterBackend 宿主可关。
pub fn buildRunOptions(app: *app_mod.App, synthetic_user_input: ?[]const u8) agent_loop.Options {
    return .{
        .session = app.session_id,
        .verbose = app.config.verbose,
        .abort = &app.abort,
        // background_request 是**宿主契约字段**(.backgrounded 停由宿主尾声消化 + 复位,
        // 目前只有主 REPL 实现,见 loop.zig 主 run 后的 .backgrounded 分支)——由该宿主自补。
        // 注入/skill/web 路径不接:接了而不消化,残留 flag 会让后续注入 run 在第 1 轮前
        // 静默 .backgrounded(宏 append 了却永不执行)。
        .read_state = &app.read_state,
        .edit_hl_cache = &app.edit_hl_cache,
        .lsp = app.lsp_service,
        .jobs = if (app.jobs) |*j| j else null,
        .job_notifications = if (app.jobs) |*j| j else null,
        .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
        .swarm = &app.swarm,
        .plan_prev_mode = &app.plan_prev_mode,
        .tasks = &app.tasks,
        .kg = if (app.kg) |*k| k else null,
        .kg_projects_dir = app.kg_projects_dir,
        .memdir_abs = app.memdir_abs,
        .api_client = app.anthropicClientOrNull(),
        .tool_defs = app.tool_defs,
        .system_prompt = app.system_prompt,
        .inject_user_context = app.user_context,
        .synthetic_user_input = synthetic_user_input,
        .dyn_registry = &app.dyn_registry,
        .host_services = app.hostServices(),
        .activated_tools = &app.activated_tools,
        .project_dir = app.project_dir_or_empty(),
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .model_tiers = app.activeModelTiers(),
        .model_switch_compact = app.pendingModelSwitchCompact(),
        .skills_set = &app.skills,
        .mcp_sessions = &app.mcp_sessions.items,
        .cron_registry = &app.cron_registry,
        .sandbox = app.sandboxPtr(),
        .cwd_abs = app.cwdAbs(),
        .additional_dirs = app.additionalDirs(),
        .home_dir = app.homeDir(),
        .artifact_root = app.sessionDir() orelse "",
        .metask_ledger_protocol = if (std.ascii.eqlIgnoreCase(app.config.provider_profile orelse "", "metask"))
            if (app.config.provider_kind == .openai) "openai_chat" else "anthropic_messages"
        else
            null,
        .tool_result_metrics = &app.tool_result_metrics,
        .file_change_journal = &app.file_change_journal,
        .plan_file_path = app.plan_file_path,
        .emit_tool_cards = true,
    };
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

test "SessionService.exec: 未知动词 → unhandled(caller 兜底)" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "doctor", "");
    try testing.expectEqual(CommandOutcome.Kind.unhandled, o.kind);
}

test "SessionService: vim toggle → vim_changed + render" {
    var app: app_mod.App = undefined;
    app.config = types.Config{};
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "vim", "");
    try testing.expectEqual(CommandOutcome.Kind.vim_changed, o.kind);
    try testing.expect(o.ok);
    try testing.expect(o.data.vim); // false→true
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("editor mode → vim", o.render(&buf));
}

test "SessionService: compact → compacted + 结构化 data + render" {
    const a = testing.allocator;
    var app: app_mod.App = undefined;
    app.conversation = @import("core/conversation.zig").Conversation.init(a);
    defer app.conversation.deinit();
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "compact", "");
    try testing.expectEqual(CommandOutcome.Kind.compacted, o.kind);
    try testing.expectEqual(@as(usize, 0), o.data.compact.dropped); // 空对话
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("compacted 0 messages (0 → 0 active)", o.render(&buf));
}

test "SessionService: add-dir 无参 → noop + usage 提示" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "add-dir", "");
    try testing.expectEqual(CommandOutcome.Kind.noop, o.kind);
    try testing.expect(!o.ok);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("usage: /add-dir <path>", o.render(&buf));
}

test "U11: /mode 命名设置(含连字符归一)与非法名" {
    var app: app_mod.App = undefined;
    app.config = types.Config{};
    app.permission_ctx = @import("permission.zig").createContext(.default, testing.allocator);
    app.plan_prev_mode = null;
    var svc = SessionService.init(&app);

    const o1 = svc.exec(testing.allocator, "mode", "plan");
    try testing.expectEqual(CommandOutcome.Kind.mode_changed, o1.kind);
    try testing.expectEqual(types.PermissionMode.plan, o1.data.mode);
    // 进 plan 记录前态(ExitPlanMode approve 据此恢复;命名路径与 Shift+Tab 同簿记)。
    try testing.expectEqual(types.PermissionMode.default, app.plan_prev_mode.?);

    const o2 = svc.exec(testing.allocator, "mode", "accept-edits");
    try testing.expectEqual(types.PermissionMode.accept_edits, o2.data.mode);
    // 离开 plan 清簿记:stale prev 绝不能残留(否则下次 approve 恢复到历史宽模式)。
    try testing.expect(app.plan_prev_mode == null);

    const o3 = svc.exec(testing.allocator, "mode", "nonsense");
    try testing.expectEqual(CommandOutcome.Kind.err, o3.kind);
    try testing.expect(!o3.ok);
    // 失败不改状态:仍是 accept_edits。
    try testing.expectEqual(types.PermissionMode.accept_edits, app.permission_ctx.modeValue());
}

test "U11: execLine 管线 —— prompt/宏 append + RunPlan;失败前零 mutation" {
    const a = testing.allocator;
    var app: app_mod.App = undefined;
    app.conversation = @import("core/conversation.zig").Conversation.init(a);
    defer app.conversation.deinit();
    // submitPrompt 走 clearActiveSkill:置零其触达的三处状态(最小 App 惯例)。
    app.active_skill = null;
    app.permission_ctx = @import("permission.zig").createContext(.default, a);
    app.session_id = @import("core/session_id.zig").SessionId.single;
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    app.skill_runtime = @import("skills/cli_adapter.zig").Runtime.init(a, io_rt.io());
    defer app.skill_runtime.deinit();
    var svc = SessionService.init(&app);

    // 普通 prompt → append + user_prompt 计划。
    const d1 = execLine(&svc, a, "hello world");
    try testing.expect(d1.run != null);
    try testing.expectEqual(RunPlan.Kind.user_prompt, d1.run.?.kind);
    try testing.expectEqual(@as(usize, 1), app.conversation.len());

    // /commit 宏 → append 宏文本 + injected_macro 计划。
    const d2 = execLine(&svc, a, "/commit");
    try testing.expectEqual(RunPlan.Kind.injected_macro, d2.run.?.kind);
    try testing.expectEqual(@as(usize, 2), app.conversation.len());

    // 展示类(/help)→ unhandled,零 run、零 mutation。
    const d3 = execLine(&svc, a, "/help");
    try testing.expectEqual(CommandOutcome.Kind.unhandled, d3.outcome.kind);
    try testing.expect(d3.run == null);
    try testing.expectEqual(@as(usize, 2), app.conversation.len());

    // 空提交 → noop。
    const d4 = execLine(&svc, a, "   ");
    try testing.expectEqual(CommandOutcome.Kind.noop, d4.outcome.kind);
    try testing.expect(d4.run == null);
}

test "U11: /retry 回卷到最后一条 user;空对话 err 零 mutation" {
    const a = testing.allocator;
    var app: app_mod.App = undefined;
    app.conversation = @import("core/conversation.zig").Conversation.init(a);
    defer app.conversation.deinit();
    var svc = SessionService.init(&app);

    // 空对话:err,无计划。
    const d0 = execLine(&svc, a, "/retry");
    try testing.expectEqual(CommandOutcome.Kind.err, d0.outcome.kind);
    try testing.expect(d0.run == null);

    try app.conversation.appendText(.user, "q1");
    try app.conversation.appendText(.assistant, "a1");
    try app.conversation.appendText(.user, "q2");
    try app.conversation.appendText(.assistant, "a2");
    const d1 = execLine(&svc, a, "/retry");
    try testing.expectEqual(RunPlan.Kind.retry, d1.run.?.kind);
    // 回卷:只剩 q1/a1/q2(q2 之后的 assistant 被丢弃)。
    try testing.expectEqual(@as(usize, 3), app.conversation.len());
}

test "U11: /retry 回卷穿过 compact_boundary → boundary 钳制,重发的 user 仍在活跃窗口" {
    // 回归(review round 1):auto-compact 可把 boundary 推到最后一条 user 之后;旧回卷不钳
    // boundary → activeStart 逐读 clamp 到 len,活跃窗口投影为**空**(请求只剩 summary,
    // 无 user 消息),其后追加的消息也隐形。修复后 boundary ≤ user_idx。
    const a = testing.allocator;
    var app: app_mod.App = undefined;
    app.conversation = @import("core/conversation.zig").Conversation.init(a);
    defer app.conversation.deinit();
    var svc = SessionService.init(&app);

    try app.conversation.appendText(.user, "q1");
    try app.conversation.appendText(.assistant, "a1");
    try app.conversation.appendText(.user, "q2"); // idx=2:要重发的最后一条 user
    try app.conversation.appendText(.assistant, "tool churn 1");
    try app.conversation.appendText(.assistant, "tool churn 2");
    // 模拟 auto-compact 把 boundary 推过最后一条 user(保留窗只剩工具回合的情形)。
    try app.conversation.restoreCompactState(4, "summary of q1..churn");

    const d = execLine(&svc, a, "/retry");
    try testing.expectEqual(RunPlan.Kind.retry, d.run.?.kind);
    try testing.expectEqual(@as(usize, 3), app.conversation.len());
    // boundary 钳到 user_idx=2:活跃窗口非空,且首条就是重发的 q2。
    const active = app.conversation.activeMessages();
    try testing.expect(active.len >= 1);
    try testing.expectEqualStrings("q2", active[0].blocks[0].text);
}

test "U11: 无参动词带参 → err(不静默吞参执行)" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const d = execLine(&svc, testing.allocator, "/compact now");
    try testing.expectEqual(CommandOutcome.Kind.err, d.outcome.kind);
    try testing.expect(d.run == null);
    const d2 = execLine(&svc, testing.allocator, "/retry please");
    try testing.expectEqual(CommandOutcome.Kind.err, d2.outcome.kind);
    try testing.expect(d2.run == null);
}

test "SessionService: model 无参 → unhandled(列候选归 caller)" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "model", "");
    try testing.expectEqual(CommandOutcome.Kind.unhandled, o.kind);
}
