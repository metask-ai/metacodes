const std = @import("std");

/// 通用配置
pub const Config = struct {
    api_key: ?[]const u8 = null,
    /// Stable actor-visible identity used only in the system prompt.  The
    /// transport/request model remains `model`; keeping these separate lets a
    /// proxy use run-specific route names without leaking them into the
    /// cacheable prompt prefix.
    model_display_name: ?[]const u8 = null,
    model: []const u8 = "claude-sonnet-4-20250514",
    model_explicit: bool = false,
    reasoning_effort: ?ReasoningEffort = null,
    /// 方言字段覆盖(null = profile 默认,见 RequestOverrides)。
    /// CLI --temperature/--top-p/--prompt-cache-key/--parallel-tool-calls/--response-format 填充。
    /// App.init 塞 OpenAIClient/GeminiClient.overrides(Anthropic 不支持方言字段,忽略)。
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    prompt_cache_key: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    /// "json_object" / "json_schema"。null = 不发 response_format。
    response_format: ?[]const u8 = null,
    /// 每次请求的 max_tokens。null = 根据 model 自动挑（util/model.zig 查表）；
    /// 非 null = 用户 CLI 明确指定的值，尊重覆盖。
    max_tokens: ?u32 = null,
    permission_mode: PermissionMode = .prompt,
    no_theme: bool = false,
    verbose: bool = false,
    /// LSP 被动诊断(Y2):`--lsp` 开启。opt-in——默认关,保持零依赖 + 零启动开销。
    lsp_enabled: bool = false,
    /// Swarm(teams/teammates):`--agent-teams` 开启。opt-in——默认关,不污染单 agent 会话
    /// 的工具菜单(对齐 cc agentSwarmsEnabled 门)。
    agent_teams: bool = false,
    /// Long-horizon evaluation ablation. `native` preserves the product's normal
    /// behavior; the three explicit arms are injected only by the evaluation
    /// runner so one binary can be compared without revision drift.
    long_horizon_arm: LongHorizonArm = .native,
    /// SW6 进程外 teammate 身份(lead fork+exec 时经 CLI 注入;非 null → 进 teammate 进程模式,
    /// 不进 REPL)。teammate_name 非空即触发。cwd 非空则启动时 chdir(worktree 隔离)。
    teammate_name: []const u8 = "",
    teammate_team: []const u8 = "",
    teammate_parent_session: []const u8 = "",
    teammate_cwd: []const u8 = "",
    /// SW6:lead 用 `--teammate-mode process` 让 Task(name) spawn 进程外 teammate(fork+exec +
    /// worktree 隔离)而非进程内线程。默认 false(进程内,SW1)。
    teammate_out_of_process: bool = false,
    /// 编辑器模式:false=emacs(默认) / true=vim。`/vim` 命令切换。
    vim_mode: bool = false,
    /// Headless 模式：非 null 时跑单次 prompt 后退出，不进 REPL。
    /// 来源：`-p "..."` / `--print "..."`，或 `-`（从 stdin 读全部）。
    prompt: ?[]const u8 = null,
    /// `--json`：headless 下用 NDJSON 事件流输出，便于 CI/脚本消费。
    json_output: bool = false,
    /// `--dump-prompt`：构造完 system prompt + 工具 defs 后打印到 stdout 并退出，
    /// 不发网络、不需 API key。用于验证提示词×工具复刻。
    dump_prompt: bool = false,
    /// `--web [port]`:起 web UI(HTTP+SSE)驱动 agent loop,不进 TUI REPL。
    /// null = 不启用;0 = 内核分配端口(启动时打印真实端口)。
    web_port: ?u16 = null,
    /// **U10-D:`serve [port]`**:daemon 模式(经 SessionRegistry+SessionHost 跑 session,SIGINT 优雅
    /// 关停)。当前单 session MVP(多 session /s/<id>/* = U10-C)。null=不启用;0=内核分配端口。
    serve_port: ?u16 = null,
    /// **U10-C:`serve --sessions N`**:daemon 宿主的静态 session 数(默认 1=单 session serve)。
    /// >1 → serveMulti(N 个独立 App/journal/driver,WebServer resolver 按 /s/<id>/* 路由)。静态 N,
    /// 无 dynamic create/destroy(见 doc/U9_U10_DAEMON_TIER_DESIGN.md §4/§5)。
    serve_sessions: usize = 1,
    /// **U10-B:`serve --uds <path>`**:daemon 附加一条 UDS+NDJSON 本地绑定(gui/语音 UI 首选,与 web
    /// 并存)。非 null 即启用(强制走 serveMulti,即便 N=1)。POSIX only(Windows 走 web)。null=不启用。
    uds_path: ?[]const u8 = null,
    /// **task#20:`--session <id>`**:显式指定 session id(24-char)。App.init 用它替代 gen()。
    /// 用途:subprocess resume——B 进程用挂起 session 的 id 复用其 transcript 目录 + suspend.json。
    /// null = gen 新 id。非 24-char 回退 gen。
    session_id: ?[]const u8 = null,
    /// **task#20:`--suspendable`**:headless 遇 UI 工具(AskUserQuestion/ExitPlanMode)时**挂起**
    /// (写 suspend.json 退出)而非 NotATty 报错。装一个恒返 .pending 的 requester。默认 false(保持旧
    /// headless 语义:无 requester → NotATty)。用于 subprocess suspend/resume 闭环(外部工具据 suspend.json 应答)。
    suspendable: bool = false,
    /// **U8:`--resume-response <json|@file>`**:恢复一个挂起(suspend.json)的 session。
    /// 值 = 挂起工具(AskUserQuestion/ExitPlanMode/custom)的迟来结果 JSON(`@path` 从文件读)。
    /// 走 headless.resumeSuspended(read suspend.json→resumeRun→清/重写)。需同 session_id
    /// (--session / 持久化 transcript 目录一致)。null = 不启用。
    resume_response: ?[]const u8 = null,
    /// `--settings <path>`:显式 settings 文件(CLI 层,优先级仅次于 managed)。
    settings_path: ?[]const u8 = null,
    /// `--allowedTools "Tool,Tool(spec),..."`:逗号分隔,注入 CLI 层 allow。
    allowed_tools: ?[]const u8 = null,
    /// `--disallowedTools "..."`:逗号分隔,注入 CLI 层 deny。
    disallowed_tools: ?[]const u8 = null,
    /// `--add-dir <path>`(可重复):额外可读写目录,注入 additionalDirectories。
    /// 多个用 `\x00` 分隔拼一串(parseArgs 累加)。
    add_dirs: ?[]const u8 = null,
    /// `--answers-file <path>` / `METACODES_ANSWERS`:预置应答队列(Stage 3)。
    /// 非 tty 下权限 .ask / AskUserQuestion 从队列按序弹出,而非读 fd 0(被 REPL 行流独占)。
    answers_file: ?[]const u8 = null,
    /// `--base-url <url>` / `METACODES_BASE_URL`:覆盖 API 端点(默认硬编码)。
    /// 用于 record/replay(指向 mock server)。须以 `/v1/messages` 结尾。
    base_url: ?[]const u8 = null,
    /// cc-zig 可执行文件所在目录(main 从 argv[0] 解析)。定位 vendor/tinykg。null=未知。
    exe_dir: ?[]const u8 = null,
    /// Credential resolver precedence. Default matches docs: explicit CLI/env API
    /// key wins over stored OAuth unless user opts into oauth-first.
    auth_precedence: AuthPrecedence = .api_key_first,
    /// `--record <dir>` / `METACODES_RECORD_DIR`:把每次请求 body + SSE 响应原始字节
    /// dump 到该目录(cassette),供 replay 确定性复现。null = 不录制。
    record_dir: ?[]const u8 = null,
    /// LLM 后端协议选择。默认 anthropic;`METACODES_PROVIDER=openai` 或 model 前缀
    /// gpt*/o1*/o3* → openai(讲 chat/completions 协议)。**只在 App 组装层据此选 Client,
    /// core/UI 零感知**(多 Provider 重构 P3)。
    provider_kind: ProviderKind = .anthropic,
};

/// A single tagged treatment prevents invalid combinations such as "TinyKG on
/// but graph tools hidden".  Swarm is intentionally outside this first-stage
/// single-agent experiment and remains controlled by `agent_teams`.
pub const LongHorizonArm = enum {
    native,
    codex_style,
    claude_style,
    tinykg,

    pub fn parse(value: []const u8) ?LongHorizonArm {
        inline for (std.meta.fields(LongHorizonArm)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn usesAutoMemory(self: LongHorizonArm, native_enabled: bool) bool {
        return switch (self) {
            .native => native_enabled,
            .codex_style => false,
            .claude_style, .tinykg => true,
        };
    }

    pub fn usesTinyKg(self: LongHorizonArm) bool {
        return switch (self) {
            .native, .tinykg => true,
            .codex_style, .claude_style => false,
        };
    }
};

/// LLM 后端协议种类(App 组装层据此选具体 Client;core 只见中立 Provider)。
pub const ProviderKind = enum { anthropic, openai, gemini };

pub const AuthPrecedence = enum { api_key_first, oauth_first };

pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn parse(s: []const u8) ?ReasoningEffort {
        if (std.ascii.eqlIgnoreCase(s, "none") or std.ascii.eqlIgnoreCase(s, "off")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "minimal")) return .minimal;
        if (std.ascii.eqlIgnoreCase(s, "low")) return .low;
        if (std.ascii.eqlIgnoreCase(s, "medium") or std.ascii.eqlIgnoreCase(s, "med")) return .medium;
        if (std.ascii.eqlIgnoreCase(s, "high")) return .high;
        if (std.ascii.eqlIgnoreCase(s, "xhigh") or std.ascii.eqlIgnoreCase(s, "max")) return .xhigh;
        return null;
    }

    pub fn name(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .none => "none",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }

    pub fn active(self: ReasoningEffort) bool {
        return switch (self) {
            .none, .minimal => false,
            .low, .medium, .high, .xhigh => true,
        };
    }
};

/// 权限模式
/// 权限模式(对齐 Claude Code 6 模式 + 历史别名)。
///
/// - default      :仅只读工具免询问(对齐官方;旧 cc-zig 的 `prompt` 等价)
/// - accept_edits :读 + 文件编辑 + fs 命令(mkdir/touch/mv/cp/rm/rmdir/sed) 免询问(限工作目录)
/// - plan         :读 + 只读 bash 免询问;写/执行 deny
/// - auto         :全部尝试 ALLOW + 后台分类器(短期用 risk-level 近似)
/// - dont_ask     :只放行 permissions.allow 预批准的;其它全 deny
/// - bypass_permissions :跳过所有 prompt;rm -rf / 仍 prompt 作为电路断路器
///
/// 兼容别名:
///   prompt → default
///   bypass → bypass_permissions
pub const PermissionMode = enum(u8) {
    default,
    accept_edits,
    plan,
    auto,
    dont_ask,
    bypass_permissions,
    // ---- 历史别名(已弃用,仍接受) ----
    /// @deprecated 用 default
    prompt,
    /// @deprecated 用 bypass_permissions
    bypass,
};

/// 消息角色
pub const MessageRole = enum { user, assistant };

/// 对话消息
pub const Message = struct {
    role: MessageRole,
    content: []const u8,
};

/// 工具调用请求
pub const ToolCall = struct {
    name: []const u8,
    input: []const u8,
};

/// API 请求消息（包含 tool_use 类型）
pub const ApiMessage = struct {
    role: MessageRole,
    content: []const ApiContent,
};

/// API 内容块
pub const ApiContent = union(enum) {
    text: []const u8,
    /// Anthropic preserved thinking block(原样回传,对齐 Claude 4.x)
    thinking: []const u8,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
};

/// 工具调用块
pub const ToolUseBlock = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8, // JSON string
};

/// 工具结果块
pub const ToolResultBlock = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// 工具定义
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.ObjectMap,
    execute: *const fn (args: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
};

/// 应用状态
pub const App = struct {
    config: Config,
    messages: std.ArrayList(Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .config = Config{},
            .messages = .empty,
            .allocator = allocator,
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        for (app.messages.items) |msg| {
            app.allocator.free(msg.content);
        }
        app.messages.deinit(app.allocator);
        app.allocator.destroy(app);
    }

    pub fn addMessage(app: *App, role: MessageRole, content: []const u8) !void {
        // 复制内容到堆内存，避免栈缓冲区被覆盖导致悬空指针
        const content_copy = try app.allocator.dupe(u8, content);
        errdefer app.allocator.free(content_copy);
        try app.messages.append(app.allocator, .{ .role = role, .content = content_copy });
    }
};

/// CLI 参数解析
pub fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator) Config {
    var config = Config{};
    var args = std.process.Args.iterate(init.minimal.args);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |model| {
                config.model = allocator.dupe(u8, model) catch model;
            }
        } else if (std.mem.eql(u8, arg, "--model-display-name")) {
            if (args.next()) |name| {
                config.model_display_name = allocator.dupe(u8, name) catch name;
            }
        } else if (std.mem.eql(u8, arg, "--no-theme")) {
            config.no_theme = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (args.next()) |key| {
                config.api_key = allocator.dupe(u8, key) catch key;
            }
        } else if (std.mem.eql(u8, arg, "--permission")) {
            if (args.next()) |mode| {
                config.permission_mode = parsePermissionMode(mode);
            }
        }
    }

    return config;
}

fn parsePermissionMode(mode: []const u8) PermissionMode {
    if (std.mem.eql(u8, mode, "auto")) return .auto;
    if (std.mem.eql(u8, mode, "prompt")) return .prompt;
    if (std.mem.eql(u8, mode, "plan")) return .plan;
    if (std.mem.eql(u8, mode, "bypass")) return .bypass;
    return .prompt;
}

fn printHelp() void {
    std.debug.print(
        \\Metacode Super
        \\
        \\Usage: metacodes [options]
        \\
        \\Options:
        \\  --model <model>       Model to use (default: claude-sonnet-4-20250514)
        \\  --model-display-name <name>  Stable model identity shown to the actor
        \\  --api-key <key>       Metask API key (or METASK_API_KEY env)
        \\  --permission <mode>   Permission mode: auto, prompt, plan, bypass
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
        \\  -h, --help            Display this help
        \\
    , .{});
}

/// 打印帮助信息（可被 stdout 捕获的版本）
pub fn printHelpToWriter(stdout: anytype) !void {
    try stdout.print(
        \\Metacode Super
        \\
        \\Usage: metacodes [options]
        \\
        \\Options:
        \\  --model <model>       Model to use (default: claude-sonnet-4-20250514)
        \\  --model-display-name <name>  Stable model identity shown to the actor
        \\  --api-key <key>       Metask API key (or METASK_API_KEY env)
        \\  --permission <mode>   Permission mode: auto, prompt, plan, bypass
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
        \\  -h, --help            Display this help
        \\
    , .{});
}
