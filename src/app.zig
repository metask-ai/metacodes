//! App 应用生命周期：持有所有顶层组件（Config, Conversation, Client, ToolDefs, Permission, AbortSignal）。
//!
//! 目的：让 main.zig 只负责参数解析 + 启动 App。所有业务状态和循环逻辑从 main.zig 下沉到
//! 此模块 + core/agent_loop.zig。
//!
//! M1.5 起加入 AbortSignal + SIGINT 绑定。signal handler 只做 atomic store，async-signal-safe。

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
const json_mod = @import("json.zig");
const tools_mod = @import("tools.zig");
const permission_mod = @import("permission.zig");
const Conversation = @import("core/conversation.zig").Conversation;
const AbortSignal = @import("util/abort.zig").AbortSignal;
const SkillSet = @import("skills/skill.zig").SkillSet;
const ReadState = @import("core/read_state.zig").ReadState;
const transcript = @import("core/transcript.zig");
const pricing = @import("util/pricing.zig");
const agent_loop = @import("core/agent_loop.zig");
const api_stream = @import("api/stream.zig");
const JobRegistry = @import("core/job_registry.zig").JobRegistry;
const TaskStore = @import("core/task_store.zig").TaskStore;
const system_prompt_mod = @import("core/system_prompt.zig");

pub const UsageTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,

    pub fn apply(self: *UsageTotals, d: api_stream.UsageDelta) void {
        self.input_tokens += d.input_tokens;
        self.output_tokens += d.output_tokens;
        self.cache_read_input_tokens += d.cache_read_input_tokens;
        self.cache_creation_input_tokens += d.cache_creation_input_tokens;
    }

    pub fn costUsd(self: *const UsageTotals, model: []const u8) f64 {
        return pricing.computeCost(
            pricing.rateFor(model),
            self.input_tokens,
            self.output_tokens,
            self.cache_read_input_tokens,
            self.cache_creation_input_tokens,
        );
    }
};

/// 给 agent_loop 用的 trampoline：把 *anyopaque 还原成 *UsageTotals。
fn usageTotalsAdd(ctx: *anyopaque, d: api_stream.UsageDelta) void {
    const self: *UsageTotals = @ptrCast(@alignCast(ctx));
    self.apply(d);
}

/// 全局 AbortSignal 指针，供 signal handler 访问。installSigintHandler 绑定后非 null。
/// signal handler 只读该指针 + 调 abort.abort()——不分配、不 IO、不获锁。
var g_abort_signal: ?*AbortSignal = null;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    api_key: []const u8,
    conversation: Conversation,
    api_client: client_mod.Client,
    tool_defs: []json_mod.ToolDefinition,
    permission_ctx: permission_mod.PermissionContext,
    abort: AbortSignal,
    skills: SkillSet,
    read_state: ReadState,
    /// Session transcript writer；失败初始化则保持 null（日志落盘 fallback）
    transcript_writer: ?transcript.Writer = null,
    /// 本 session 累计用量（跨多 turn）
    usage: UsageTotals = .{},
    /// 从 config.json 加载的细粒度权限规则；null 时仅靠四模式兜底
    rule_set: ?permission_mod.RuleSet = null,
    /// 后台 Bash 作业注册表（失败初始化则 null）
    jobs: ?JobRegistry = null,
    /// 进入 plan 模式前的原 mode；ExitPlanMode 用它恢复
    plan_prev_mode: ?types.PermissionMode = null,
    /// 模型长任务 scratchpad（Task* 工具共享）
    tasks: TaskStore,
    /// 预构造的 system prompt（app 启动时一次性 build）。null = build 失败时降级为无 prompt。
    system_prompt: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: types.Config,
        api_key: []const u8,
    ) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const tool_defs = try tools_mod.toToolDefinitions(allocator);
        errdefer allocator.free(tool_defs);

        app.* = .{
            .allocator = allocator,
            .config = config,
            .api_key = api_key,
            .conversation = Conversation.init(allocator),
            .api_client = client_mod.Client.init(allocator, io, api_key, config.model),
            .tool_defs = tool_defs,
            .permission_ctx = permission_mod.createContext(config.permission_mode, allocator),
            .abort = AbortSignal.init(),
            .skills = SkillSet.init(allocator),
            .read_state = ReadState.init(allocator),
            .tasks = TaskStore.init(allocator),
        };

        // 启动时加载 skills：project CWD + $HOME
        app.skills.loadFromStandardPaths("") catch {};

        // 探测 <base_url>/v1/models 取 model catalog（max_tokens）。失败静默，走本地 fallback。
        app.api_client.probeModels();
        // CLI --max-tokens 覆盖
        app.api_client.setMaxTokensOverride(config.max_tokens);

        // 初始化 transcript writer：需要 cwd + HOME
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "init failed: {s} (session will not persist)", .{@errorName(err)});
        };

        // 从 config.json 加载 permission_rules
        app.loadPermissionRules() catch |err| {
            @import("util/log.zig").debug("permission", "no rules loaded: {s}", .{@errorName(err)});
        };

        // 初始化 job registry
        app.jobs = JobRegistry.init(allocator) catch |err| blk: {
            @import("util/log.zig").warn("job", "registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        // 构造 system prompt（依赖 config.model）。失败仅 log，保持 null。
        app.system_prompt = system_prompt_mod.build(allocator, config.model) catch |err| blk: {
            @import("util/log.zig").warn("sysprompt", "build failed: {s} (continuing without system prompt)", .{@errorName(err)});
            break :blk null;
        };

        return app;
    }

    pub fn deinit(app: *App) void {
        if (app.transcript_writer) |*w| w.deinit();
        app.api_client.deinit();
        app.conversation.deinit();
        app.allocator.free(app.tool_defs);
        app.skills.deinit();
        app.read_state.deinit();
        app.tasks.deinit();
        if (app.rule_set) |*r| r.deinit();
        if (app.jobs) |*j| j.deinit();
        if (app.system_prompt) |s| app.allocator.free(s);
        app.allocator.destroy(app);
    }

    fn initTranscriptWriter(app: *App) !void {
        // HOME
        const home_z = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_z);

        const cwd = try @import("util/fs.zig").getCwd(app.allocator);
        defer app.allocator.free(cwd);

        const w = try transcript.Writer.init(app.allocator, cwd, home, app.config.model);
        app.transcript_writer = w;
    }

    /// Agent loop 每轮结束后调用一次，把 conversation 新增的 message 刷到 transcript。
    pub fn persistTranscript(app: *App) void {
        if (app.transcript_writer) |*w| w.flush(&app.conversation);
    }

    /// 获取 agent_loop 能用的 UsageSink（把 event 累加到 app.usage）。
    pub fn usageSink(app: *App) agent_loop.UsageSink {
        return .{ .ctx = @ptrCast(&app.usage), .addFn = usageTotalsAdd };
    }

    /// 从 ~/.cc-zig/config.json 读 permission_rules 数组。失败仅 log，不影响启动。
    /// 同时把加载的 rule_set 绑到 permission_ctx.rules。
    fn loadPermissionRules(app: *App) !void {
        const home_c = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_c);
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/.cc-zig/config.json\x00", .{home});
        const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.NotFound;
        defer _ = std.c.close(fd);

        var all = std.ArrayList(u8).empty;
        defer all.deinit(app.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try all.appendSlice(app.allocator, buf[0..@intCast(n)]);
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, app.allocator, all.items, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        const rules_v = root.object.get("permission_rules") orelse return;
        if (rules_v != .array) return;

        var rs = permission_mod.RuleSet.init(app.allocator);
        errdefer rs.deinit();

        for (rules_v.array.items) |rv| {
            if (rv != .object) continue;
            const match_v = rv.object.get("match") orelse continue;
            const dec_v = rv.object.get("decision") orelse continue;
            if (match_v != .object or dec_v != .string) continue;

            const tool_v = match_v.object.get("tool") orelse continue;
            if (tool_v != .string) continue;

            const d: permission_mod.PermissionResult = if (std.mem.eql(u8, dec_v.string, "allow"))
                .allow
            else if (std.mem.eql(u8, dec_v.string, "deny"))
                .deny
            else if (std.mem.eql(u8, dec_v.string, "ask"))
                .ask
            else
                continue;

            const cmd_prefix = if (match_v.object.get("command_prefix")) |v|
                (if (v == .string) try app.allocator.dupe(u8, v.string) else null)
            else
                null;
            const path_glob = if (match_v.object.get("path_glob")) |v|
                (if (v == .string) try app.allocator.dupe(u8, v.string) else null)
            else
                null;

            try rs.append(.{
                .tool = try app.allocator.dupe(u8, tool_v.string),
                .command_prefix = cmd_prefix,
                .path_glob = path_glob,
                .decision = d,
            });
        }

        app.rule_set = rs;
        app.permission_ctx.rules = &app.rule_set.?;
        @import("util/log.zig").info("permission", "loaded {d} rule(s) from config", .{app.rule_set.?.rules.items.len});
    }

    /// 把 app.abort 绑到进程级 SIGINT handler。只需调用一次。
    /// 再次按 Ctrl+C 时，handler 会 atomic-store true；主循环通过 isAborted() 观察。
    pub fn installSigintHandler(app: *App) !void {
        g_abort_signal = &app.abort;

        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = sigintHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
};

/// Signal handler: async-signal-safe (仅 atomic store)。
fn sigintHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (g_abort_signal) |s| {
        s.abort(.user_ctrl_c);
    }
}

test "App init/deinit" {
    // 注意：init.io 在测试环境下不易构造，这里只校验 init/deinit 签名可用。
    // 真正的初始化测试放在集成测试层。
    _ = App;
}

