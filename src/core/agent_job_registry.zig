//! 后台 subagent 作业注册表(AgentJobRegistry)。
//!
//! 与 job_registry.zig(Bash 后台,fork 进程模型)的关键区别:
//! 后台 subagent 是**同进程线程**模型——每个 job 在自己的 std.Thread 里跑
//! subagent.spawnAgent(网络 + 工具循环),不是 fork 子进程。
//!
//! 设计(见 doc plan / SUBAGENT_DESIGN):
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
const client_mod = @import("../client.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const subagent = @import("subagent.zig");
const agent_loop = @import("agent_loop.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const AgentSet = @import("../agents/set.zig").AgentSet;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const SkillSet = @import("../skills/skill.zig").SkillSet;

/// 同时存在的后台 job 上限。防线程爆炸 + API 速率打爆。
pub const MAX_BG_JOBS: usize = 8;

pub const JobStatus = enum { running, done, failed, killed };

/// 后台 subagent 的一个作业。堆分配,地址稳定(线程与主线程共享 *JobEntry)。
pub const JobEntry = struct {
    id: [16]u8 = undefined, // "agent_" + 8 hex + NUL pad
    id_len: u8 = 0,
    /// 保护下列 status/output_buf/final_text/stop_reason/turns/tool_calls/err_name。
    mutex: std.c.pthread_mutex_t = .{},
    status: JobStatus = .running,
    /// 增量输出缓冲。线程边跑边 append(持锁);TaskOutput since_byte 增量读。
    output_buf: std.ArrayList(u8) = .empty,
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
    allocator: std.mem.Allocator,
    started_ms: util_time.Millis = 0,
    desc_preview: []u8 = &.{}, // owned

    pub fn idSlice(self: *const JobEntry) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn lockPublic(self: *JobEntry) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlockPublic(self: *JobEntry) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn lock(self: *JobEntry) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *JobEntry) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// 线程持锁写一段流式输出。
    fn appendOutput(self: *JobEntry, bytes: []const u8) void {
        self.lock();
        defer self.unlock();
        self.output_buf.appendSlice(self.allocator, bytes) catch {};
    }

    /// agent_loop progress 回调的 trampoline:持锁更新 current_turn/current_tool/input。
    /// 经 opts.progress_state(*JobEntry erased)+ progress_fn 注入,见 jobThreadMain。
    pub fn progressTrampoline(state: *anyopaque, turn: u32, tool_name: []const u8, tool_input: []const u8) void {
        const self: *JobEntry = @ptrCast(@alignCast(state));
        self.lock();
        defer self.unlock();
        self.current_turn = turn;
        // 空 tool_name = 仅推进轮次(轮开始上报),**保留**上一个工具——对齐 cc
        // "持续显示最近动作"语义。否则工具执行窗口短于一帧时动作行几乎不可见。
        if (tool_name.len == 0) return;
        const n = @min(tool_name.len, self.current_tool.len);
        @memcpy(self.current_tool[0..n], tool_name[0..n]);
        self.current_tool_len = @intCast(n);
        const m = @min(tool_input.len, self.current_tool_input.len);
        @memcpy(self.current_tool_input[0..m], tool_input[0..m]);
        self.current_tool_input_len = @intCast(m);
    }
};

/// 启动后台 job 所需的全部参数。调用方(agent.zig)填好后交给 spawnBackground,
/// 由 registry 内部 dupe 进堆分配的 JobInput。
pub const SpawnParams = struct {
    prompt: []const u8,
    system_prompt: []const u8,
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
    perm_override: ?@import("../types.zig").PermissionMode = null,
    project_dir: []const u8 = "",
    parent_model: []const u8 = "",
    desc: []const u8 = "",
    activate_skill_state: ?*anyopaque = null,
    activate_skill_fn: ?*const fn (state: *anyopaque, skill_name: []const u8, allowed: []const []const u8, disallowed: []const []const u8) anyerror!void = null,
};

/// 线程拥有的输入。线程结束时自行 cleanup(free dupe + client/io deinit + destroy)。
const JobInput = struct {
    allocator: std.mem.Allocator,
    entry: *JobEntry,
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
    // 值拷贝:
    permission_ctx: permission_mod.PermissionContext,
    perm_override: ?@import("../types.zig").PermissionMode,
    agent_depth: u8,
    max_turns: u32,
    // 借用(App 生命周期):
    agents: ?*const AgentSet,
    dyn_registry: ?*const DynRegistry,
    skills: ?*const SkillSet,
    activate_skill_state: ?*anyopaque,
    activate_skill_fn: ?*const fn (state: *anyopaque, skill_name: []const u8, allowed: []const []const u8, disallowed: []const []const u8) anyerror!void,
    // 专属资源:
    io_runtime: *std.Io.Threaded,
    client: *client_mod.Client,
    // 嵌套后台:子 agent 也能 Task(run_in_background) 注册进同一 root registry。
    registry: *AgentJobRegistry,

    fn cleanup(self: *JobInput) void {
        const a = self.allocator;
        a.free(self.prompt);
        a.free(self.system_prompt);
        for (self.desc_copies) |d| a.free(d);
        a.free(self.desc_copies);
        a.free(self.tool_defs_owned);
        a.free(self.project_dir);
        a.free(self.parent_model);
        if (self.model_override) |m| a.free(m);
        self.client.deinit();
        a.destroy(self.client);
        self.io_runtime.deinit();
        a.destroy(self.io_runtime);
        a.destroy(self);
    }
};

/// 把后台 subagent 的流式输出导进 entry.output_buf 的 writer。
/// 替代 subagent 默认的 NullWriter,实现增量可见。
const SinkWriter = struct {
    entry: *JobEntry,
    pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        // 小段格式化到栈/临时,再持锁 append。常见是单段 text delta。
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            // 超长:退化为分配一次
            const big = std.fmt.allocPrint(self.entry.allocator, fmt, args) catch return;
            defer self.entry.allocator.free(big);
            self.entry.appendOutput(big);
            return;
        };
        self.entry.appendOutput(s);
    }
};

pub const AgentJobRegistry = struct {
    allocator: std.mem.Allocator,
    list_mutex: std.c.pthread_mutex_t = .{},
    entries: std.ArrayList(*JobEntry) = .empty,
    index: std.AutoHashMap([16]u8, *JobEntry),
    // 造 per-job Client 用(dupe 自 App):
    api_key: []u8,
    base_url: ?[]u8,
    model: []u8,
    seq: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        model: []const u8,
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
        };
    }

    fn listLock(self: *AgentJobRegistry) void {
        _ = std.c.pthread_mutex_lock(&self.list_mutex);
    }
    fn listUnlock(self: *AgentJobRegistry) void {
        _ = std.c.pthread_mutex_unlock(&self.list_mutex);
    }

    /// running job 计数(持 list 锁)。TUI(TaskTab)用。
    pub fn runningCount(self: *AgentJobRegistry) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            const running = e.status == .running;
            e.unlock();
            if (running) n += 1;
        }
        return n;
    }

    fn genId(self: *AgentJobRegistry) [16]u8 {
        self.seq +%= 1;
        var raw: [4]u8 = undefined;
        const fd = std.c.open("/dev/urandom", std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            _ = std.c.read(fd, &raw, raw.len);
        } else {
            // 退化:用 seq + 时间低位
            const t: u32 = @truncate(@as(u64, @bitCast(util_time.nowMs())));
            raw = @bitCast(t ^ self.seq);
        }
        var id: [16]u8 = undefined;
        // "agent_" (6) + 8 hex = 14 字节;余 NUL
        const written = std.fmt.bufPrint(&id, "agent_{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3] }) catch unreachable;
        for (id[written.len..]) |*b| b.* = 0;
        return id;
    }

    /// 启动后台 job,立即返回 id(指向 entry.id,registry 存活期间有效)。
    pub fn spawnBackground(self: *AgentJobRegistry, p: SpawnParams) ![]const u8 {
        if (self.runningCount() >= MAX_BG_JOBS) return error.TooManyBackgroundJobs;

        const a = self.allocator;

        // 1) 堆分配 entry(地址稳定)
        const entry = try a.create(JobEntry);
        errdefer a.destroy(entry);
        entry.* = .{ .allocator = a };
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        const id = self.genId();
        entry.id = id;
        entry.id_len = blk: {
            var n: u8 = 0;
            while (n < id.len and id[n] != 0) : (n += 1) {}
            break :blk n;
        };
        entry.desc_preview = try a.dupe(u8, p.desc[0..@min(p.desc.len, 80)]);
        errdefer a.free(entry.desc_preview);

        // 2) 专属 io_runtime + Client(堆分配,所有权给 JobInput)
        const io_rt = try a.create(std.Io.Threaded);
        errdefer a.destroy(io_rt);
        io_rt.* = std.Io.Threaded.init(a, .{});
        errdefer io_rt.deinit();

        const client = try a.create(client_mod.Client);
        errdefer a.destroy(client);
        client.* = client_mod.Client.initWithBaseUrl(a, io_rt.io(), self.api_key, self.model, self.base_url);
        errdefer client.deinit();

        // 3) dupe 所有借用内存进 JobInput(必须在 spawn 之前)
        const input = try a.create(JobInput);
        errdefer a.destroy(input);
        const prompt_owned = try a.dupe(u8, p.prompt);
        errdefer a.free(prompt_owned);
        const sys_owned = try a.dupe(u8, p.system_prompt);
        errdefer a.free(sys_owned);
        const defs_owned = try a.dupe(json_mod.ToolDefinition, p.tool_defs);
        errdefer a.free(defs_owned);
        // 深拷贝每个 description 进 job 内存(父 execute 返回后原串被释放 → 否则 UAF)。
        // name/input_schema/server_type 指向静态注册表,长生命周期,浅拷贝即可。
        const desc_copies = try a.alloc([]u8, defs_owned.len);
        errdefer a.free(desc_copies);
        var nd: usize = 0;
        errdefer for (desc_copies[0..nd]) |d| a.free(d);
        for (defs_owned, 0..) |*d, di| {
            const c = try a.dupe(u8, d.description);
            desc_copies[di] = c;
            nd = di + 1;
            d.description = c;
        }
        const pdir_owned = try a.dupe(u8, p.project_dir);
        errdefer a.free(pdir_owned);
        const pmodel_owned = try a.dupe(u8, p.parent_model);
        errdefer a.free(pmodel_owned);
        const mover_owned: ?[]u8 = if (p.model_override) |m| try a.dupe(u8, m) else null;
        errdefer if (mover_owned) |m| a.free(m);

        input.* = .{
            .allocator = a,
            .entry = entry,
            .prompt = prompt_owned,
            .system_prompt = sys_owned,
            .tool_defs_owned = defs_owned,
            .desc_copies = desc_copies,
            .project_dir = pdir_owned,
            .parent_model = pmodel_owned,
            .model_override = mover_owned,
            .permission_ctx = p.permission_ctx,
            .perm_override = p.perm_override,
            .agent_depth = p.agent_depth,
            .max_turns = p.max_turns,
            .agents = p.agents,
            .dyn_registry = p.dyn_registry,
            .skills = p.skills,
            .activate_skill_state = p.activate_skill_state,
            .activate_skill_fn = p.activate_skill_fn,
            .io_runtime = io_rt,
            .client = client,
            .registry = self,
        };

        // 4) 注册进 entries + index(持 list 锁),在 spawn 之前——保证 id 立即可查
        self.listLock();
        self.entries.append(a, entry) catch |e| {
            self.listUnlock();
            return e;
        };
        self.index.put(entry.id, entry) catch {};
        self.listUnlock();

        // 5) spawn 线程。spawn 成功后所有权(input/entry/client/io)归线程 + registry,
        //    上面的 errdefer 不再触发(已过)。
        entry.thread = std.Thread.spawn(.{}, jobThreadMain, .{input}) catch |e| {
            // spawn 失败:回滚——从 registry 摘掉 + cleanup input + destroy entry
            self.listLock();
            _ = self.index.remove(entry.id);
            for (self.entries.items, 0..) |it, i| {
                if (it == entry) {
                    _ = self.entries.swapRemove(i);
                    break;
                }
            }
            self.listUnlock();
            input.cleanup(); // free dupe + client/io deinit + destroy input
            a.free(entry.desc_preview);
            a.destroy(entry);
            return e;
        };

        log.info("agent", "background job spawned id={s} desc={s}", .{ entry.idSlice(), entry.desc_preview });
        return entry.idSlice();
    }

    /// 测试专用:注册一个**无线程**的假 running entry(供离线 TTY 验证 agent 进度树)。
    /// 不 spawn 线程、不开网络。entry 由 registry deinit 时统一释放(无 thread → join 跳过)。
    pub fn pushTestEntry(self: *AgentJobRegistry, desc: []const u8, turn: u32, tool: []const u8, tool_input: []const u8) !void {
        const a = self.allocator;
        const entry = try a.create(JobEntry);
        errdefer a.destroy(entry);
        entry.* = .{ .allocator = a };
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        const id = self.genId();
        entry.id = id;
        entry.id_len = blk: {
            var n: u8 = 0;
            while (n < id.len and id[n] != 0) : (n += 1) {}
            break :blk n;
        };
        entry.desc_preview = try a.dupe(u8, desc[0..@min(desc.len, 80)]);
        entry.status = .running;
        entry.current_turn = turn;
        const tn = @min(tool.len, entry.current_tool.len);
        @memcpy(entry.current_tool[0..tn], tool[0..tn]);
        entry.current_tool_len = @intCast(tn);
        const tin = @min(tool_input.len, entry.current_tool_input.len);
        @memcpy(entry.current_tool_input[0..tin], tool_input[0..tin]);
        entry.current_tool_input_len = @intCast(tin);
        self.listLock();
        self.entries.append(a, entry) catch |e| {
            self.listUnlock();
            a.free(entry.desc_preview);
            a.destroy(entry);
            return e;
        };
        self.index.put(entry.id, entry) catch {};
        self.listUnlock();
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
    };

    pub fn snapshotJobs(self: *AgentJobRegistry, allocator: std.mem.Allocator) ![]JobSnapshot {
        self.listLock();
        defer self.listUnlock();
        var out = try allocator.alloc(JobSnapshot, self.entries.items.len);
        var i: usize = 0;
        for (self.entries.items) |e| {
            e.lock();
            defer e.unlock();
            out[i] = .{
                .id = try allocator.dupe(u8, e.idSlice()),
                .status = e.status,
                .desc = try allocator.dupe(u8, e.desc_preview),
                .turns = e.turns,
                .tool_calls = e.tool_calls,
                .current_turn = e.current_turn,
                .current_tool = try allocator.dupe(u8, e.current_tool[0..e.current_tool_len]),
                .current_tool_input = try allocator.dupe(u8, e.current_tool_input[0..e.current_tool_input_len]),
            };
            i += 1;
        }
        return out;
    }

    pub fn freeSnapshots(allocator: std.mem.Allocator, snaps: []JobSnapshot) void {
        for (snaps) |s| {
            allocator.free(s.id);
            allocator.free(s.desc);
            allocator.free(s.current_tool);
            allocator.free(s.current_tool_input);
        }
        allocator.free(snaps);
    }

    /// 终止一个后台 job(只 abort,非阻塞)。状态由线程跑到检查点后自置 .killed。
    /// 幂等:对已结束 job 调用安全(abort 标志无副作用)。
    pub fn kill(self: *AgentJobRegistry, id: []const u8) error{JobNotFound}!void {
        const e = self.get(id) orelse return error.JobNotFound;
        e.abort.abort(.user_ctrl_c);
    }

    /// abort 全部 running → join 全部线程 → free。drain 循环覆盖迟注册的嵌套 job。
    pub fn deinit(self: *AgentJobRegistry) void {
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

        // 所有线程已退,单线程 free 每个 entry
        for (self.entries.items) |e| {
            if (e.final_text) |ft| e.allocator.free(ft);
            e.output_buf.deinit(e.allocator);
            e.allocator.free(e.desc_preview);
            e.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
        self.index.deinit();
        self.allocator.free(self.api_key);
        if (self.base_url) |u| self.allocator.free(u);
        self.allocator.free(self.model);
    }
};

/// 后台线程主函数:跑 subagent,结果偷进 entry,cleanup input(不碰 entry 释放)。
fn jobThreadMain(input: *JobInput) void {
    const e = input.entry;

    var ctx_override = input.permission_ctx;
    if (input.perm_override) |m| ctx_override.mode = m;

    var sink = SinkWriter{ .entry = e };

    const opts = subagent.SpawnOptions{
        .max_turns = if (input.max_turns > 0) input.max_turns else 20,
        .system_prompt = if (input.system_prompt.len > 0) input.system_prompt else null,
        .agent_depth = input.agent_depth,
        .dyn_registry = input.dyn_registry,
        .tool_defs_override = input.tool_defs_owned,
        .permission_mode_override = input.perm_override,
        .model_override = input.model_override,
        .activate_skill_state = input.activate_skill_state,
        .activate_skill_fn = input.activate_skill_fn,
        .project_dir = input.project_dir,
        .agent_jobs = input.registry, // 允许嵌套后台
        // 实时进度回写:agent_loop 每轮/每工具调 trampoline,持锁更新 e.current_turn/tool。
        .progress_state = @ptrCast(e),
        .progress_fn = &JobEntry.progressTrampoline,
    };

    const result = subagent.spawnAgentSink(
        input.allocator,
        input.client,
        input.tool_defs_owned,
        &ctx_override,
        &e.abort,
        input.prompt,
        opts,
        &sink,
    ) catch |err| {
        e.lock();
        e.status = .failed;
        e.err_name = @errorName(err);
        e.unlock();
        input.cleanup();
        return;
    };

    e.lock();
    e.final_text = result.final_text; // 偷走所有权;不调 result.deinit()
    e.stop_reason = result.stop_reason;
    e.turns = result.turns;
    e.tool_calls = result.tool_calls;
    e.status = if (e.abort.isAborted()) .killed else .done;
    e.unlock();

    input.cleanup();
}
