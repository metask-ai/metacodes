const std = @import("std");

/// 通用配置
pub const Config = struct {
    api_key: ?[]const u8 = null,
    model: []const u8 = "claude-sonnet-4-20250514",
    /// 每次请求的 max_tokens。null = 根据 model 自动挑（util/model.zig 查表）；
    /// 非 null = 用户 CLI 明确指定的值，尊重覆盖。
    max_tokens: ?u32 = null,
    permission_mode: PermissionMode = .prompt,
    no_theme: bool = false,
    verbose: bool = false,
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
    /// `--settings <path>`:显式 settings 文件(CLI 层,优先级仅次于 managed)。
    settings_path: ?[]const u8 = null,
    /// `--allowedTools "Tool,Tool(spec),..."`:逗号分隔,注入 CLI 层 allow。
    allowed_tools: ?[]const u8 = null,
    /// `--disallowedTools "..."`:逗号分隔,注入 CLI 层 deny。
    disallowed_tools: ?[]const u8 = null,
    /// `--add-dir <path>`(可重复):额外可读写目录,注入 additionalDirectories。
    /// 多个用 `\x00` 分隔拼一串(parseArgs 累加)。
    add_dirs: ?[]const u8 = null,
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
pub const PermissionMode = enum {
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
        \\  --api-key <key>       Anthropic API key (or ANTHROPIC_API_KEY env)
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
        \\  --api-key <key>       Anthropic API key (or ANTHROPIC_API_KEY env)
        \\  --permission <mode>   Permission mode: auto, prompt, plan, bypass
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
        \\  -h, --help            Display this help
        \\
    , .{});
}
