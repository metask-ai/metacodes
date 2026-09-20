//! 后台 subagent 作业注册表(AgentJobRegistry)。
//!
//! 与 job_registry.zig(Bash 后台,fork 进程模型)的关键区别:
//! 后台 subagent 是**同进程线程**模型——每个 job 在自己的 std.Thread 里跑
//! subagent.spawnAgent(网络 + 工具循环),不是 fork 子进程。
//!
//! 设计:
//! - **每 job 独立 Client + 独立 std.Io.Threaded**:Client 构造 O(1) 无共享,
//!   彻底规避多线程共享 App.api_client 的 http.Client 竞争。
//! - **每 job 独立 AbortSignal**:TaskStop / deinit 时 abort 打断在途网络读。
//! - **entries 存 *JobEntry(指针)**:ArrayList grow 会 realloc;若存值数组,
//!   后台线程持有的 *JobEntry 会悬挂(UAF)。存指针 + 堆分配地址稳定规避。
//! - **JobEntry.mutex(pthread)** 保护 status/output_buf/final_text 等线程边写主线程边读。
//! - **增量输出**:线程把 subagent 流式 text 落 output_buf(持锁 append),
//!   TaskOutput 按 since_byte 增量读(对齐 BashOutput 的轮询心智)。
//!
//! deinit 铁律(UAF 防护):drain 循环 { abort 全部 running → join 全部线程 } 直到无
//! running,再单线程 free。join 完成是"线程不再碰 entry"的唯一可靠 happens-before。
//! App.deinit 必须在共享 allocator 释放之前调本 deinit。

const std = @import("std");
const rng = @import("platform").rng;
const sync = @import("platform").sync;
const client_mod = @import("../client.zig");
const pf = @import("../api/provider_factory.zig");
const dialect_mod = @import("../api/dialect.zig");
const types_mod = @import("../types.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const subagent = @import("subagent.zig");
const agent_loop = @import("agent_loop.zig");
const Conversation = @import("conversation.zig").Conversation;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const util_time = @import("../util/time.zig");
const utf8 = @import("../util/utf8.zig");
const log = @import("../util/log.zig");
const AgentSet = @import("../agents/set.zig").AgentSet;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const SkillSet = @import("../skills/skill.zig").SkillSet;
const ActiveSkillState = @import("../skills/active.zig").ActiveSkillState;
const SessionId = @import("session_id.zig").SessionId;

/// 同时存在的后台 job 上限。防线程爆炸 + API 速率打爆。
pub const MAX_BG_JOBS: usize = 8;
const OUTPUT_CAP: usize = 512 * 1024;

pub const JobStatus = enum { running, done, failed, killed };

/// 后台 subagent 的一个作业。堆分配,地址稳定(线程与主线程共享 *JobEntry)。
pub const JobEntry = struct {
    id: [16]u8 = undefined, // "agent_" + 8 hex + NUL pad
    id_len: u8 = 0,
    /// 保护下列 status/output_buf/final_text/stop_reason/turns/tool_calls/err_name。
    mutex: sync.Mutex = .{},
    /// TaskOutput long-poll wakeup. Signaled when observable output grows or
    /// the job publishes a terminal status, so callers do not busy-poll the
    /// same `running` snapshot into the zero-gain breaker.
    condition: sync.Condition = .{},
    status: JobStatus = .running,
    /// **task#18**:done lifecycle 事件是否已发。job 线程只置 status(不能安全用父栈 trampoline
    /// reporter);主/driver 线程 drainNewlyDone reap 时据此一次性发 done,避免重复。锁内读写。
    done_emitted: bool = false,
    /// 增量输出缓冲。线程边跑边 append(持锁);TaskOutput since_byte 增量读。
    output_buf: std.ArrayList(u8) = .empty,
    output_truncated: bool = false,
    utf8_pending: [4]u8 = undefined,
    utf8_pending_len: u8 = 0,
    final_text: ?[]u8 = null, // owned by allocator;done 后非空
    stop_reason: ?agent_loop.StopReason = null,
    turns: u32 = 0,
    tool_calls: u32 = 0,
    /// 实时进度(subagent agent_loop 跑动时持锁更新,供 TUI agent 进度树显示)。
    /// current_turn:当前轮(1-based);current_tool:当前/最近执行的工具名(定长拷贝);
    /// current_tool_input:该工具的原始 input JSON 快照(定长截断,供动作行渲染参数预览)。
    /// **注意:job 结束(done/failed/killed)后 current_tool/input 是 stale 的**——
    /// 保留的是最后一个工具,不清空(对齐 cc 持续显示最近动作)。渲染方必须先查 status
    /// == .running 再用 current_tool,否则会显示已结束 job 的鬼影动作(见 agent_tree)。
    current_turn: u32 = 0,
    current_tool: [32]u8 = undefined,
    current_tool_len: u8 = 0,
    current_tool_input: [96]u8 = undefined,
    current_tool_input_len: u8 = 0,
    err_name: ?[]const u8 = null, // @errorName 静态字符串,不 own
    thread: ?std.Thread = null,
    abort: AbortSignal = undefined,
    /// worker 线程在发第一个请求前登记的 provider 视图(借用 worker 栈上的 OwnedProvider);
    /// abortAllRunning 据此 cancel 在飞请求(shutdown 连接叫醒卡住的读)。worker 退出前
    /// 在 entry 锁内清空,cancel 与清空串行,不会指向已 deinit 的 client。
    cancel_provider: ?@import("../api/provider.zig").Provider = null,
    allocator: std.mem.Allocator,
    /// Immutable parent session for routing output/events after the foreground
    /// session rotates or resumes another transcript.
    session: SessionId = .single,
    started_ms: util_time.Millis = 0,
    desc_preview: []u8 = &.{}, // owned
    /// 前台(同步)job 标记。foreground job **无 thread**(跑在主线程/并发批的 worker 上,
    /// 由 agent.zig 同步 spawn 驱动),其进度经 progressTrampoline 写入,供进度树渲染。
    /// 与后台 job 共用 entries/snapshot/agent_tree 渲染链;区别仅在生命周期(transient,
    /// 父轮结束即 removeForeground)与释放路径(无 thread → 不 join)。
    foreground: bool = false,
    /// Long-poll readers holding this background entry. Protected by the
    /// registry list mutex so teardown can wait before freeing the entry.
    readers: usize = 0,
    /// agent 类型(如 "Explore"),从 desc 拆出。进度树标题按 type 分组计数需要。owned。
    agent_type: []u8 = &.{},
    /// 累计 token(input+output,经 usage_sink 持锁累加)。进度树行 `· X tokens` 用。
    tokens: u64 = 0,
    /// 该 agent 收到的 prompt 预览(spawn 时 dup,截断)。区域2 查看 transcript 顶部显示。owned。
    prompt_preview: []u8 = &.{},
    /// AgentDef.isolation=worktree 的稳定路径副本；后台线程释放 Worktree 自有路径后仍可查询。
    worktree_path: []u8 = &.{},
    /// null=仍在运行/无 worktree；终态 true=有变化保留，false=干净已移除。
    worktree_kept: ?bool = null,
    /// null=running/no worktree; false=cleanup failed or only partially completed.
    worktree_cleanup_complete: ?bool = null,
    /// 该 agent 的可读 transcript(progress trampoline 持锁 append `⎿ Tool: arg` 行)。
    /// 区域2 Enter 查看 agent 上下文用。owned ArrayList。
    transcript: std.ArrayList(u8) = .empty,

    pub fn idSlice(self: *const JobEntry) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn lockPublic(self: *JobEntry) void {
        _ = self.mutex.lock();
    }
    pub fn unlockPublic(self: *JobEntry) void {
        _ = self.mutex.unlock();
    }

    fn lock(self: *JobEntry) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *JobEntry) void {
        _ = self.mutex.unlock();
    }

    /// 线程持锁写一段流式输出。
    fn appendOutput(self: *JobEntry, bytes: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.output_truncated) {
            self.condition.broadcast();
            return;
        }
        if (self.utf8_pending_len > 0) {
            const pending = self.utf8_pending[0..self.utf8_pending_len];
            if (pending.len > OUTPUT_CAP -| self.output_buf.items.len) {
                self.output_truncated = true;
                self.utf8_pending_len = 0;
                self.condition.broadcast();
                return;
            }
            self.output_buf.appendSlice(self.allocator, pending) catch {
                self.output_truncated = true;
                self.utf8_pending_len = 0;
                self.condition.broadcast();
                return;
            };
            self.utf8_pending_len = 0;
        }
        const room = OUTPUT_CAP -| self.output_buf.items.len;
        const take = @min(bytes.len, room);
        self.output_buf.appendSlice(self.allocator, bytes[0..take]) catch {
            self.output_truncated = true;
            self.condition.broadcast();
            return;
        };
        if (take < bytes.len) self.output_truncated = true;
        if (utf8.incompleteTailStart(self.output_buf.items)) |start| {
            const tail_len = self.output_buf.items.len - start;
            @memcpy(self.utf8_pending[0..tail_len], self.output_buf.items[start..]);
            self.utf8_pending_len = @intCast(tail_len);
            self.output_buf.items.len = start;
        }
        self.condition.broadcast();
    }

    fn flushPendingOutput(self: *JobEntry) void {
        if (self.utf8_pending_len == 0) return;
        // Keep the source-byte cursor contract at stream end.  The pending
        // bytes are an incomplete source sequence, so append them as-is and
        // let the canonical JSON writer render U+FFFD.  Appending the
        // three-byte replacement here would make output_size_bytes and
        // output_next_offset jump by a different unit than the provider's
        // source bytes.
        const pending = self.utf8_pending[0..self.utf8_pending_len];
        if (pending.len > OUTPUT_CAP -| self.output_buf.items.len) {
            self.output_truncated = true;
            self.utf8_pending_len = 0;
            return;
        }
        self.output_buf.appendSlice(self.allocator, pending) catch {
            self.output_truncated = true;
            self.utf8_pending_len = 0;
            return;
        };
        self.utf8_pending_len = 0;
    }

    /// Wait for TaskOutput-observable state to change. The caller supplies a
    /// bounded slice so it can re-check AbortSignal between waits.
    pub fn waitForOutputOrTerminal(self: *JobEntry, since: ?usize, timeout_ns: u64) bool {
        self.lock();
        defer self.unlock();
        if (self.status != .running or (since != null and self.output_buf.items.len > since.?)) return true;
        _ = self.condition.timedWait(&self.mutex, timeout_ns);
        return self.status != .running or (since != null and self.output_buf.items.len > since.?);
    }

    /// L1:JobEntry 是一个 UiBackend——subagent 的 agent_loop 经 backend.emit 把流式 text /
    /// 轮工具进度 / token usage 全喂进来,更新自身字段,供进度树渲染。取代旧三通道
    /// (WriterBackend+jobSink / progressTrampoline / usageTrampoline)。
    /// **线程**:emit 在 subagent 自己的线程调(后台 job 线程;前台并发批的 worker)。**每个
    /// 消费分支各自持 self.mutex**(appendOutput / applyProgress / usage 分支),与主线程渲染读
    /// 形成 happens-before。注意 pthread mutex 非递归——emitThunk 本身不持锁,勿在其顶层加锁
    /// (否则重入 appendOutput/applyProgress 死锁)。新增分支若读写 self.* 必须自行上锁。
    /// **语义(L1 行为变化)**:前台 entry(synchronous Task)现在也走本 backend,故其 output_buf
    /// 会被流式 text 填充(旧前台路径走 null-writer 丢弃)。前台 entry 在 index 中可被 TaskOutput
    /// 按 id 查到——但前台 Task 同步阻塞返回 final_text,模型无法在其执行中查它;唯一可见窗口是
    /// 同批并发 Task 互查,届时读到的是对端 subagent 的真实流式输出(正确数据,非脏读)。
    pub fn backend(self: *JobEntry) @import("protocol/ui_backend.zig").UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = &emitThunk, .poll = &pollThunk };
    }

    fn pollThunk(_: *anyopaque, _: @import("protocol/ui_backend.zig").SessionId) ?@import("protocol/ui_backend.zig").UiEvent {
        return null; // subagent 无用户输入通道
    }

    fn emitThunk(state: *anyopaque, _: @import("protocol/ui_backend.zig").SessionId, ev: @import("protocol/ui_backend.zig").CoreEvent) void {
        const self: *JobEntry = @ptrCast(@alignCast(state));
        switch (ev) {
            // 流式 text(及 web_search 的 ui_text)→ 增量输出缓冲(TaskOutput since_byte 读)。
            .text_chunk => |t| self.appendOutput(t),
            // 轮/工具级进度 → current_turn/tool/tool_calls/transcript。
            .progress => |p| self.applyProgress(p.turn, p.tool_name, p.tool_input, p.tool_calls),
            // token usage → tokens(取最新 input+output 快照,镜像 context 大小,对齐 cc)。
            .usage => |u| {
                self.lock();
                defer self.unlock();
                self.tokens = u.input_tokens + u.output_tokens;
            },
            else => {}, // tool_start/result/stream_* 等表达事件:后台 subagent 无 TUI,忽略。
        }
    }

    /// 持锁更新进度字段(原 progressTrampoline 主体)。turn/tool_calls 单调回写;空 tool_name
    /// = 仅推进轮次,保留上一动作(对齐 cc"持续显示最近动作");非空则更新当前工具 + transcript。
    fn applyProgress(self: *JobEntry, turn: u32, tool_name: []const u8, tool_input: []const u8, tool_calls: u32) void {
        self.lock();
        defer self.unlock();
        self.current_turn = turn;
        self.tool_calls = tool_calls;
        if (tool_name.len == 0) return;
        const repaired_name = utf8.repairInvalidUtf8(self.allocator, tool_name) catch return;
        defer self.allocator.free(repaired_name);
        const name_page = utf8.pagePrefix(repaired_name, self.current_tool.len);
        const n = name_page.len;
        @memcpy(self.current_tool[0..n], name_page);
        self.current_tool_len = @intCast(n);
        const repaired_input = utf8.repairInvalidUtf8(self.allocator, tool_input) catch return;
        defer self.allocator.free(repaired_input);
        const input_page = utf8.pagePrefix(repaired_input, self.current_tool_input.len);
        const m = input_page.len;
        @memcpy(self.current_tool_input[0..m], input_page);
        self.current_tool_input_len = @intCast(m);
        appendTranscriptToolLine(&self.transcript, self.allocator, name_page, input_page) catch {};
    }
};

/// 把一行工具动作存进 transcript:`<tool>\t<input>\n`(tab 分隔原料,渲染方再格式化)。
/// 截断超长 input 防 transcript 膨胀。
fn appendTranscriptToolLine(list: *std.ArrayList(u8), a: std.mem.Allocator, tool: []const u8, input: []const u8) !void {
    if (tool.len == 0) return;
    const repaired_tool = try utf8.repairInvalidUtf8(a, tool);
    defer a.free(repaired_tool);
    const repaired_input = try utf8.repairInvalidUtf8(a, input);
    defer a.free(repaired_input);
    try list.appendSlice(a, utf8.pagePrefix(repaired_tool, 32));
    try list.append(a, '\t');
    try list.appendSlice(a, utf8.pagePrefix(repaired_input, 256));
    try list.append(a, '\n');
}

fn dupeUtf8Preview(a: std.mem.Allocator, bytes: []const u8, max: usize) ![]u8 {
    const repaired = try utf8.repairInvalidUtf8(a, bytes);
    defer a.free(repaired);
    return a.dupe(u8, utf8.pagePrefix(repaired, max));
}

/// 启动后台 job 所需的全部参数。调用方(agent.zig)填好后交给 spawnBackground,
/// 由 registry 内部 dupe 进堆分配的 JobInput。
pub const SpawnParams = struct {
    prompt: []const u8,
    system_prompt: []const u8,
    session: SessionId,
    /// 子 agent 可见工具集(已过滤);registry dupe 一份。
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: permission_mod.PermissionContext, // 值拷贝
    /// App 生命周期稳定,借用不拷贝。
    agents: ?*const AgentSet = null,
    dyn_registry: ?*const DynRegistry = null,
    skills: ?*const SkillSet = null,
    agent_depth: u8 = 1,
    max_turns: u32 = 0, // 0 = 用 SpawnOptions 默认
    model_override: ?[]const u8 = null,
    /// 档位表借用指针(App 生命周期只读表;worker 线程读安全,不 dupe)。
    model_tiers: ?*const @import("../api/model_tiers.zig").ProviderTiers = null,
    reasoning_effort_override: ?@import("../types.zig").ReasoningEffort = null,
    overrides_override: ?@import("../api/request_overrides.zig").RequestOverrides = null,
    perm_override: ?@import("../types.zig").PermissionMode = null,
    project_dir: []const u8 = "",
    parent_model: []const u8 = "",
    desc: []const u8 = "",
    /// agent 类型(如 "Explore";进度树标题按 type 分组用)。
    agent_type: []const u8 = "",
    /// L5:后台 subagent 的宿主能力(通常 skillOnly 投影)。见 HostServices。
    host_services: ?@import("../tools/context.zig").HostServices = null,
    /// KG 透传(subagent 参与任务 DAG:claim/闭合;真模型 e2e 抓过缺席=KgUnavailable)。
    /// App 生命周期稳定,借用;KgClient 内部 detail 锁护并发。
    kg: ?*@import("../kg/client.zig").KgClient = null,
    kg_projects_dir: []const u8 = "",
    /// **task#12(安全):sandbox 透传到后台 subagent**——否则后台 Bash 绕过父 sandbox(Linus review
    /// 抓:同步路径修了、后台路径漏了,同 KG 字段的两构造点陷阱)。sandbox 指针借 App 生命周期(稳定,
    /// App.deinit 先 join jobs);cwd_abs/home_dir/additional_dirs 由 JobInput 深拷贝(additional_dirs 会被
    /// /add-dir realloc,借用悬挂 → 快照)。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    cwd_abs: []const u8 = "",
    home_dir: []const u8 = "",
    artifact_root: []const u8 = "",
    tool_result_metrics: ?*@import("tool_result_metrics.zig").Metrics = null,
    file_change_journal: ?*@import("file_change.zig").Journal = null,
    additional_dirs: []const []const u8 = &.{},
    /// AgentDef.mcpServers 过滤后的 session 视图；registry 复制外层 slice，entry 本体借 App。
    mcp_sessions: []const @import("mcp_session.zig").McpSessionEntry = &.{},
    /// AgentDef.isolation=worktree 所有权；spawnBackground consume-on-call。
    worktree: ?@import("../agents/isolation.zig").Worktree = null,
    /// Ctrl+B 主对话转后台:预建对话副本(深拷贝,所有权转移给 registry → JobInput → spawnAgentSink)。
    /// null=普通 subagent(从 prompt 起新对话)。
    prebuilt_conversation: ?Conversation = null,
};

/// 线程拥有的输入。线程结束时自行 cleanup(free dupe + client/io deinit + destroy)。
const JobInput = struct {
    allocator: std.mem.Allocator,
    entry: *JobEntry,
    session: SessionId,
    // 自有拷贝:
    prompt: []u8,
    system_prompt: []u8,
    tool_defs_owned: []json_mod.ToolDefinition, // dupe 的 slice;description 深拷贝(见下),其余字段借静态注册表
    /// 被 redescribeForContext 重写的 description 是父 execute 期分配的,execute 返回即释放。
    /// 后台 job 寿命更长 → 必须深拷贝进 job 内存,否则 UAF。这里持有这些拷贝,cleanup 时 free。
    desc_copies: [][]u8,
    project_dir: []u8,
    parent_model: []u8,
    model_override: ?[]u8,
    model_tiers: ?*const @import("../api/model_tiers.zig").ProviderTiers,
    reasoning_effort_override: ?@import("../types.zig").ReasoningEffort,
    // 值拷贝:
    permission_ctx: permission_mod.PermissionContext,
    perm_override: ?@import("../types.zig").PermissionMode,
    agent_depth: u8,
    max_turns: u32,
    // 借用(App 生命周期):
    agents: ?*const AgentSet,
    dyn_registry: ?*const DynRegistry,
    skills: ?*const SkillSet,
    host_services: ?@import("../tools/context.zig").HostServices,
    kg: ?*@import("../kg/client.zig").KgClient,
    kg_projects_dir: []const u8,
    // task#12:sandbox 借 App 生命周期(App.deinit 先 join jobs,指针稳定);cwd_abs/home_dir/additional_dirs
    // 深拷贝(job-owned;additional_dirs 深拷贝外层+每条,防 /add-dir realloc 悬挂)。cleanup 释放。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings,
    cwd_abs: []u8,
    home_dir: []u8,
    artifact_root: []u8,
    tool_result_metrics: ?*@import("tool_result_metrics.zig").Metrics,
    file_change_journal: ?*@import("file_change.zig").Journal,
    additional_dirs: [][]u8,
    memdir_owned: []u8,
    mcp_sessions_owned: []@import("mcp_session.zig").McpSessionEntry,
    worktree: ?@import("../agents/isolation.zig").Worktree,
    // 专属资源:P0.5 换成 OwnedProvider(据 provider_kind 造对应具体 client + io,统一 deinit)。
    owned: pf.OwnedProvider,
    /// Ctrl+B 主对话转后台:预建对话(深拷贝副本,所有权在此)。jobThreadMain move 进 SpawnOptions
    /// 后立即置 null(单一所有者);仅 spawn 失败回滚时 cleanup 命中 deinit。null=普通 subagent(从 prompt 起)。
    prebuilt_conversation: ?Conversation = null,
    /// A background job owns a retained policy-frame projection. The parent
    /// may rotate sessions or clear its skill while this thread is running.
    active_skill_owned: ?ActiveSkillState = null,
    // 嵌套后台:子 agent 也能 Task(run_in_background) 注册进同一 root registry。
    registry: *AgentJobRegistry,

    /// 在发布 terminal status 前固定 worktree 结局；否则 TaskOutput 可能先看到 done，
    /// 下一次轮询才看到 worktree_kept，形成非原子的终态快照。
    fn finalizeWorktree(self: *JobInput) void {
        if (self.worktree) |*wt| {
            const kept = wt.finalize(null);
            self.entry.lock();
            self.entry.worktree_kept = kept;
            self.entry.worktree_cleanup_complete = wt.cleanup_complete;
            self.entry.unlock();
        }
    }

    fn cleanup(self: *JobInput) void {
        const a = self.allocator;
        a.free(self.prompt);
        a.free(self.system_prompt);
        for (self.desc_copies) |d| a.free(d);
        a.free(self.desc_copies);
        a.free(self.tool_defs_owned);
        a.free(self.project_dir);
        a.free(self.parent_model);
        a.free(self.cwd_abs); // task#12
        a.free(self.home_dir);
        a.free(self.artifact_root);
        for (self.additional_dirs) |d| a.free(d);
        a.free(self.additional_dirs);
        a.free(self.memdir_owned);
        a.free(self.mcp_sessions_owned);
        if (self.worktree) |*wt| {
            self.finalizeWorktree();
            wt.deinit();
        }
        if (self.model_override) |m| a.free(m);
        if (self.prebuilt_conversation) |*c| c.deinit(); // 仅 spawn 失败回滚命中(jobThreadMain 成功路径已 move 置 null)
        if (self.active_skill_owned) |*skill| skill.deinit();
        self.owned.deinit();
        a.destroy(self);
    }
};

pub const AgentJobRegistry = struct {
    allocator: std.mem.Allocator,
    list_mutex: sync.Mutex = .{},
    entries: std.ArrayList(*JobEntry) = .empty,
    closing: bool = false,
    starting: usize = 0,
    index: std.AutoHashMap([16]u8, *JobEntry),
    // 造 per-job provider 用(dupe 自 App):
    api_key: []u8,
    base_url: ?[]u8,
    model: []u8,
    /// P0.5:parent 的 provider 协议 → per-job provider 据此造对应具体 client(子继承父 provider)。
    provider_kind: types_mod.ProviderKind = .anthropic,
    /// OpenAI wire 协议(仅 provider_kind==.openai 时消费):子 job 继承父的显式选择。
    openai_protocol: types_mod.OpenAIProtocol = .chat_completions,
    /// Provider-declared authentication for the parent's resolved route
    /// (issue #16). Null keeps the historical bearer header, so a child agent
    /// authenticates exactly the way the parent does.
    auth_scheme: ?@import("../provider/credential.zig").AuthScheme = null,
    /// Borrowed from the App/Runtime immutable plugin Snapshot. App drains all
    /// jobs before destroying that Snapshot.
    dialect_resolver: dialect_mod.Resolver = .builtin(),
    limits: ?@import("../api/model_limits.zig").ModelLimitsSource = null,
    catalog_snapshot: ?@import("../api/catalog.zig").Catalog = null,
    /// per-job provider 的收头阶段流空闲上限;null = env/默认(见 provider_factory.Options)。测试注入小值。
    stream_idle_timeout_ms: ?u64 = null,
    /// per-job provider 的正文阶段流空闲上限平覆盖;null = env/按 max_tokens 自动。测试注入小值。
    stream_body_idle_timeout_ms: ?u64 = null,
    seq: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        model: []const u8,
        provider_kind: types_mod.ProviderKind,
    ) !AgentJobRegistry {
        return initWithDialectResolver(
            allocator,
            api_key,
            base_url,
            model,
            provider_kind,
            .chat_completions,
            .builtin(),
        );
    }

    pub fn initWithDialectResolver(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        model: []const u8,
        provider_kind: types_mod.ProviderKind,
        openai_protocol: types_mod.OpenAIProtocol,
        dialect_resolver: dialect_mod.Resolver,
    ) !AgentJobRegistry {
        const key_owned = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_owned);
        const url_owned: ?[]u8 = if (base_url) |u| try allocator.dupe(u8, u) else null;
        errdefer if (url_owned) |u| allocator.free(u);
        const model_owned = try allocator.dupe(u8, model);
        errdefer allocator.free(model_owned);
        return .{
            .allocator = allocator,
            .index = std.AutoHashMap([16]u8, *JobEntry).init(allocator),
            .api_key = key_owned,
            .base_url = url_owned,
            .model = model_owned,
            .provider_kind = provider_kind,
            .openai_protocol = openai_protocol,
            .dialect_resolver = dialect_resolver,
        };
    }

    /// Update the default parent model used for subsequently spawned agent
    /// jobs. Already-running jobs own their own Client/model copies.
    pub fn setModel(self: *AgentJobRegistry, model: []const u8) !void {
        const model_owned = try self.allocator.dupe(u8, model);
        self.listLock();
        defer self.listUnlock();
        const old = self.model;
        self.model = model_owned;
        self.allocator.free(old);
    }

    /// Publish an owned catalog snapshot. Workers never inspect App's mutable catalog.
    pub fn setLimits(self: *AgentJobRegistry, source: @import("../api/model_limits.zig").ModelLimitsSource) !void {
        var snapshot: ?@import("../api/catalog.zig").Catalog = null;
        if (source.catalog) |catalog| snapshot = try catalog.clone(self.allocator);
        self.listLock();
        defer self.listUnlock();
        if (self.catalog_snapshot) |*old| old.deinit();
        self.catalog_snapshot = snapshot;
        self.limits = source;
        self.limits.?.catalog = null;
    }

    /// Update the API key used for subsequently spawned agent jobs.
    /// Already-running jobs own their Client copies and are left untouched.
    pub fn setApiKey(self: *AgentJobRegistry, api_key: []const u8) !void {
        const key_owned = try self.allocator.dupe(u8, api_key);
        self.listLock();
        defer self.listUnlock();
        const old = self.api_key;
        self.api_key = key_owned;
        @memset(old, 0);
        self.allocator.free(old);
    }

    /// Move every future job onto a new provider route (issue #16).
    ///
    /// One call, because these fields are one decision: a registry holding this
    /// provider's key while still pointing at the previous provider's endpoint
    /// would send the credential to the wrong vendor. Both allocations happen
    /// before the swap, so a failure leaves the previous route completely
    /// intact. Jobs already running keep the provider they were constructed
    /// with; this affects the ones spawned next.
    pub fn setRoute(
        self: *AgentJobRegistry,
        api_key: []const u8,
        base_url: ?[]const u8,
        provider_kind: types_mod.ProviderKind,
        openai_protocol: types_mod.OpenAIProtocol,
        auth_scheme: ?@import("../provider/credential.zig").AuthScheme,
    ) !void {
        const key_owned = try self.allocator.dupe(u8, api_key);
        errdefer {
            @memset(key_owned, 0);
            self.allocator.free(key_owned);
        }
        const url_owned: ?[]u8 = if (base_url) |url| try self.allocator.dupe(u8, url) else null;

        self.listLock();
        defer self.listUnlock();
        const old_key = self.api_key;
        const old_url = self.base_url;
        self.api_key = key_owned;
        self.base_url = url_owned;
        self.provider_kind = provider_kind;
        self.openai_protocol = openai_protocol;
        self.auth_scheme = auth_scheme;
        @memset(old_key, 0);
        self.allocator.free(old_key);
        if (old_url) |url| self.allocator.free(url);
    }

    fn listLock(self: *AgentJobRegistry) void {
        _ = self.list_mutex.lock();
    }
    fn listUnlock(self: *AgentJobRegistry) void {
        _ = self.list_mutex.unlock();
    }

    /// running job 计数(持 list 锁)。TUI(TaskTab)用。
    pub fn runningCount(self: *AgentJobRegistry) usize {
        // `entries` is a growable pointer array.  Callers can register or
        // remove foreground/background entries concurrently with the UI
        // ticker, so iterating it without the registry lock is a real race
        // (and can observe a freed/reallocated slice).
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const running = e.status == .running;
            e.unlock();
            if (running) n += 1;
        }
        return n;
    }

    fn runningBackgroundCountLocked(self: *AgentJobRegistry) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const running = !e.foreground and e.status == .running;
            e.unlock();
            if (running) n += 1;
        }
        return n;
    }

    fn runningBackgroundCount(self: *AgentJobRegistry) usize {
        self.listLock();
        defer self.listUnlock();
        return self.runningBackgroundCountLocked();
    }

    pub fn runningCountForSession(self: *AgentJobRegistry, session: SessionId) usize {
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const owned_running = std.mem.eql(u8, e.session.asSlice(), session.asSlice()) and e.status == .running;
            e.unlock();
            if (owned_running) n += 1;
        }
        return n;
    }

    pub fn totalCountForSession(self: *AgentJobRegistry, session: SessionId) usize {
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const owned = std.mem.eql(u8, e.session.asSlice(), session.asSlice());
            e.unlock();
            if (owned) n += 1;
        }
        return n;
    }

    /// 总 entry 数(含已完成,供空闲期 `← for agents` 入口判定)。持 list 锁。
    pub fn totalCount(self: *AgentJobRegistry) usize {
        self.listLock();
        defer self.listUnlock();
        return self.entries.items.len;
    }

    fn genId(self: *AgentJobRegistry) [16]u8 {
        self.seq +%= 1;
        var raw: [5]u8 = undefined;
        if (!rng.randomBytes(&raw)) {
            // 退化:用 seq + 时间低位(可移植熵源不可用时)
            const t: u64 = @bitCast(util_time.nowMs());
            const fallback: u64 = t ^ self.seq;
            const fallback_bytes = std.mem.asBytes(&fallback);
            @memcpy(&raw, fallback_bytes[0..raw.len]);
        }
        var id: [16]u8 = undefined;
        // "agent_" (6) + 10 hex = 16 bytes.  Keep the fixed-width id while
        // increasing entropy from 32 to 40 bits; publication below also
        // rejects the (still possible) duplicate instead of overwriting the
        // index entry for an older live job.
        const written = std.fmt.bufPrint(&id, "agent_{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3], raw[4] }) catch unreachable;
        for (id[written.len..]) |*b| b.* = 0;
        return id;
    }

    /// 启动后台 job,立即返回 id(指向 entry.id,registry 存活期间有效)。
    /// **所有权 / 失败回滚(committed-flag 模型)**:本函数逐资源 errdefer,全部 gate 在 `if (!committed)`。
    /// spawn 线程成功后才 `committed = true`(所有权转移给线程,errdefer 全部失效)。在那之前的**任何**
    /// 失败路径只需 `return e`——errdefer 统一释放,**不手动 cleanup**(手动 cleanup + errdefer 共存会
    /// double-free:Zig errdefer 在 catch+return e 时照样触发,实测验证)。`p.prebuilt_conversation`
    /// 同样 consume-on-call:失败由 errdefer 释放,成功由 job(jobThreadMain move 进 spawnAgentSink)释放。
    pub fn spawnBackground(self: *AgentJobRegistry, p_in: SpawnParams) ![]const u8 {
        // Hold an in-flight reservation for the *whole* call.  Deinit may
        // close the registry while a caller is still building provider/input
        // state, before the entry is published; counting only the publication
        // window lets it free the registry allocator/config out from under
        // this function.  The defer is registered first so every later
        // errdefer rolls back before the reservation is released.
        self.listLock();
        if (self.closing) {
            self.listUnlock();
            return error.RegistryClosed;
        }
        self.starting += 1;
        self.listUnlock();
        defer {
            self.listLock();
            self.starting -= 1;
            self.listUnlock();
        }

        var p = p_in;
        var committed = false; // spawn 成功才置 true;此前所有 errdefer 都 gate 在 !committed
        // prebuilt_conversation 的释放(失败路径):consume-on-call,errdefer 接管。
        errdefer if (!committed) {
            if (p.prebuilt_conversation) |*c| c.deinit();
            if (p.worktree) |*wt| {
                _ = wt.finalize(null);
                wt.deinit();
            }
        };
        if (self.runningBackgroundCount() >= MAX_BG_JOBS) return error.TooManyBackgroundJobs;

        const a = self.allocator;

        // 1) 堆分配 entry(地址稳定)
        const entry = try a.create(JobEntry);
        errdefer if (!committed) a.destroy(entry);
        entry.* = .{ .allocator = a, .session = p.session };
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        entry.desc_preview = try dupeUtf8Preview(a, p.desc, 80);
        errdefer if (!committed) a.free(entry.desc_preview);
        entry.agent_type = dupeUtf8Preview(a, p.agent_type, 32) catch &.{};
        errdefer if (!committed and entry.agent_type.len > 0) a.free(entry.agent_type);
        entry.worktree_path = if (p.worktree) |wt| try a.dupe(u8, wt.path) else &.{};
        errdefer if (!committed and entry.worktree_path.len > 0) a.free(entry.worktree_path);

        // 2) 专属 OwnedProvider(据 provider_kind 造对应具体 client + io,所有权给 JobInput)。
        //    **必须用 self.allocator**(与 jobThreadMain 传给 spawnAgentSink 的 input.allocator 一致):
        //    provider 的流式事件(tool_use/text)所有权会转移进 subagent 的 agent_loop,两者 allocator
        //    不一致 → Invalid free(GPA 实测)。后台单/多 job 用 registry.allocator 全程一致,已验证能跑。
        //    ⚠️ 线程安全存疑(见 HANDOFF):后台 job 线程用 registry.allocator 做 HTTP,若 App gpa 非线程安全
        //    且与 io_runtime worker 并发理论上有 TaskBatch 同款风险,但后台测试历来通过、未实测崩溃,留查。
        // Route/model credentials can be rotated while the UI is spawning a
        // job.  Keep the registry lock across the snapshot and provider
        // construction so setRoute/setApiKey/setModel cannot free or replace
        // these slices mid-call.
        self.listLock();
        var owned = pf.makeProviderWithOptions(
            self.allocator,
            self.provider_kind,
            self.api_key,
            self.model,
            self.base_url,
            self.openai_protocol,
            self.dialect_resolver,
            .{ .auth_scheme = self.auth_scheme, .limits = self.limits, .stream_idle_timeout_ms = self.stream_idle_timeout_ms, .stream_body_idle_timeout_ms = self.stream_body_idle_timeout_ms },
        ) catch |err| {
            self.listUnlock();
            return err;
        };
        self.listUnlock();
        errdefer if (!committed) owned.deinit();

        // 3) dupe 所有借用内存进 JobInput(必须在 spawn 之前)
        const input = try a.create(JobInput);
        errdefer if (!committed) a.destroy(input);
        const prompt_owned = try a.dupe(u8, p.prompt);
        errdefer if (!committed) a.free(prompt_owned);
        const sys_owned = try a.dupe(u8, p.system_prompt);
        errdefer if (!committed) a.free(sys_owned);
        const defs_owned = try a.dupe(json_mod.ToolDefinition, p.tool_defs);
        errdefer if (!committed) a.free(defs_owned);
        // 深拷贝每个 description 进 job 内存(父 execute 返回后原串被释放 → 否则 UAF)。
        // name/input_schema/server_type 指向静态注册表,长生命周期,浅拷贝即可。
        const desc_copies = try a.alloc([]u8, defs_owned.len);
        errdefer if (!committed) a.free(desc_copies);
        var nd: usize = 0;
        errdefer if (!committed) for (desc_copies[0..nd]) |d| a.free(d);
        for (defs_owned, 0..) |*d, di| {
            const c = try a.dupe(u8, d.description);
            desc_copies[di] = c;
            nd = di + 1;
            d.description = c;
        }
        const pdir_owned = try a.dupe(u8, p.project_dir);
        errdefer if (!committed) a.free(pdir_owned);
        const pmodel_owned = try a.dupe(u8, p.parent_model);
        errdefer if (!committed) a.free(pmodel_owned);
        const mover_owned: ?[]u8 = if (p.model_override) |m| try a.dupe(u8, m) else null;
        errdefer if (!committed) if (mover_owned) |m| a.free(m);
        // task#12:sandbox 快照(cwd_abs/home_dir dupe;additional_dirs 深拷贝防 /add-dir realloc 悬挂)。
        const cwd_owned = try a.dupe(u8, p.cwd_abs);
        errdefer if (!committed) a.free(cwd_owned);
        const home_owned = try a.dupe(u8, p.home_dir);
        errdefer if (!committed) a.free(home_owned);
        const artifact_root_owned = try a.dupe(u8, p.artifact_root);
        errdefer if (!committed) a.free(artifact_root_owned);
        const adirs_owned = try a.alloc([]u8, p.additional_dirs.len);
        errdefer if (!committed) a.free(adirs_owned);
        var nad: usize = 0;
        errdefer if (!committed) for (adirs_owned[0..nad]) |d| a.free(d);
        for (p.additional_dirs, 0..) |d, di| {
            adirs_owned[di] = try a.dupe(u8, d);
            nad = di + 1;
        }
        const memdir_owned = try a.dupe(u8, p.permission_ctx.memdir_abs);
        errdefer if (!committed) a.free(memdir_owned);
        const mcp_sessions_owned = try a.dupe(@import("mcp_session.zig").McpSessionEntry, p.mcp_sessions);
        errdefer if (!committed) a.free(mcp_sessions_owned);

        var permission_owned = p.permission_ctx.scopedDerive(null);
        permission_owned.allocator = a;
        permission_owned.session = p.session;
        permission_owned.memdir_abs = memdir_owned;
        permission_owned.match_ctx.cwd = cwd_owned;
        permission_owned.match_ctx.project_root = pdir_owned;
        permission_owned.match_ctx.home = home_owned;
        permission_owned.match_ctx.additional_dirs = adirs_owned;
        permission_owned.match_ctx.alloc = a;

        var active_skill_owned: ?ActiveSkillState = if (p.permission_ctx.active_skill) |skill|
            try ActiveSkillState.initFromPolicyFrame(a, skill.skill_name, skill.policy_frame)
        else
            null;
        errdefer if (!committed) if (active_skill_owned) |*skill| skill.deinit();

        input.* = .{
            .allocator = a,
            .entry = entry,
            .session = p.session,
            .prompt = prompt_owned,
            .system_prompt = sys_owned,
            .tool_defs_owned = defs_owned,
            .desc_copies = desc_copies,
            .project_dir = pdir_owned,
            .parent_model = pmodel_owned,
            .model_override = mover_owned,
            .model_tiers = p.model_tiers,
            .reasoning_effort_override = p.reasoning_effort_override,
            .permission_ctx = permission_owned,
            .perm_override = p.perm_override,
            .agent_depth = p.agent_depth,
            .max_turns = p.max_turns,
            .agents = p.agents,
            .dyn_registry = p.dyn_registry,
            .skills = p.skills,
            .host_services = p.host_services,
            .kg = p.kg,
            .kg_projects_dir = p.kg_projects_dir,
            .sandbox = p.sandbox, // task#12:borrow(App-lifetime)
            .cwd_abs = cwd_owned,
            .home_dir = home_owned,
            .artifact_root = artifact_root_owned,
            .tool_result_metrics = p.tool_result_metrics,
            .file_change_journal = p.file_change_journal,
            .additional_dirs = adirs_owned,
            .memdir_owned = memdir_owned,
            .mcp_sessions_owned = mcp_sessions_owned,
            .worktree = p.worktree,
            .owned = owned,
            .prebuilt_conversation = p.prebuilt_conversation, // move(Ctrl+B 转后台);普通 subagent=null
            .active_skill_owned = active_skill_owned,
            .registry = self,
        };
        if (input.active_skill_owned) |*skill| input.permission_ctx.active_skill = skill;

        // 4) 注册进 entries + index(持 list 锁),在 spawn 之前——保证 id 立即可查。
        //    失败:只 return e,上面所有 !committed errdefer 统一释放(不手动 cleanup → 防 double-free)。
        self.listLock();
        // The early runningCount check is only a fast rejection.  Admission
        // must be rechecked while holding the same publication lock or two
        // concurrent Task calls can both observe one free slot and exceed
        // MAX_BG_JOBS before either entry is appended.
        if (self.closing) {
            self.listUnlock();
            return error.RegistryClosed;
        }
        if (self.runningBackgroundCountLocked() >= MAX_BG_JOBS) {
            self.listUnlock();
            return error.TooManyBackgroundJobs;
        }
        var id = self.genId();
        var collision_attempts: usize = 0;
        while (self.index.contains(id)) : (collision_attempts += 1) {
            if (collision_attempts >= 8) {
                self.listUnlock();
                return error.JobIdCollision;
            }
            id = self.genId();
        }
        entry.id = id;
        entry.id_len = blk: {
            var n: u8 = 0;
            while (n < id.len and id[n] != 0) : (n += 1) {}
            break :blk n;
        };
        self.entries.append(a, entry) catch |e| {
            self.listUnlock();
            return e;
        };
        self.index.put(entry.id, entry) catch |err| {
            // Do not publish a job that cannot be looked up.  Silently
            // swallowing OOM here leaves an entry in the roster without an
            // index key, making TaskOutput/TaskStop appear to lose the job.
            _ = self.entries.pop();
            self.listUnlock();
            return err;
        };
        self.listUnlock();
        // 注册成功后 entry 已进 entries——若下面 spawn 失败,需从 entries 摘掉再让 errdefer 释放。
        errdefer if (!committed) {
            self.listLock();
            _ = self.index.remove(entry.id);
            for (self.entries.items, 0..) |it, i| {
                if (it == entry) {
                    _ = self.entries.swapRemove(i);
                    break;
                }
            }
            self.listUnlock();
        };

        // 5) spawn 线程。成功 → committed=true,所有权(input/entry/client/io/prebuilt)归线程 + registry,
        //    所有 errdefer 失效。失败 → return e,errdefer 统一回滚(摘 registry + 释放全部资源)。
        entry.thread = std.Thread.spawn(.{}, jobThreadMain, .{input}) catch |err| {
            return err;
        };
        committed = true;

        log.info("agent", "background job spawned id={s} desc={s}", .{ entry.idSlice(), entry.desc_preview });
        return entry.idSlice();
    }

    /// 测试专用:注册一个**无线程**的假 entry(供离线 TTY 验证 agent 进度树/switcher)。
    /// 不 spawn 线程、不开网络。entry 由 registry deinit 时统一释放(无 thread → join 跳过)。
    /// 全参数版:type/desc/tool_calls/tokens/status/current_tool 全可控,驱动新树格式。
    pub fn pushTestEntryFull(
        self: *AgentJobRegistry,
        agent_type: []const u8,
        desc: []const u8,
        tool_calls: u32,
        tokens: u64,
        tool: []const u8,
        tool_input: []const u8,
        status: JobStatus,
    ) !void {
        const a = self.allocator;
        const entry = try a.create(JobEntry);
        entry.* = .{ .allocator = a };
        // One cleanup owner for every failure before publication.  In
        // particular, do not call freeEntry in an append/index catch while a
        // separate destroy/desc errdefer is still armed (that used to
        // double-free test entries on allocator failure).
        errdefer freeEntry(entry);
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        entry.foreground = true;
        entry.desc_preview = try dupeUtf8Preview(a, desc, 80);
        entry.agent_type = dupeUtf8Preview(a, agent_type, 32) catch &.{};
        entry.status = status;
        entry.current_turn = 1;
        entry.tool_calls = tool_calls;
        entry.tokens = tokens;
        const tn = @min(tool.len, entry.current_tool.len);
        @memcpy(entry.current_tool[0..tn], tool[0..tn]);
        entry.current_tool_len = @intCast(tn);
        const tin = @min(tool_input.len, entry.current_tool_input.len);
        @memcpy(entry.current_tool_input[0..tin], tool_input[0..tin]);
        entry.current_tool_input_len = @intCast(tin);
        // 测试用 transcript:prompt(从 desc 派生)+ 当前工具行,供区域2 viewing 渲染。
        entry.prompt_preview = dupeUtf8Preview(a, desc, 4096) catch &.{};
        if (tool.len > 0) {
            appendTranscriptToolLine(&entry.transcript, a, tool, tool_input) catch {};
        }
        self.listLock();
        const id = self.genId();
        entry.id = id;
        entry.id_len = blk: {
            var n: u8 = 0;
            while (n < id.len and id[n] != 0) : (n += 1) {}
            break :blk n;
        };
        self.entries.append(a, entry) catch |e| {
            self.listUnlock();
            return e;
        };
        self.index.put(entry.id, entry) catch |err| {
            _ = self.entries.pop();
            self.listUnlock();
            return err;
        };
        self.listUnlock();
    }

    /// 旧签名 wrapper(back-compat):默认 type="Explore",running。turn 映射 current_turn
    /// (旧语义),tool_calls/tokens 保持 0(测试校验初值为 0)。
    pub fn pushTestEntry(self: *AgentJobRegistry, desc: []const u8, turn: u32, tool: []const u8, tool_input: []const u8) !void {
        try self.pushTestEntryFull("Explore", desc, 0, 0, tool, tool_input, .running);
        // 旧测试用 turn 作 current_turn 语义,覆盖之(Full 固定设 1)。
        const e = self.entries.items[self.entries.items.len - 1];
        e.current_turn = turn;
    }

    /// 测试专用:清掉所有(测试注入的)entry + 释放。供 /agent-churn-test 收尾,不污染后续状态。
    /// 仅用于无 thread 的测试 entry(foreground/pushTestEntry);有 thread 的真 job 不该走这。
    pub fn clearTestEntries(self: *AgentJobRegistry) void {
        self.listLock();
        defer self.listUnlock();
        while (self.entries.items.len > 0) {
            const e = self.entries.pop().?;
            _ = self.index.remove(e.id);
            freeEntry(e);
        }
    }

    /// O(1) 按 id 查 entry。
    pub fn get(self: *AgentJobRegistry, id: []const u8) ?*JobEntry {
        if (id.len > 16) return null;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        return self.index.get(key);
    }

    /// TaskOutput may long-poll, so it must never borrow a transient foreground
    /// entry that another parallel Task can remove. Background entries remain
    /// allocated until registry deinit (which joins workers before freeing).
    pub fn getBackground(self: *AgentJobRegistry, id: []const u8) ?*JobEntry {
        if (id.len > 16) return null;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        const entry = self.index.get(key) orelse return null;
        if (entry.foreground) return null;
        return entry;
    }

    /// Session-scoped TaskOutput lookup. A registry is process-global, but a
    /// job belongs to the immutable session that spawned it; the active UI
    /// session must not be allowed to read another session's output by id.
    pub fn getBackgroundForSession(self: *AgentJobRegistry, id: []const u8, session: SessionId) ?*JobEntry {
        const entry = self.getBackground(id) orelse return null;
        entry.lock();
        defer entry.unlock();
        if (!std.mem.eql(u8, entry.session.asSlice(), session.asSlice())) return null;
        return entry;
    }

    pub fn acquireBackgroundForSession(self: *AgentJobRegistry, id: []const u8, session: SessionId) ?*JobEntry {
        if (id.len > 16) return null;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        const entry = self.index.get(key) orelse return null;
        if (entry.foreground) return null;
        entry.lock();
        const owned = std.mem.eql(u8, entry.session.asSlice(), session.asSlice());
        entry.unlock();
        if (!owned) return null;
        entry.readers += 1;
        return entry;
    }

    pub fn releaseBackground(self: *AgentJobRegistry, entry: *JobEntry) void {
        self.listLock();
        if (entry.readers > 0) entry.readers -= 1;
        self.listUnlock();
    }

    /// 后台 subagent job 的值语义快照(供 TUI Ctrl+T 列表用,不持锁/不持指针)。
    /// id/desc 拷进调用者 allocator;调用者用完整体 free(freeSnapshots)。
    pub const JobSnapshot = struct {
        id: []u8,
        status: JobStatus,
        desc: []u8,
        turns: u32,
        tool_calls: u32,
        current_turn: u32,
        /// 当前/最近工具名(owned by caller allocator;空 = 无)。
        current_tool: []u8,
        /// 该工具的原始 input JSON 快照(owned;供动作行渲染参数预览)。
        current_tool_input: []u8,
        /// 是否前台(同步)job。
        foreground: bool = false,
        /// agent 类型(owned;如 "Explore";进度树标题按 type 分组用)。
        agent_type: []u8,
        /// 累计 token(进度树行 `· X tokens` 用)。
        tokens: u64 = 0,
        /// 起始时间(毫秒;进度树 2s 后 ctrl+b 提示 + switcher elapsed 用)。
        started_ms: util_time.Millis = 0,
    };

    pub fn snapshotJobs(self: *AgentJobRegistry, allocator: std.mem.Allocator) ![]JobSnapshot {
        return self.snapshotJobsForSession(allocator, null);
    }

    /// Session-scoped roster snapshot. Jobs remain process-global so shutdown
    /// can drain them all, but UI/state projections must never expose a job
    /// created by a different resumed session.
    pub fn snapshotJobsForSession(self: *AgentJobRegistry, allocator: std.mem.Allocator, session: ?SessionId) ![]JobSnapshot {
        self.listLock();
        defer self.listUnlock();
        var out: std.ArrayList(JobSnapshot) = .empty;
        errdefer {
            for (out.items) |s| {
                allocator.free(s.id);
                allocator.free(s.desc);
                allocator.free(s.current_tool);
                allocator.free(s.current_tool_input);
                allocator.free(s.agent_type);
            }
            out.deinit(allocator);
        }
        for (self.entries.items) |e| {
            e.lock();
            defer e.unlock();
            if (session) |wanted| {
                if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            }
            var snapshot = JobSnapshot{
                .id = &.{},
                .status = e.status,
                .desc = &.{},
                .turns = e.turns,
                .tool_calls = e.tool_calls,
                .current_turn = e.current_turn,
                .current_tool = &.{},
                .current_tool_input = &.{},
                .foreground = e.foreground,
                .agent_type = &.{},
                .tokens = e.tokens,
                .started_ms = e.started_ms,
            };
            errdefer {
                if (snapshot.id.len > 0) allocator.free(snapshot.id);
                if (snapshot.desc.len > 0) allocator.free(snapshot.desc);
                if (snapshot.current_tool.len > 0) allocator.free(snapshot.current_tool);
                if (snapshot.current_tool_input.len > 0) allocator.free(snapshot.current_tool_input);
                if (snapshot.agent_type.len > 0) allocator.free(snapshot.agent_type);
            }
            snapshot.id = try allocator.dupe(u8, e.idSlice());
            snapshot.desc = try allocator.dupe(u8, e.desc_preview);
            snapshot.current_tool = try allocator.dupe(u8, e.current_tool[0..e.current_tool_len]);
            snapshot.current_tool_input = try allocator.dupe(u8, e.current_tool_input[0..e.current_tool_input_len]);
            snapshot.agent_type = try allocator.dupe(u8, e.agent_type);
            try out.append(allocator, snapshot);
            // Ownership moved into `out`; leave the local cleanup inert.
            snapshot = .{
                .id = &.{},
                .status = .running,
                .desc = &.{},
                .turns = 0,
                .tool_calls = 0,
                .current_turn = 0,
                .current_tool = &.{},
                .current_tool_input = &.{},
                .agent_type = &.{},
            };
        }
        return try out.toOwnedSlice(allocator);
    }

    /// **task#18:后台 job done 事件的跨线程发射**。job 线程只置 e.status(终态),**不能**用父的栈
    /// trampoline reporter(其生命周期=父轮,job 后台续跑时早失效 → 悬挂)。改由**主/driver 线程**周期
    /// reap:排出"终态且 done 未发"的 job(锁内标 done_emitted 防重复,值语义 dup),caller 据此发
    /// agent_lifecycle.done 到 session journal。返回 owned;freeDoneInfos 释放。
    pub const DoneInfo = struct { id: []u8, session: SessionId, status: JobStatus, turns: u32, tool_calls: u32, tokens: u64 };
    pub fn drainNewlyDone(self: *AgentJobRegistry, allocator: std.mem.Allocator) ![]DoneInfo {
        return self.drainNewlyDoneForSession(allocator, null);
    }

    pub fn drainNewlyDoneForSession(self: *AgentJobRegistry, allocator: std.mem.Allocator, session: ?SessionId) ![]DoneInfo {
        self.listLock();
        defer self.listUnlock();
        var list: std.ArrayList(DoneInfo) = .empty;
        errdefer {
            for (list.items) |d| allocator.free(d.id);
            list.deinit(allocator);
        }
        for (self.entries.items) |e| {
            e.lock();
            defer e.unlock();
            if (e.status == .running or e.done_emitted) continue;
            if (session) |wanted| {
                if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            }
            var id = try allocator.dupe(u8, e.idSlice()); // 唯一需 dup 的
            errdefer if (id.len > 0) allocator.free(id);
            try list.append(allocator, .{ .id = id, .session = e.session, .status = e.status, .turns = e.turns, .tool_calls = e.tool_calls, .tokens = e.tokens });
            id = &.{}; // ownership moved into list
            e.done_emitted = true; // 成功入队后才标记(append/dupe OOM 则留 false,下轮重试,不丢事件)
        }
        return list.toOwnedSlice(allocator);
    }
    pub fn freeDoneInfos(allocator: std.mem.Allocator, infos: []DoneInfo) void {
        for (infos) |d| allocator.free(d.id);
        allocator.free(infos);
    }

    pub fn freeSnapshots(allocator: std.mem.Allocator, snaps: []JobSnapshot) void {
        for (snaps) |s| {
            allocator.free(s.id);
            allocator.free(s.desc);
            allocator.free(s.current_tool);
            allocator.free(s.current_tool_input);
            allocator.free(s.agent_type);
        }
        allocator.free(snaps);
    }

    /// 终止一个后台 job(只 abort,非阻塞)。状态由线程跑到检查点后自置 .killed。
    /// 幂等:对已结束 job 调用安全(abort 标志无副作用)。
    pub fn kill(self: *AgentJobRegistry, id: []const u8) error{JobNotFound}!void {
        const e = self.get(id) orelse return error.JobNotFound;
        e.abort.abort(.user_ctrl_c);
    }

    /// User-facing TaskStop is session scoped. Keep the process-wide `kill`
    /// primitive for shutdown/admin paths, but never let a resumed session
    /// cancel a job owned by another session by guessing its id.
    pub fn killForSession(self: *AgentJobRegistry, id: []const u8, session: SessionId) error{JobNotFound}!void {
        const e = self.acquireBackgroundForSession(id, session) orelse return error.JobNotFound;
        defer self.releaseBackground(e);
        e.abort.abort(.user_ctrl_c);
    }

    /// Abort either a foreground or background entry owned by `session`.
    /// The switcher includes foreground entries, so using the background-only
    /// reader lease there would report success while leaving the visible task
    /// running.
    pub fn abortForSession(self: *AgentJobRegistry, id: []const u8, session: SessionId) error{JobNotFound}!void {
        if (id.len > 16) return error.JobNotFound;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        const e = self.index.get(key) orelse return error.JobNotFound;
        e.lock();
        defer e.unlock();
        if (!std.mem.eql(u8, e.session.asSlice(), session.asSlice())) return error.JobNotFound;
        e.abort.abort(.user_ctrl_c);
        if (e.cancel_provider) |p| p.cancel(&e.abort);
    }

    /// 非阻塞 abort 所有 running job(esc 中断用)。**不 join**(watcher 线程调,不能阻塞)——
    /// 各 job 跑到检查点后自退。前台 Task 的 subagent 走 app.abort 已被中断;此处补齐**后台/嵌套**
    /// agent job(它们持自己的 entry.abort,app.abort 不触达)。返回触发的数量。幂等。
    pub fn abortAllRunning(self: *AgentJobRegistry) usize {
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const running = e.status == .running;
            e.unlock();
            if (running) {
                e.abort.abort(.user_ctrl_c);
                // 标志只在事件之间被检查;真的把连接 shutdown 才能叫醒卡在 readv 里的 worker。
                e.lock();
                if (e.cancel_provider) |p| p.cancel(&e.abort);
                e.unlock();
                n += 1;
            }
        }
        return n;
    }

    pub fn abortAllRunningForSession(self: *AgentJobRegistry, session: SessionId) usize {
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const owned_running = std.mem.eql(u8, e.session.asSlice(), session.asSlice()) and e.status == .running;
            if (owned_running) {
                e.abort.abort(.user_ctrl_c);
                if (e.cancel_provider) |p| p.cancel(&e.abort);
                n += 1;
            }
            e.unlock();
        }
        return n;
    }

    /// 造一个专属 OwnedProvider(据 parent 的 provider_kind 造对应具体 client + 独立 io_runtime,
    /// 堆分配,所有权归调用者)。供同步前台 Task 并发执行时每个 spawn 用独立 provider,避免跨线程
    /// 共享 App 的单例 client。调用者用完 `.deinit()`。P0.5:构造路径 provider-neutral。
    pub fn makeProvider(self: *AgentJobRegistry) !pf.OwnedProvider {
        // **线程安全铁律**:makeProvider 造的 Client 会在 **worker 线程**做 HTTP(后台 subagent /
        // TaskBatch 并发 worker),且主线程造它时可能与 App 的 io_runtime worker 线程并发。App 的
        // gpa(self.allocator)非线程安全并发访问会损坏(假 OOM/unreachable → SIGABRT,真机实测)。
        // 故用 c_allocator(malloc,线程安全)隔离。OwnedProvider 自带此 allocator,deinit 也用它,一致。
        self.listLock();
        defer self.listUnlock();
        var limits = self.limits;
        if (limits) |*value| value.catalog = if (self.catalog_snapshot) |*catalog| catalog else null;
        return pf.makeProviderWithOptions(
            std.heap.c_allocator,
            self.provider_kind,
            self.api_key,
            self.model,
            self.base_url,
            self.openai_protocol,
            self.dialect_resolver,
            .{ .auth_scheme = self.auth_scheme, .limits = limits, .stream_idle_timeout_ms = self.stream_idle_timeout_ms, .stream_body_idle_timeout_ms = self.stream_body_idle_timeout_ms },
        );
    }

    fn makeProviderForTool(raw: *anyopaque) anyerror!pf.OwnedProvider {
        const self: *AgentJobRegistry = @ptrCast(@alignCast(raw));
        return self.makeProvider();
    }

    /// Capability view used by tools that need a private HTTP client. Keeping
    /// construction here reuses the registry's owned provider configuration and
    /// its thread-safe c_allocator policy without exposing credentials.
    pub fn providerFactory(self: *AgentJobRegistry) pf.Factory {
        return .{ .ctx = @ptrCast(self), .makeFn = &makeProviderForTool };
    }

    /// Backwards-compatible single-session wrapper for library callers that do
    /// not have a session identity. Production dispatchers must use the
    /// session-aware entry point below.
    pub fn registerForeground(self: *AgentJobRegistry, agent_type: []const u8, desc: []const u8, prompt: []const u8) ?*JobEntry {
        return self.registerForegroundForSession(agent_type, desc, prompt, .single);
    }

    /// 前台(同步)job 注册:堆分配一个无线程的 running entry,返回稳定 *JobEntry
    /// 供 agent.zig 同步路径传 progress_state/usage_state。spawn 在主线程/并发批 worker
    /// 上同步驱动,进度经 trampoline 写入,被 watcher tickSpinner 拾取渲染。
    /// agent_type 从 desc 拆出(用于进度树按 type 分组)。失败返回 null(降级为无进度可见)。
    pub fn registerForegroundForSession(
        self: *AgentJobRegistry,
        agent_type: []const u8,
        desc: []const u8,
        prompt: []const u8,
        session: SessionId,
    ) ?*JobEntry {
        const a = self.allocator;
        const entry = a.create(JobEntry) catch return null;
        entry.* = .{ .allocator = a, .session = session };
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        entry.status = .running;
        entry.foreground = true;
        entry.desc_preview = dupeUtf8Preview(a, desc, 80) catch {
            a.destroy(entry);
            return null;
        };
        entry.agent_type = dupeUtf8Preview(a, agent_type, 32) catch &.{};
        entry.prompt_preview = dupeUtf8Preview(a, prompt, 4096) catch &.{};
        self.listLock();
        const id = self.genId();
        entry.id = id;
        entry.id_len = blk: {
            var n: u8 = 0;
            while (n < id.len and id[n] != 0) : (n += 1) {}
            break :blk n;
        };
        self.entries.append(a, entry) catch {
            self.listUnlock();
            freeEntry(entry);
            return null;
        };
        self.index.put(entry.id, entry) catch {
            _ = self.entries.pop();
            self.listUnlock();
            freeEntry(entry);
            return null;
        };
        self.listUnlock();
        return entry;
    }

    /// 前台 job 完成:持锁标记 done/失败 + 终值。entry 仍留在 registry(transient
    /// 进度树会在父轮结束 removeForeground 时移除)。
    pub fn finishForeground(self: *AgentJobRegistry, e: *JobEntry, turns: u32, tool_calls: u32, stop_reason: agent_loop.StopReason) void {
        _ = self;
        e.lock();
        e.turns = turns;
        e.tool_calls = tool_calls;
        e.stop_reason = stop_reason;
        e.flushPendingOutput();
        e.status = if (e.abort.isAborted()) .killed else .done;
        e.condition.broadcast();
        e.unlock();
    }

    /// 移除一个前台 entry(从 entries/index 摘除并释放)。仅前台(thread==null)可用。
    /// 父轮结束 / Region 1 transient 消失时调用。
    pub fn removeForeground(self: *AgentJobRegistry, e: *JobEntry) void {
        self.listLock();
        if (self.closing) {
            self.listUnlock();
            return;
        }
        _ = self.index.remove(e.id);
        for (self.entries.items, 0..) |it, i| {
            if (it == e) {
                _ = self.entries.swapRemove(i);
                break;
            }
        }
        self.listUnlock();
        freeEntry(e);
    }

    /// 拷贝某 agent 的 transcript(prompt + 工具行原料)到调用者 allocator。
    /// 区域2 Enter 查看 agent 上下文用。持锁 dup,无跨线程借用。找不到返 null。
    pub fn copyTranscript(self: *AgentJobRegistry, id: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        return self.copyTranscriptForSession(id, allocator, null);
    }

    /// Session-scoped transcript copy.  Keep the registry lock while taking
    /// the entry lock: foreground entries can be removed immediately after a
    /// parent tool returns, so a get-then-lock sequence would otherwise race
    /// `removeForeground` and dereference freed memory.
    pub fn copyTranscriptForSession(self: *AgentJobRegistry, id: []const u8, allocator: std.mem.Allocator, session: ?SessionId) !?[]u8 {
        if (id.len > 16) return null;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        const e = self.index.get(key) orelse return null;
        e.lock();
        defer e.unlock();
        if (session) |wanted| {
            if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) return null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (e.prompt_preview.len > 0) {
            try out.appendSlice(allocator, e.prompt_preview);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, e.transcript.items);
        return try out.toOwnedSlice(allocator);
    }

    /// 拷贝某 agent 的完整对话(prompt + output_buf 完整输出流)到调用者 allocator。
    /// agent switcher viewing 态主区显示被查看 subagent 对话用。持锁 dup 快照(被查看 agent
    /// 可能在跑、output_buf 在变 → 拷快照防 race)。找不到 id 返 null。owned,caller free。
    /// 与 copyTranscript 区别:本函数含 output_buf(助手文本+工具卡完整流),非只工具行。
    pub fn copyOutputBuf(self: *AgentJobRegistry, id: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        return self.copyOutputBufForSession(id, allocator, null);
    }

    /// Session-scoped output copy with the same list+entry lock ordering as
    /// `copyTranscriptForSession`.
    pub fn copyOutputBufForSession(self: *AgentJobRegistry, id: []const u8, allocator: std.mem.Allocator, session: ?SessionId) !?[]u8 {
        if (id.len > 16) return null;
        var key: [16]u8 = undefined;
        @memcpy(key[0..id.len], id);
        for (key[id.len..]) |*b| b.* = 0;
        self.listLock();
        defer self.listUnlock();
        const e = self.index.get(key) orelse return null;
        e.lock();
        defer e.unlock();
        if (session) |wanted| {
            if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) return null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (e.prompt_preview.len > 0) {
            try out.appendSlice(allocator, e.prompt_preview);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, e.output_buf.items);
        return try out.toOwnedSlice(allocator);
    }

    /// abort 全部 running → join 全部线程 → free。drain 循环覆盖迟注册的嵌套 job。
    pub fn deinit(self: *AgentJobRegistry) void {
        self.listLock();
        self.closing = true;
        self.listUnlock();
        // A spawn that passed admission may still be between publication and
        // Thread.spawn. Wait for that hand-off to finish before taking the
        // join snapshot, otherwise deinit could free an entry just before its
        // thread handle is assigned.
        while (true) {
            self.listLock();
            const starting = self.starting;
            self.listUnlock();
            if (starting == 0) break;
            util_time.sleepMs(1);
        }
        // drain:反复 abort + join,直到没有未 join 的线程。
        while (true) {
            // 快照当前 entries(持锁拷指针,join 时不持锁避免与线程注册死锁)
            self.listLock();
            const snapshot = self.allocator.dupe(*JobEntry, self.entries.items) catch self.entries.items;
            const own_snapshot = snapshot.ptr != self.entries.items.ptr;
            self.listUnlock();

            var pending = false;
            for (snapshot) |e| {
                e.abort.abort(.user_ctrl_c);
                if (e.thread) |t| {
                    t.join();
                    e.thread = null; // 标记已 join
                    pending = true; // 本轮有动作,可能有嵌套 job 在 join 期间注册
                }
            }
            if (own_snapshot) self.allocator.free(snapshot);
            if (!pending) break;
        }

        // TaskOutput may still be between lookup and its final snapshot. Its
        // reader reference is independent of the worker join above, so wait
        // before freeing the pointed-to JobEntry.
        while (true) {
            self.listLock();
            var readers = false;
            for (self.entries.items) |e| if (e.readers != 0) {
                readers = true;
                break;
            };
            self.listUnlock();
            if (!readers) break;
            util_time.sleepMs(1);
        }

        // Detach the pointer array under the list lock before freeing entries;
        // a concurrent foreground cleanup must not swapRemove the same slice
        // while teardown is iterating it. `closing` makes new spawns and
        // removeForeground no-ops, so the detached array is stable.
        self.listLock();
        var detached = self.entries;
        self.entries = .empty;
        self.index.clearRetainingCapacity();
        self.listUnlock();

        // 所有线程已退,单线程 free 每个 entry
        for (detached.items) |e| {
            freeEntry(e);
        }
        detached.deinit(self.allocator);
        self.index.deinit();
        // Workers may still consult the catalog while they are being joined.
        // Release it only after the join barrier, otherwise makeProvider can
        // read a freed catalog through the limits snapshot.
        if (self.catalog_snapshot) |*catalog| catalog.deinit();
        self.allocator.free(self.api_key);
        if (self.base_url) |u| self.allocator.free(u);
        self.allocator.free(self.model);
    }
};

/// 释放一个 entry 的所有 owned 内存 + destroy。调用前必须确保无线程再碰它
/// (deinit 已 join;foreground entry thread==null 单线程安全)。
fn freeEntry(e: *JobEntry) void {
    if (e.final_text) |ft| e.allocator.free(ft);
    e.output_buf.deinit(e.allocator);
    e.allocator.free(e.desc_preview);
    if (e.agent_type.len > 0) e.allocator.free(e.agent_type);
    if (e.prompt_preview.len > 0) e.allocator.free(e.prompt_preview);
    if (e.worktree_path.len > 0) e.allocator.free(e.worktree_path);
    e.transcript.deinit(e.allocator);
    e.allocator.destroy(e);
}

/// 后台线程主函数:跑 subagent,结果偷进 entry,cleanup input(不碰 entry 释放)。
fn jobThreadMain(input: *JobInput) void {
    const e = input.entry;

    var ctx_override = input.permission_ctx.scopedDerive(input.perm_override);

    // L1:JobEntry 自身就是 backend——流式 text 进 output_buf、进度/token 更新树字段,
    // 单通道(取代旧 WriterBackend+jobSink / progress / usage 三通道)。
    const be = e.backend();

    // JobInput owns this definition snapshot for the whole thread lifetime.
    // Use it as the execution ceiling as well as the advertised tool list.
    var child_tool_policy = @import("../tools/context.zig").ToolSetExecutionPolicy{
        .definitions = input.tool_defs_owned,
    };

    const opts = subagent.SpawnOptions{
        .max_turns = if (input.max_turns > 0) input.max_turns else 20,
        .session = input.session,
        .system_prompt = if (input.system_prompt.len > 0) input.system_prompt else null,
        .agent_depth = input.agent_depth,
        .dyn_registry = input.dyn_registry,
        .tool_defs_override = input.tool_defs_owned,
        .execution_policy = child_tool_policy.executionPolicy(),
        .permission_mode_override = input.perm_override,
        .model_override = input.model_override,
        .model_tiers = input.model_tiers,
        .reasoning_effort_override = input.reasoning_effort_override,
        .host_services = input.host_services,
        .project_dir = input.project_dir,
        .agent_jobs = input.registry, // 允许嵌套后台
        .kg = input.kg,
        .kg_projects_dir = input.kg_projects_dir,
        // task#12:后台 subagent 继承父 sandbox(否则 Bash 绕过用户 sandbox 配置)。
        .sandbox = input.sandbox,
        .cwd_abs = input.cwd_abs,
        .home_dir = input.home_dir,
        .artifact_root = input.artifact_root,
        .tool_result_metrics = input.tool_result_metrics,
        .file_change_journal = input.file_change_journal,
        .additional_dirs = input.additional_dirs,
        .mcp_sessions = &input.mcp_sessions_owned,
        // Ctrl+B 转后台:move 预建对话给 spawnAgentSink(它 defer deinit)。**move 后立即置 null**:
        // 单一所有者不变式——此后只有 opts/spawnAgentSink 持有,input.cleanup 不再 deinit(防 double-free)。
        .prebuilt_conversation = input.prebuilt_conversation,
    };
    input.prebuilt_conversation = null;

    e.lock();
    e.cancel_provider = input.owned.provider();
    e.unlock();
    // worker 结束(无论成败)都先撤下 cancel 视图,再由 input.cleanup() deinit owned。
    defer {
        e.lock();
        e.cancel_provider = null;
        e.unlock();
    }

    const result = subagent.spawnAgentSink(
        input.allocator,
        input.owned.provider(),
        input.owned.anthropicClient(),
        input.tool_defs_owned,
        &ctx_override,
        &e.abort,
        input.prompt,
        opts,
        &be,
    ) catch |err| {
        input.finalizeWorktree();
        e.lock();
        e.flushPendingOutput();
        e.status = .failed;
        e.err_name = @errorName(err);
        e.condition.broadcast();
        e.unlock();
        input.cleanup();
        return;
    };

    input.finalizeWorktree();
    e.lock();
    e.final_text = result.final_text; // 偷走所有权;不调 result.deinit()
    e.stop_reason = result.stop_reason;
    e.turns = result.turns;
    e.tool_calls = result.tool_calls;
    e.flushPendingOutput();
    e.status = if (e.abort.isAborted()) .killed else .done;
    e.condition.broadcast();
    e.unlock();

    input.cleanup();
}

const testing = std.testing;

test "AgentJobRegistry setModel updates future providers" {
    var reg = try AgentJobRegistry.init(testing.allocator, "test-key", "http://127.0.0.1:1", "old-model", .anthropic);
    defer reg.deinit();
    try reg.setModel("new-model");
    var owned = try reg.makeProvider();
    defer owned.deinit();
    // provider() 出中立 vtable,model 经具体 client 透传。
    try testing.expectEqualStrings("new-model", owned.provider().model());
}

test "clearTestEntries removes index keys before freeing entries" {
    var reg = try AgentJobRegistry.init(testing.allocator, "test-key", null, "test-model", .anthropic);
    defer reg.deinit();
    try reg.pushTestEntry("stale", 1, "", "");
    var id: [16]u8 = undefined;
    const entry = reg.entries.items[0];
    @memcpy(&id, &entry.id);
    reg.clearTestEntries();
    try std.testing.expect(reg.get(id[0..]) == null);
}

test "JobEntry backend 消费 CoreEvent.progress 实时回写 tool_calls(L1:#6 进度=事件)" {
    // #6 修复:执行中进度必须实时回写 tool_calls,否则 subagent 树恒显 `· 0 tools ·`。
    // L1 后:进度走 backend.emit(.progress)(取代旧 progressTrampoline 回调)。本测试经
    // JobEntry.backend() 的 emit 驱动,端到端验证 CoreEvent.progress → 树字段的接线。
    var reg = try AgentJobRegistry.init(testing.allocator, "test-key", "http://127.0.0.1:1", "test-model", .anthropic);
    defer reg.deinit();

    try reg.pushTestEntry("count files", 1, "", "");
    const entry = reg.entries.items[0];
    try testing.expectEqual(@as(u32, 0), entry.tool_calls);

    const be = entry.backend();
    // 模拟 agent_loop 上报:turn 2,刚调完第 5 个工具(Grep)。
    be.emitEvent(.single, .{ .progress = .{ .turn = 2, .tool_name = "Grep", .tool_input = "{\"pattern\":\"x\"}", .tool_calls = 5 } });

    const snaps = try reg.snapshotJobs(testing.allocator);
    defer AgentJobRegistry.freeSnapshots(testing.allocator, snaps);
    try testing.expectEqual(@as(usize, 1), snaps.len);
    try testing.expectEqual(JobStatus.running, snaps[0].status);
    try testing.expectEqual(@as(u32, 5), snaps[0].tool_calls);
    try testing.expectEqual(@as(u32, 2), snaps[0].current_turn);

    // 轮起始上报(空 tool_name)也刷新计数(early-return 之前回写)。
    be.emitEvent(.single, .{ .progress = .{ .turn = 3, .tool_name = "", .tool_input = "", .tool_calls = 7 } });
    const snaps2 = try reg.snapshotJobs(testing.allocator);
    defer AgentJobRegistry.freeSnapshots(testing.allocator, snaps2);
    try testing.expectEqual(@as(u32, 7), snaps2[0].tool_calls);

    // usage 事件回写 tokens(取最新 input+output 快照)。
    be.emitEvent(.single, .{ .usage = .{ .input_tokens = 1000, .output_tokens = 200 } });
    entry.lockPublic();
    const tok = entry.tokens;
    entry.unlockPublic();
    try testing.expectEqual(@as(u64, 1200), tok);

    // L1 行为:text_chunk 进 output_buf(前台 entry 也走本 backend,故流式 text 被填充)。
    be.emitEvent(.single, .{ .text_chunk = "hello " });
    be.emitEvent(.single, .{ .text_chunk = "world" });
    entry.lockPublic();
    const out = entry.output_buf.items;
    entry.unlockPublic();
    try testing.expectEqualStrings("hello world", out);
}

test "TaskOutput lookup is scoped to the job's origin session" {
    const a = testing.allocator;
    var reg = try AgentJobRegistry.init(a, "test-key", "http://127.0.0.1:1", "test-model", .anthropic);
    defer reg.deinit();

    try reg.pushTestEntry("session scoped", 1, "", "");
    const entry = reg.entries.items[0];
    entry.foreground = false;
    const owner = @import("session_id.zig").gen();
    const other = @import("session_id.zig").gen();
    entry.session = owner;
    try testing.expect(reg.getBackgroundForSession(entry.idSlice(), owner) != null);
    try testing.expect(reg.getBackgroundForSession(entry.idSlice(), other) == null);
    try testing.expectError(error.JobNotFound, reg.killForSession(entry.idSlice(), other));
    const owned = try reg.snapshotJobsForSession(testing.allocator, owner);
    defer AgentJobRegistry.freeSnapshots(testing.allocator, owned);
    try testing.expectEqual(@as(usize, 1), owned.len);
    const hidden = try reg.snapshotJobsForSession(testing.allocator, other);
    defer AgentJobRegistry.freeSnapshots(testing.allocator, hidden);
    try testing.expectEqual(@as(usize, 0), hidden.len);
}

test "foreground entries retain session identity for roster and viewing" {
    const a = testing.allocator;
    var reg = try AgentJobRegistry.init(a, "test-key", "http://127.0.0.1:1", "test-model", .anthropic);
    defer reg.deinit();
    const owner = @import("session_id.zig").gen();
    const other = @import("session_id.zig").gen();
    const entry = reg.registerForegroundForSession("Explore", "foreground", "prompt", owner) orelse return error.TestUnexpectedResult;
    defer reg.removeForeground(entry);
    entry.appendOutput("answer\n");

    const owned = try reg.snapshotJobsForSession(a, owner);
    defer AgentJobRegistry.freeSnapshots(a, owned);
    try testing.expectEqual(@as(usize, 1), owned.len);
    const hidden = try reg.snapshotJobsForSession(a, other);
    defer AgentJobRegistry.freeSnapshots(a, hidden);
    try testing.expectEqual(@as(usize, 0), hidden.len);

    const out = (try reg.copyOutputBufForSession(entry.idSlice(), a, owner)).?;
    defer a.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "answer\n"));
    try testing.expect((try reg.copyOutputBufForSession(entry.idSlice(), a, other)) == null);
}

test "spawnBackground prebuilt_conversation consume-on-call:失败路径不泄漏(R3)" {
    // Ctrl+B 转后台:spawnBackground 是 consume-on-call —— 失败路径必须释放传入的 prebuilt
    // conversation。填满 registry 触发 TooManyBackgroundJobs 早退,断言 testing.allocator 不报
    // 泄漏/double-free(=失败路径正确 deinit 了 prebuilt copy)。
    const a = testing.allocator;
    var reg = try AgentJobRegistry.init(a, "test-key", "http://127.0.0.1:1", "test-model", .anthropic);
    defer reg.deinit();

    var i: usize = 0;
    while (i < MAX_BG_JOBS) : (i += 1) {
        try reg.pushTestEntry("filler", 1, "", "");
        reg.entries.items[reg.entries.items.len - 1].foreground = false;
    }

    var copy = Conversation.init(a);
    try copy.appendText(.user, "continue this");
    try copy.appendText(.assistant, "ok");

    const r = reg.spawnBackground(.{
        .prompt = "",
        .system_prompt = "",
        .session = SessionId.single,
        .tool_defs = &.{},
        .permission_ctx = permission_mod.createContext(.bypass_permissions, a),
        .prebuilt_conversation = copy,
    });
    try testing.expectError(error.TooManyBackgroundJobs, r);
    // 不手动 deinit copy:consume 语义下失败路径已释放。testing.allocator 检查泄漏/double-free。
}

test "abortAllRunning:esc 中断 abort 所有 running agent job(非阻塞)" {
    // 用户实测 bug:启动多 agent 后 esc 不终止。根因:后台/嵌套 agent job 持自己的 entry.abort,
    // app.abort 不触达。esc 现调 abortAllRunning() 补齐。验证:对所有 running entry 置 abort、返回数量。
    const a = testing.allocator;
    var reg = try AgentJobRegistry.init(a, "k", "http://127.0.0.1:1", "m", .anthropic);
    defer reg.deinit();
    // pushTestEntry 造无线程的 running entry(状态 .running)。
    try reg.pushTestEntry("agent A", 1, "", "");
    try reg.pushTestEntry("agent B", 1, "", "");
    // 验证初始未 abort。
    try testing.expect(!reg.entries.items[0].abort.isAborted());
    try testing.expect(!reg.entries.items[1].abort.isAborted());

    const n = reg.abortAllRunning();
    try testing.expectEqual(@as(usize, 2), n);
    // 两个 running job 的 abort 都被触发。
    try testing.expect(reg.entries.items[0].abort.isAborted());
    try testing.expect(reg.entries.items[1].abort.isAborted());
    // 幂等:再调一次不报错(已 abort 的再 abort 无副作用)。
    _ = reg.abortAllRunning();
}

test "spawnBackground committed-flag:input.* 建好后失败也无泄漏(FailingAllocator,不 spawn 线程)" {
    // 用 FailingAllocator 在 spawnBackground 的 dupe/创建块中途失败,驱动 !committed errdefer 统一回滚
    // (含 prebuilt_conversation 深拷贝)。**只扫会在 Thread.spawn 之前失败的低 fail_index**——避免
    // 成功路径起真线程在失败 allocator 上跑出无关 OOM 泄漏。验证 committed-flag 模型在每个早期失败点
    // 都不泄漏、不 double-free(对照旧 spawn-fail 路径手动 cleanup+errdefer 共存的 double-free)。
    const base = testing.allocator;
    // spawnBackground 成功前的 alloc 次数(entry/io/client/input/各 dupe + task#12 的 cwd/home/
    // additional_dirs 深拷贝)约 20+ 次;扫 1..18 确保每次失败都落在 spawn 之前,**绝不到 Thread.spawn**。
    // 传非空 additional_dirs → 覆盖 task#12 深拷贝**循环中途失败**的 nad 计数回滚(Linus review DoD)。
    var n: usize = 1;
    while (n <= 18) : (n += 1) {
        var fa = std.testing.FailingAllocator.init(base, .{ .fail_index = n });
        const a = fa.allocator();
        // registry 自身 init 也要 alloc;init 失败就跳过该 index(本测试只关心 spawnBackground 内部回滚)。
        var reg = AgentJobRegistry.init(a, "k", "http://127.0.0.1:1", "m", .anthropic) catch continue;
        defer reg.deinit();

        var copy = Conversation.init(a);
        copy.appendText(.user, "hist") catch {
            copy.deinit();
            continue;
        };

        // 必失败(fail_index 落在 spawnBackground 内部);consume 语义释放 copy + errdefer 释放全部资源。
        // **覆盖盲区(诚实登记)**:本测试只能驱动 **alloc 失败** 路径(input.* 之前的各 dupe/create errdefer)。
        // 而 spawn-后的 un-register errdefer(line ~440)只在 **Thread.spawn 失败** 时触发——spawn 失败不是
        // alloc 失败,FailingAllocator 模拟不出。那条 errdefer 的正确性靠代码审查 + LIFO 顺序保证(un-register
        // 后注册→最先跑→在 destroy(entry) 前用有效指针 swapRemove),非本测试覆盖。
        const r = reg.spawnBackground(.{
            .prompt = "p",
            .system_prompt = "s",
            .session = SessionId.single,
            .tool_defs = &.{},
            .permission_ctx = permission_mod.createContext(.bypass_permissions, a),
            .desc = "main",
            .agent_type = "main",
            // task#12:非空 additional_dirs → 驱动深拷贝循环中途失败,验 nad 计数回滚无泄漏。
            .cwd_abs = "/cwd",
            .home_dir = "/home",
            .additional_dirs = &.{ "/dir/a", "/dir/b" },
            .prebuilt_conversation = copy,
        });
        // **硬警报**(Linus):本扫描区间(1..13)按设计 fail_index 永远落在 Thread.spawn 之前 → 必失败。
        // 若 spawnBackground 竟成功,说明有人在 spawn 前加了 alloc、13 这个边界过时了 → 测试退化成
        // "起真线程在失败 allocator 上跑出无关 OOM 泄漏"。与其悄悄 flaky,不如**响**:成功即报错,
        // 逼维护者把上界调到 spawn 前的真实 alloc 数。(reg.deinit defer 会 abort+join 误起的线程。)
        if (r) |_| {
            return error.TestFailIndexTooHigh; // 扫到了 spawn 成功路径——调小上界或对齐真实 alloc 数
        } else |_| {}
        // FailingAllocator 在 reg.deinit 后由 testing.allocator(base)检查:errdefer 必须已释放
        // copy + 所有 spawnBackground 内分配,否则报泄漏。
    }
}

test "copyOutputBuf: prompt_preview + output_buf 完整流;缺 id 返 null" {
    var reg = try AgentJobRegistry.init(testing.allocator, "test-key", "http://127.0.0.1:1", "test-model", .anthropic);
    defer reg.deinit();
    try reg.pushTestEntry("inspect repo", 1, "", "");
    const entry = reg.entries.items[0];
    // 模拟 subagent 输出流写进 output_buf。
    entry.appendOutput("⏺ 探索 backend\n");
    entry.appendOutput("  ⎿ Read main.go\n");

    const id = entry.idSlice();
    const out = (try reg.copyOutputBuf(id, testing.allocator)).?;
    defer testing.allocator.free(out);
    // 含 output_buf 内容(助手文本流)。
    try testing.expect(std.mem.indexOf(u8, out, "探索 backend") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read main.go") != null);

    // 缺失 id → null。
    try testing.expect((try reg.copyOutputBuf("agent_deadbeef", testing.allocator)) == null);
}

test "task#18: drainNewlyDone 排终态 job 一次(done_emitted 防重复)+ 跳 running" {
    const a = std.testing.allocator;
    var reg = try AgentJobRegistry.init(a, "k", null, "m", .anthropic);
    defer reg.deinit();
    // 一个 running + 两个终态(done/failed)。
    try reg.pushTestEntryFull("Explore", "r", 2, 50, "Grep", "{}", .running);
    try reg.pushTestEntryFull("Plan", "d1", 3, 100, "Read", "{}", .done);
    try reg.pushTestEntryFull("Task", "d2", 1, 20, "Bash", "{}", .failed);

    // 首次 drain:返回 2 个终态(done+failed),不含 running。
    const first = try reg.drainNewlyDone(a);
    defer AgentJobRegistry.freeDoneInfos(a, first);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    for (first) |d| {
        try std.testing.expect(d.status == .done or d.status == .failed);
        try std.testing.expectEqual(SessionId.single, d.session);
    }

    // 二次 drain:同样两个已 done_emitted → 返回空(不重复发)。
    const second = try reg.drainNewlyDone(a);
    defer AgentJobRegistry.freeDoneInfos(a, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "issue #16: setRoute moves key, endpoint, and transport together" {
    const a = std.testing.allocator;
    var reg = try AgentJobRegistry.init(a, "old-key", "https://old.invalid", "old-model", .anthropic);
    defer reg.deinit();

    try reg.setRoute(
        "new-key",
        "https://new.invalid/api/coding/paas/v4",
        .openai,
        .chat_completions,
        .{ .api_key_header = "x-api-key" },
    );
    try std.testing.expectEqualStrings("new-key", reg.api_key);
    try std.testing.expectEqualStrings("https://new.invalid/api/coding/paas/v4", reg.base_url.?);
    try std.testing.expectEqual(types_mod.ProviderKind.openai, reg.provider_kind);
    try std.testing.expect(reg.auth_scheme != null);
    // The model is a separate decision with its own seam; setRoute must not
    // silently reset it.
    try std.testing.expectEqualStrings("old-model", reg.model);
}

test "issue #16: a failed setRoute leaves the previous route completely intact" {
    const a = std.testing.allocator;
    var reg = try AgentJobRegistry.init(a, "old-key", "https://old.invalid", "old-model", .anthropic);
    defer reg.deinit();

    // Fail on the *second* allocation, so the key has already been duped: the
    // swap must still not have happened. A registry holding the new key while
    // pointing at the old endpoint would send the credential to the wrong
    // vendor, which is the whole reason these move together.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    reg.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, reg.setRoute(
        "new-key",
        "https://new.invalid",
        .openai,
        .chat_completions,
        null,
    ));
    reg.allocator = a;

    try std.testing.expectEqualStrings("old-key", reg.api_key);
    try std.testing.expectEqualStrings("https://old.invalid", reg.base_url.?);
    try std.testing.expectEqual(types_mod.ProviderKind.anthropic, reg.provider_kind);
}

test "AgentJobRegistry provider inherits and defaults its model limits" {
    const a = std.testing.allocator;
    var catalog = @import("../api/catalog.zig").Catalog.init(a);
    defer catalog.deinit();
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":64000,\"max_input_tokens\":1048576}]} ");
    var reg = try AgentJobRegistry.init(a, "test-key", null, "GLM-5.2", .anthropic);
    defer reg.deinit();
    try reg.setLimits(.{ .catalog = &catalog });
    catalog.deinit();
    catalog = @import("../api/catalog.zig").Catalog.init(a);
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":1111,\"max_input_tokens\":2222}]} ");
    var inherited = try reg.makeProvider();
    defer inherited.deinit();
    try std.testing.expectEqual(@as(u32, 64000), inherited.provider().maxTokensFor("glm-5.2"));
    try std.testing.expectEqual(@as(u32, 1048576), inherited.provider().maxInputTokensFor("GLM-5.2"));
    try reg.setLimits(.{ .catalog = &catalog });
    var refreshed = try reg.makeProvider();
    defer refreshed.deinit();
    try std.testing.expectEqual(@as(u32, 1111), refreshed.provider().maxTokensFor("GLM-5.2"));
    try std.testing.expectEqual(@as(u32, 2222), refreshed.provider().maxInputTokensFor("GLM-5.2"));
    try reg.setLimits(.{});
    var fallback = try reg.makeProvider();
    defer fallback.deinit();
    try std.testing.expectEqual(@as(u32, 32000), fallback.provider().maxTokensFor("GLM-5.2"));
    try std.testing.expectEqual(@as(u32, 200000), fallback.provider().maxInputTokensFor("GLM-5.2"));
}
