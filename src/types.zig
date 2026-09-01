const std = @import("std");

/// 通用配置
pub const Config = struct {
    /// 第一个无法识别的命令行参数(fail-closed:main 检查后报错退出)。
    /// 静默吞掉未知 flag 会让 treatment/评估参数拼错时无声降级——参数面
    /// 是外部契约,必须拒绝而不是忽略。
    parse_error: ?[]const u8 = null,
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
    /// LSP 集成(被动诊断 + 符号来源)。**默认开**;`--no-lsp` 关闭(`--lsp` 保留为显式开启,
    /// 可覆盖前面的 `--no-lsp`)。
    ///
    /// 为什么从 opt-in 翻成默认开(issue #17 follow-on):`1515b34` 砍掉 tree-sitter 后,
    /// CodeMap / FindSymbol / Read-outline / Edit 写后诊断**四项能力全部只剩 LSP 一个来源**,
    /// 默认关 = 默认降级。而真正的启用门在运行期且早就齐了——注册 server + 二进制已装
    /// (`servers.binaryAvailable`)+ 在 git workspace 内 + 命中 root marker,再加惰性 spawn /
    /// idle 回收 / client 上限 / broken-set。没装 language server 或不在项目里的机器,开着也不
    /// 会起任何进程。这个 flag 因此是一道多余的第二重门,唯一实际效果就是把默认钉在关。
    ///
    /// **代价(登记,不是默认关的理由)**:装了 server 的项目里,每次 Edit/Write 写盘**后**会
    /// 串行等 delta 诊断。那两个超时(warm ≤14s / 冷 spawn ≤26s)是**上限不是典型值**——本仓
    /// 实测 zls:冷 112ms、warm 52ms。重量级 server(rust-analyzer/clangd 建索引)会显著更贵,
    /// 上限兜底。盘写本身不被阻塞,等待可被 Ctrl+C 打断。见 `lsp/service.zig` 顶部 Linus #4。
    /// 嫌慢就 `--no-lsp`。
    lsp_enabled: bool = true,
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
    /// headless 多模态输入(issue #10):`--image <path>`(可重复)。与 prompt 一起
    /// 构成一条按序 text+images 的 user 消息。多个路径用 `\x00` 分隔拼一串
    /// (同 add_dirs 的 appendNulList 约定)。null = 无图像。
    images: ?[]const u8 = null,
    /// `--pdf <path>`(headless,可重复):与 images 同形的 `\x00` 分隔路径串。
    /// 块顺序:prompt 文本 → 各 image → 各 document。null = 未传该 flag。
    documents: ?[]const u8 = null,
    /// `--json`：headless 下用 NDJSON 事件流输出，便于 CI/脚本消费。
    json_output: bool = false,
    /// `--stream-json`:headless 运行期实时 NDJSON 事件流(text/tool/usage/turn),
    /// 每事件一行随发随写——外部看护可 tail 定位/止损,不必等收尾 result 行。
    stream_json: bool = false,
    /// `--dump-prompt`：构造完 system prompt + 工具 defs 后打印到 stdout 并退出，
    /// 不发网络、不需 API key。用于验证提示词×工具复刻。
    dump_prompt: bool = false,
    /// `--dump-plugins`:打印版本化 immutable plugin inventory JSON 后退出。
    dump_plugins: bool = false,
    /// `--version`:打印 `metacodes <semver>` 到 stdout 后退出(parse 只置位,
    /// main 早退打印,保持 parseArgsForTest 可测)。
    show_version: bool = false,
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
    /// Experimental, opt-in progress checkpoint for coding evaluations. Kept
    /// out of the default product path until measured on fixed benchmarks.
    verification_checkpoint: bool = false,
    verification_final_gate: bool = false,
    requirement_ledger: bool = false,
    requirement_ledger_observe: bool = false,
    verification_final_observe: bool = false,
    /// `--add-dir <path>`(可重复):额外可读写目录,注入 additionalDirectories。
    /// 多个用 `\x00` 分隔拼一串(parseArgs 累加)。
    add_dirs: ?[]const u8 = null,
    /// `--plugin-dir <path>`(可重复):显式启用一个严格 manifest 的 data package。
    /// 多个用 `\x00` 分隔；App 启动时把相对路径锚到 cwd、事务化构造一个不可变
    /// plugin generation，再把贡献投影进 canonical Skill/Agent registries。
    plugin_dirs: ?[]const u8 = null,
    /// `--process-plugin-dir <path>`(可重复):显式授予一个 hash-pinned
    /// out-of-process package 可执行权限。与 data package 加载通道分离。
    process_plugin_dirs: ?[]const u8 = null,
    /// `--answers-file <path>` / `METACODES_ANSWERS`:预置应答队列(Stage 3)。
    /// 非 tty 下权限 .ask / AskUserQuestion 从队列按序弹出,而非读 fd 0(被 REPL 行流独占)。
    answers_file: ?[]const u8 = null,
    /// `--base-url <url>` / `METACODES_BASE_URL`:覆盖 API 端点(默认硬编码)。
    /// 用于 record/replay(指向 mock server)。须以 `/v1/messages` 结尾。
    base_url: ?[]const u8 = null,
    /// metacodes 可执行文件所在目录(main 从 argv[0] 解析)。定位 staged TinyKG。null=未知。
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
    /// Provider profile id or alias (`--provider`). Non-null switches startup
    /// from model-name inference to registry-based route resolution (issue #16).
    provider_profile: ?[]const u8 = null,
    /// Channel within the selected profile (`--channel`).
    provider_channel: ?[]const u8 = null,
    /// Exact offer id (`--offer`), which pins one reproducible route.
    provider_offer: ?[]const u8 = null,
    /// Offer id of the resolved startup route, rendered for display/logs.
    selected_offer_id: ?[]const u8 = null,
    /// Canonical `ProviderId` of the resolved startup route. Recorded once at
    /// resolution so later startup steps never re-derive provider identity from
    /// the user-supplied alias — a second lookup that failed would fall back to
    /// the Metask credential path and leak a credential across providers.
    resolved_provider_id: ?[]const u8 = null,
    /// Provider-declared authentication for the resolved route. Null keeps the
    /// historical `authorization: Bearer <key>` transport behaviour.
    auth_scheme: ?@import("provider/credential.zig").AuthScheme = null,
    /// OpenAI wire 协议选择(`--openai-protocol` / env METACODES_OPENAI_PROTOCOL)。
    /// 默认 chat_completions;responses 走 /v1/responses(typed SSE 事件流)。
    /// 仅 provider_kind==.openai 时被消费;**显式配置,绝不从 base_url/model 推断**。
    openai_protocol: OpenAIProtocol = .chat_completions,
    /// True when the wire protocol came from `--openai-protocol` or its
    /// environment variable. An explicit choice outranks a route default.
    openai_protocol_explicit: bool = false,
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
            .claude_style => true,
            // TinyKG links markdown memory when the native channel is enabled,
            // but an explicit global disable remains authoritative.  This
            // permits graph-only deployments without silently enabling a
            // second persistence channel.
            .tinykg => native_enabled,
        };
    }

    pub fn usesTinyKg(self: LongHorizonArm) bool {
        return switch (self) {
            .native, .tinykg => true,
            .codex_style, .claude_style => false,
        };
    }
};

test "TinyKG arm respects an explicit auto-memory disable" {
    try std.testing.expect(LongHorizonArm.tinykg.usesAutoMemory(true));
    try std.testing.expect(!LongHorizonArm.tinykg.usesAutoMemory(false));
    try std.testing.expect(LongHorizonArm.claude_style.usesAutoMemory(false));
}

/// LLM 后端协议种类(App 组装层据此选具体 Client;core 只见中立 Provider)。
pub const ProviderKind = enum { anthropic, openai, gemini };

/// OpenAI 后端的 wire 协议(仅 provider_kind==.openai 时生效):
/// chat_completions = /v1/chat/completions(默认);responses = /v1/responses。
/// 显式配置选择(flag/env),绝不从 base_url/model 推断。
pub const OpenAIProtocol = enum {
    chat_completions,
    responses,

    /// 解析 CLI/env 值:"responses" → responses;"chat"/"chat_completions" → chat_completions。
    /// 词表外返 null(调用方 fail-closed,拼错不许静默落默认)。
    pub fn parse(value: []const u8) ?OpenAIProtocol {
        if (std.mem.eql(u8, value, "responses")) return .responses;
        if (std.mem.eql(u8, value, "chat") or std.mem.eql(u8, value, "chat_completions")) return .chat_completions;
        return null;
    }
};

test "OpenAIProtocol.parse:词表内映射,词表外 fail-closed" {
    try std.testing.expectEqual(OpenAIProtocol.responses, OpenAIProtocol.parse("responses").?);
    try std.testing.expectEqual(OpenAIProtocol.chat_completions, OpenAIProtocol.parse("chat").?);
    try std.testing.expectEqual(OpenAIProtocol.chat_completions, OpenAIProtocol.parse("chat_completions").?);
    try std.testing.expect(OpenAIProtocol.parse("respones") == null);
    try std.testing.expect(OpenAIProtocol.parse("") == null);
}

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
    /// 用户消息中的一等图像内容(issue #10)。base64 载荷 + MIME,与 text 可按序混排。
    /// wire 翻译按 provider 方言(dialect.serializeImagePart);不支持图像输入的
    /// (provider, model) 序列化时必须返回显式能力错误,绝不静默丢弃或降级为文本。
    image: ImageBlock,
    /// 用户消息中的一等文档内容(issue #25)。当前仅 PDF(application/pdf)。
    /// **与 image 分开建模**:文档不是图片,能力也不同——`supports_image_input`
    /// 为真绝不蕴含 `supports_pdf_input`。wire 翻译按 provider 方言
    /// (dialect.serializeDocumentPart);不支持文档输入的 (provider, model)
    /// 序列化时返回显式能力错误,绝不静默丢弃、OCR、抽文本或降级成页面图。
    document: DocumentBlock,
    /// Provider 私有的推理续传状态(issue #23)。目前唯一生产者/消费者是 OpenAI
    /// Responses(`store:false` 下的 `reasoning` item + `encrypted_content`):
    /// 服务端不存响应,推理上下文只能由客户端原样回传。**不是**可读文本——
    /// 与 `.thinking` 是两回事,永不展示、永不进 summary、永不当 assistant 正文。
    /// 其它方言序列化时整块跳过(它们各有自己的推理回传约定或根本不需要)。
    reasoning_item: ReasoningItemBlock,
};

/// 一条 provider 私有的推理续传项。`json` 是服务端原样发回的 wire JSON 对象
/// (含 id / summary / encrypted_content),回传时**逐字节不改**——任何重排都可能
/// 让服务端拒绝解密。`model` 是产出它的模型名:加密推理状态是模型/响应作用域的,
/// 会话中途换模型后把旧 item 发给新模型会被服务端拒收,故序列化层按模型名门控。
pub const ReasoningItemBlock = struct {
    model: []const u8,
    json: []const u8,
};

/// 图像内容块(中立 IR)。data 是 base64 编码字节;media_type 是与内容一致的 MIME
/// (至少支持 image/png 与 image/jpeg)。字节所有权跟随所在 ApiMessage 的借用契约。
pub const ImageBlock = struct {
    media_type: []const u8,
    data: []const u8,
};

/// 文档内容块(中立 IR,issue #25)。`data` 是 base64 编码的原始文档字节,
/// `media_type` 必须与内容一致(当前唯一受理值 `core/pdf.zig` 的 MEDIA_TYPE)。
/// `title` 是**宿主给的文档身份**(如原始文件名),可为空;它是稳定标识,
/// 绝不放绝对路径、时间戳或任何每次运行都会变的东西——那会污染 provider 可见
/// 字节的缓存前缀契约。字节所有权跟随所在 ApiMessage 的借用契约。
pub const DocumentBlock = struct {
    media_type: []const u8,
    data: []const u8,
    title: []const u8 = "",
    /// 准入时数出来的页数;null = 页树在压缩对象流里,不完整解析数不出来
    /// (见 core/pdf.zig)。**不是猜测值**,只用于 token 估算与预算,不上 wire。
    pages: ?u32 = null,
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
